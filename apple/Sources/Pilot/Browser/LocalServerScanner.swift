import Foundation

struct LocalServer: Identifiable, Hashable, Sendable {
    let port: Int
    let name: String

    // Identity is per-project, not per-port. Two dev servers can legitimately
    // resolve to the same port (several Next apps that all default to 3000, or
    // wrangler apps before their dev.port is read), and keying identity on the
    // bare port made SwiftUI's `ForEach(id:)` collapse them into one card shown
    // N times. Name + port keeps colliding servers distinct in the list.
    var id: String { "\(name)@\(port)" }
    var url: URL { URL(string: "http://localhost:\(port)")! }
    var displayURL: String { "localhost:\(port)" }
}

/// Per-workspace cache of discovered dev servers, shared by the New Tab
/// launcher and the browser start page. A known workspace shows its list
/// immediately; a scan runs only when nothing is cached or the cached list is
/// older than `refreshInterval`, and concurrent requests share one scan.
@MainActor
final class LocalServerCatalog {
    static let shared = LocalServerCatalog()
    static let refreshInterval: Duration = .seconds(60)
    /// Bounded so long sessions across many workspaces don't grow without limit.
    static let maximumWorkspaces = 32

    private struct Entry { var servers: [LocalServer]; var scannedAt: ContinuousClock.Instant }
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<[LocalServer], Never>] = [:]
    private let scanner: @Sendable (String) async -> [LocalServer]
    private let now: () -> ContinuousClock.Instant

    init(
        scanner: @escaping @Sendable (String) async -> [LocalServer] = { await LocalServerScanner.scan(rootPath: $0) },
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.scanner = scanner
        self.now = now
    }

    /// The last list found for this workspace, or nil if it was never scanned.
    func cached(rootPath: String) -> [LocalServer]? { entries[rootPath]?.servers }

    /// True when the workspace was never scanned or its list is stale.
    func needsRefresh(rootPath: String) -> Bool {
        guard let entry = entries[rootPath] else { return true }
        return now() - entry.scannedAt >= Self.refreshInterval
    }

    /// Scans the workspace (sharing an in-flight scan) and caches the result.
    func refresh(rootPath: String) async -> [LocalServer] {
        if let running = inFlight[rootPath] { return await running.value }
        let scan = scanner
        let task = Task { await scan(rootPath) }
        inFlight[rootPath] = task
        let found = await task.value
        inFlight[rootPath] = nil
        entries[rootPath] = Entry(servers: found, scannedAt: now())
        if entries.count > Self.maximumWorkspaces,
           let oldest = entries.min(by: { $0.value.scannedAt < $1.value.scannedAt })?.key {
            entries[oldest] = nil
        }
        return found
    }

    /// The cached list when fresh, otherwise a new scan.
    func servers(rootPath: String) async -> [LocalServer] {
        if !needsRefresh(rootPath: rootPath), let cached = cached(rootPath: rootPath) { return cached }
        return await refresh(rootPath: rootPath)
    }
}

// LocalServerScanner — best-effort discovery of dev-server candidates for a
// workspace. Scans the project tree for `package.json`, framework configs,
// and `.env*` files; pulls out an explicit port when present and otherwise
// falls back to the framework's default (Next: 3000, Vite: 5173, etc.).
//
// Only candidates are returned — liveness is determined separately by
// `LocalServerProbe`.
enum LocalServerScanner {
    private static let maxDepth = 4

    private static let ignoredDirectories: Set<String> = [
        "node_modules", ".git", "dist", "build", "target", ".next", ".nuxt",
        ".svelte-kit", "vendor", "DerivedData", ".build", "Pods", "out",
        ".turbo", ".cache", "coverage", ".vercel"
    ]

    static func scan(rootPath: String) async -> [LocalServer] {
        guard !rootPath.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            collect(rootPath: rootPath)
        }.value
    }

    private static func collect(rootPath: String) -> [LocalServer] {
        let root = URL(fileURLWithPath: rootPath)
        let configFiles = collectConfigFiles(at: root).sorted { lhs, rhs in
            // package.json wins over .env at the same project folder.
            let lhsIsPkg = lhs.lastPathComponent == "package.json"
            let rhsIsPkg = rhs.lastPathComponent == "package.json"
            if lhsIsPkg != rhsIsPkg { return lhsIsPkg }
            return lhs.path < rhs.path
        }

        // Dedupe by project folder so two Next.js apps that both default to
        // 3000 both surface — port collisions are real and worth showing.
        var byProject: [String: LocalServer] = [:]
        for url in configFiles {
            guard let server = parse(file: url) else { continue }
            let projectKey = url.deletingLastPathComponent().path
            if byProject[projectKey] == nil {
                byProject[projectKey] = server
            }
        }
        return byProject.values.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.name < $1.name
        }
    }

    // MARK: - Tree walk

    private static func collectConfigFiles(at root: URL) -> [URL] {
        var result: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        let fm = FileManager.default

        while let (dir, depth) = queue.first {
            queue.removeFirst()
            if depth > maxDepth { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let name = entry.lastPathComponent
                if isDir {
                    if !ignoredDirectories.contains(name), !name.hasPrefix(".") || name == ".env" {
                        queue.append((entry, depth + 1))
                    }
                } else if name == "package.json" || name.hasPrefix(".env") {
                    result.append(entry)
                }
            }
        }
        return result
    }

    // MARK: - Per-file parsers

    private static func parse(file: URL) -> LocalServer? {
        let name = file.lastPathComponent
        if name == "package.json" {
            return parsePackageJSON(at: file)
        }
        if name.hasPrefix(".env") {
            let projectName = file.deletingLastPathComponent().lastPathComponent
            return parseEnv(at: file, fallbackName: projectName)
        }
        return nil
    }

    private static func parsePackageJSON(at url: URL) -> LocalServer? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let projectName = displayName(
            packageName: json["name"] as? String,
            folder: url.deletingLastPathComponent().lastPathComponent
        )
        let scripts = json["scripts"] as? [String: String] ?? [:]
        let rawScript = ["dev", "start", "serve"]
            .compactMap { scripts[$0] }
            .first ?? ""
        let scriptValue = resolveScriptIndirection(rawScript, scripts: scripts)

        if let port = extractPort(fromScript: scriptValue) {
            return LocalServer(port: port, name: projectName)
        }
        // Wrangler-based dev (Cloudflare Workers, including OpenNext / `next`
        // apps run via `wrangler dev`): the real port is wrangler's [dev].port,
        // not a framework default. Read it before `inferFrameworkPort`, else the
        // `next` dependency masks every wrangler app as 3000 and they collapse
        // onto the same port. Wrangler's own fallback is 8787 when unset.
        if scriptValue.range(of: "wrangler", options: .caseInsensitive) != nil {
            let port = wranglerDevPort(in: url.deletingLastPathComponent()) ?? 8787
            return LocalServer(port: port, name: projectName)
        }
        if let port = inferFrameworkPort(script: scriptValue, packageJSON: json) {
            return LocalServer(port: port, name: projectName)
        }
        return nil
    }

    // Reads `[dev].port` from a sibling wrangler config (wrangler.jsonc, .json,
    // or .toml). jsonc permits comments and trailing commas, so a tolerant
    // regex is more robust here than JSONSerialization. Matches `dev.port`
    // specifically — not the adjacent `inspector_port` (the `"port"` /
    // `\bport` anchors exclude the `_port` suffix).
    private static func wranglerDevPort(in directory: URL) -> Int? {
        let candidates = ["wrangler.jsonc", "wrangler.json", "wrangler.toml"]
        for name in candidates {
            let fileURL = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let pattern = name.hasSuffix(".toml")
                ? #"\[dev\][^\[]*?\bport\s*=\s*(\d+)"#
                : #""dev"\s*:\s*\{[^}]*?"port"\s*:\s*(\d+)"#
            if let port = firstCapturedInt(in: text, pattern: pattern) {
                return port
            }
        }
        return nil
    }

    private static func firstCapturedInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[captured])
    }

    // Follows `bun run X` / `npm run X` / `pnpm run X` / `yarn X` wrappers
    // to the underlying script in the same package.json so the real -p flag
    // is visible to `extractPort`. Bounded to 5 hops to defend against
    // accidental cycles.
    private static func resolveScriptIndirection(
        _ script: String,
        scripts: [String: String],
        depth: Int = 0
    ) -> String {
        guard depth < 5 else { return script }
        let tokens = script.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2 else { return script }
        let runners: Set<String> = ["bun", "npm", "pnpm", "yarn", "npx"]
        guard runners.contains(tokens[0]) else { return script }
        let candidateIndex = tokens[1] == "run" ? 2 : 1
        guard candidateIndex < tokens.count else { return script }
        guard let next = scripts[tokens[candidateIndex]] else { return script }
        return resolveScriptIndirection(next, scripts: scripts, depth: depth + 1)
    }

    private static func parseEnv(at url: URL, fallbackName: String) -> LocalServer? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in content.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("PORT=") || line.hasPrefix("PORT =") else { continue }
            let value = line
                .drop(while: { $0 != "=" })
                .dropFirst()
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if let port = Int(value) {
                return LocalServer(port: port, name: fallbackName)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func displayName(packageName: String?, folder: String) -> String {
        guard let raw = packageName, !raw.isEmpty else { return folder }
        // Strip @scope/ prefixes so "@blau/web" → "web"
        if raw.hasPrefix("@"), let slash = raw.firstIndex(of: "/") {
            return String(raw[raw.index(after: slash)...])
        }
        return raw
    }

    private static func extractPort(fromScript script: String) -> Int? {
        // Matches `--port 3000`, `--port=3000`, `-p 3000`, `-p=3000`.
        let pattern = #"(?:--port|-p)[\s=]+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(script.startIndex..., in: script)
        guard let match = regex.firstMatch(in: script, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: script) else { return nil }
        return Int(script[r])
    }

    private static func inferFrameworkPort(script: String, packageJSON: [String: Any]) -> Int? {
        let lower = script.lowercased()
        if lower.contains("next") { return 3000 }
        if lower.contains("vite") { return 5173 }
        if lower.contains("astro") { return 4321 }
        if lower.contains("react-scripts") { return 3000 }
        if lower.contains("ng serve") || lower.contains("ng start") { return 4200 }
        if lower.contains("gatsby") { return 8000 }
        if lower.contains("nuxt") { return 3000 }
        if lower.contains("remix") { return 3000 }

        let deps = (packageJSON["dependencies"] as? [String: Any]) ?? [:]
        let devDeps = (packageJSON["devDependencies"] as? [String: Any]) ?? [:]
        let merged = deps.merging(devDeps) { lhs, _ in lhs }
        if merged["next"] != nil { return 3000 }
        if merged["vite"] != nil { return 5173 }
        if merged["astro"] != nil { return 4321 }
        if merged["react-scripts"] != nil { return 3000 }
        if merged["@angular/cli"] != nil { return 4200 }
        if merged["gatsby"] != nil { return 8000 }
        if merged["nuxt"] != nil || merged["nuxt3"] != nil { return 3000 }
        if merged["@remix-run/dev"] != nil { return 3000 }
        return nil
    }
}
