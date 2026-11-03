import Foundation

struct DroneWorkspaceRegistry: Sendable {
    private let roots: [UUID: URL]
    private let maximumPathBytes: Int

    init(workspaces: [UUID: URL], maximumPathBytes: Int = 4_096) throws {
        var canonicalRoots: [UUID: URL] = [:]
        for (id, root) in workspaces {
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { throw DroneJobError.unauthorized }
            canonicalRoots[id] = canonical
        }
        roots = canonicalRoots
        self.maximumPathBytes = maximumPathBytes
    }

    func root(for id: UUID) throws -> URL {
        guard let root = roots[id] else { throw DroneJobError.unauthorized }
        return root
    }

    func resolve(
        _ relativePath: String,
        workspaceID: UUID,
        allowMissingLeaf: Bool = false
    ) throws -> URL {
        let root = try root(for: workspaceID)
        try validateRelativePath(relativePath)
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let canonical: URL
        if allowMissingLeaf {
            let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
            canonical = parent.appendingPathComponent(candidate.lastPathComponent).standardizedFileURL
        } else {
            canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        }
        guard Self.isDescendant(canonical, of: root) else { throw DroneJobError.unauthorized }
        return canonical
    }

    func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              path.utf8.count <= maximumPathBytes,
              !path.utf8.contains(0),
              !(path as NSString).isAbsolutePath,
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw DroneJobError.unauthorized }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}

enum DroneJobRequestValidator {
    static func validate(_ create: DroneJobCreate, limits: DroneJobEngineLimits) throws {
        guard (16 ... 128).contains(create.idempotencyKey.utf8.count),
              create.idempotencyKey.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (65 ... 90).contains($0)
                      || (97 ... 122).contains($0) || $0 == 45 || $0 == 95
              })
        else { throw DroneJobError.invalidRequest }
        try DroneAuthorization.validateEnvironment(create.request.environment)
        switch create.request.operation {
        case .process(let operation):
            try validate(operation, limits: limits)
        case .readFile(let operation):
            try requireNoEnvironment(create.request.environment)
            guard operation.maximumBytes >= 0,
                  operation.maximumBytes <= limits.maximumFileBytes
            else { throw DroneJobError.resourceLimit }
        case .writeFile(let operation):
            try requireNoEnvironment(create.request.environment)
            guard operation.data.count <= limits.maximumFileBytes else {
                throw DroneJobError.resourceLimit
            }
        case .listDirectory(let operation):
            try requireNoEnvironment(create.request.environment)
            guard operation.maximumEntries > 0,
                  operation.maximumEntries <= limits.maximumDirectoryEntries
            else { throw DroneJobError.resourceLimit }
        case .gitStatus(let operation):
            try validateGit(
                timeoutMilliseconds: operation.timeoutMilliseconds,
                outputLimit: operation.outputLimit,
                limits: limits
            )
        case .gitDiff(let operation):
            try validateGit(
                timeoutMilliseconds: operation.timeoutMilliseconds,
                outputLimit: operation.outputLimit,
                limits: limits
            )
        }
    }

    private static func validate(
        _ operation: DroneProcessOperation,
        limits: DroneJobEngineLimits
    ) throws {
        guard !operation.executablePath.isEmpty,
              operation.executablePath.utf8.count <= limits.maximumPathBytes,
              !operation.executablePath.utf8.contains(0),
              (operation.executablePath as NSString).isAbsolutePath,
              operation.arguments.count <= limits.maximumProcessArguments,
              operation.timeoutMilliseconds > 0,
              operation.timeoutMilliseconds <= limits.maximumProcessTimeoutMilliseconds,
              operation.standardOutputLimit >= 0,
              operation.standardOutputLimit <= limits.maximumProcessOutputBytes,
              operation.standardErrorLimit >= 0,
              operation.standardErrorLimit <= limits.maximumProcessOutputBytes
        else { throw DroneJobError.resourceLimit }
        var totalBytes = 0
        for argument in operation.arguments {
            guard !argument.utf8.contains(0),
                  argument.utf8.count <= limits.maximumArgumentBytes
            else { throw DroneJobError.resourceLimit }
            totalBytes += argument.utf8.count
            guard totalBytes <= limits.maximumTotalArgumentBytes else {
                throw DroneJobError.resourceLimit
            }
        }
    }

    private static func validateGit(
        timeoutMilliseconds: Int,
        outputLimit: Int,
        limits: DroneJobEngineLimits
    ) throws {
        guard timeoutMilliseconds > 0,
              timeoutMilliseconds <= limits.maximumProcessTimeoutMilliseconds,
              outputLimit >= 0,
              outputLimit <= limits.maximumProcessOutputBytes
        else { throw DroneJobError.resourceLimit }
    }

    private static func requireNoEnvironment(_ environment: [String: String]) throws {
        guard environment.isEmpty else { throw DroneJobError.invalidRequest }
    }
}

enum DroneJobEnvironment {
    static func make(requested: [String: String]) throws -> [String: String] {
        try DroneAuthorization.validateEnvironment(requested)
        var environment = [
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for (name, value) in requested { environment[name] = value }
        return environment
    }
}

enum DroneWorkspaceOperations {
    static func readFile(
        workspace: DroneWorkspaceRegistry,
        workspaceID: UUID,
        operation: DroneReadFileOperation
    ) throws -> Data {
        let url = try workspace.resolve(operation.relativePath, workspaceID: workspaceID)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw DroneJobError.invalidRequest }
        if let size = values.fileSize, size > operation.maximumBytes {
            throw DroneJobError.resourceLimit
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: operation.maximumBytes + 1) ?? Data()
        guard data.count <= operation.maximumBytes else { throw DroneJobError.resourceLimit }
        return data
    }

    static func writeFile(
        workspace: DroneWorkspaceRegistry,
        workspaceID: UUID,
        operation: DroneWriteFileOperation
    ) throws -> Int {
        guard operation.relativePath != "." else { throw DroneJobError.invalidRequest }
        let url = try workspace.resolve(
            operation.relativePath,
            workspaceID: workspaceID,
            allowMissingLeaf: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw DroneJobError.invalidRequest }
        }
        try operation.data.write(to: url, options: .atomic)
        return operation.data.count
    }

    static func listDirectory(
        workspace: DroneWorkspaceRegistry,
        workspaceID: UUID,
        operation: DroneListDirectoryOperation
    ) throws -> [DroneDirectoryEntry] {
        let url = try workspace.resolve(operation.relativePath, workspaceID: workspaceID)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw DroneJobError.invalidRequest }
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        ) else { throw DroneJobError.invalidRequest }
        var entries: [DroneDirectoryEntry] = []
        for case let child as URL in enumerator {
            guard entries.count < operation.maximumEntries else {
                throw DroneJobError.resourceLimit
            }
            let values = try child.resourceValues(forKeys: Set(keys))
            let kind: DroneDirectoryEntry.Kind = if values.isRegularFile == true {
                .file
            } else if values.isDirectory == true {
                .directory
            } else if values.isSymbolicLink == true {
                .symbolicLink
            } else {
                .other
            }
            entries.append(DroneDirectoryEntry(
                name: child.lastPathComponent,
                kind: kind,
                size: values.fileSize.map(UInt64.init)
            ))
        }
        return entries.sorted { $0.name < $1.name }
    }
}
