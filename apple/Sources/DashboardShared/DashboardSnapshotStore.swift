import Foundation

public enum DashboardSnapshotStoreError: Error, Equatable {
    case appGroupUnavailable(String)
    case snapshotTooLarge
}

public struct DashboardSnapshotStore: Sendable {
    public static let maxSnapshotBytes = 512 * 1_024

    public let appGroup: String?
    private let directory: URL?

    public init(appGroup: String) {
        self.appGroup = appGroup
        directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public init(directory: URL) {
        appGroup = nil
        self.directory = directory
    }

    public func read<Snapshot: Decodable>(_ type: Snapshot.Type, for family: DashboardFamily) -> Snapshot? {
        guard let url = fileURL(for: family), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxSnapshotBytes + 1),
              data.count <= Self.maxSnapshotBytes else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func write<Snapshot: Encodable>(_ snapshot: Snapshot, for family: DashboardFamily) throws {
        guard let directory else {
            throw DashboardSnapshotStoreError.appGroupUnavailable(appGroup ?? "injected directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maxSnapshotBytes else { throw DashboardSnapshotStoreError.snapshotTooLarge }
        try data.write(to: directory.appendingPathComponent(family.fileName), options: .atomic)
    }

    public func clear(_ family: DashboardFamily) throws {
        guard let url = fileURL(for: family) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    public func clearAll() throws {
        for family in DashboardFamily.allCases {
            try clear(family)
        }
    }

    private func fileURL(for family: DashboardFamily) -> URL? {
        directory?.appendingPathComponent(family.fileName)
    }
}

private extension DashboardFamily {
    var fileName: String { "dashboard-\(rawValue).json" }
}
