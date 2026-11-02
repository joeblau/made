import CryptoKit
import Foundation

/// A side-loaded wallet extension discovered on disk.
///
/// Pilot holds no keys and signs nothing. The wallet is an ordinary unpacked
/// Chrome extension (Rabby, Backpack, …) running inside Chromium, which keeps
/// its own secrets in its own extension storage — so this type is only ever
/// about *locating* an extension and addressing its UI.
struct WalletExtension: Identifiable, Equatable, Sendable {
    /// Chrome's unpacked-extension identifier, derived from `directory`.
    let id: String
    /// Display name from the manifest.
    let name: String
    let directory: URL
    /// Manifest-declared action popup, relative to the extension root.
    let popupPath: String

    /// `chrome-extension://<id>/<popupPath>` — what the popup panel loads.
    var popupURL: URL? {
        URL(string: "chrome-extension://\(id)/\(popupPath)")
    }

    /// Best-effort glyph. Wallets are third-party, so this is a display nicety
    /// with a neutral fallback rather than a registry that must be kept current.
    var systemImageName: String {
        switch name.lowercased() {
        case let value where value.contains("rabby"): "hare"
        case let value where value.contains("backpack"): "backpack"
        default: "wallet.bifold"
        }
    }
}

/// Finds side-loaded wallet extensions and derives their Chrome identifiers.
///
/// Everything here treats the extension directory as untrusted input: it is a
/// folder a user dropped on disk, and its `manifest.json` is authored by a third
/// party. Sizes are bounded before reading and the manifest's popup path is
/// confined to the extension root.
enum WalletExtensionRegistry {
    /// Where Pilot looks for unpacked wallet extensions, in order.
    ///
    /// The canonical home is Pilot's own Application Support directory, so the
    /// set is per-user and survives rebuilds. `PILOT_WALLET_EXTENSIONS_DIR`
    /// overrides it for development against a working tree.
    static func searchRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL? = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
    ) -> [URL] {
        var roots: [URL] = []
        if let override = environment["PILOT_WALLET_EXTENSIONS_DIR"], !override.isEmpty {
            roots.append(contentsOf: override.split(separator: ":").map {
                URL(fileURLWithPath: String($0))
            })
        }
        if let applicationSupport {
            roots.append(
                applicationSupport
                    .appending(path: "Pilot", directoryHint: .isDirectory)
                    .appending(path: "Extensions", directoryHint: .isDirectory)
            )
        }
        return roots
    }

    /// Every readable extension across the search roots, sorted by name so the
    /// menu order does not depend on filesystem enumeration order.
    static func discover(
        roots: [URL] = searchRoots(),
        fileManager: FileManager = .default
    ) -> [WalletExtension] {
        var found: [WalletExtension] = []
        var seenIDs = Set<String>()

        for root in roots {
            let entries = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                guard let walletExtension = load(directory: entry, fileManager: fileManager),
                      seenIDs.insert(walletExtension.id).inserted else { continue }
                found.append(walletExtension)
            }
        }

        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Read one extension directory, or nil when it is not a usable extension.
    static func load(directory: URL, fileManager: FileManager = .default) -> WalletExtension? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let manifestURL = directory.appending(path: "manifest.json")
        guard let attributes = try? fileManager.attributesOfItem(atPath: manifestURL.path),
              let size = attributes[.size] as? Int,
              size > 0, size <= maximumManifestBytes,
              let data = try? Data(contentsOf: manifestURL) else { return nil }

        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let popupPath = popupPath(in: manifest) else { return nil }

        // Chrome derives an unpacked extension's ID from its absolute path, so
        // the ID must be computed from the same path CEF is told to load. That
        // is why nothing here may be hardcoded: moving the directory changes the
        // identifier, and a stale constant silently addresses a nonexistent
        // extension.
        let id = identifier(forDirectory: directory)
        return WalletExtension(
            id: id,
            name: displayName(manifest: manifest, directory: directory, id: id, fileManager: fileManager),
            directory: directory,
            popupPath: popupPath
        )
    }

    /// The manifest name, resolved the way Chrome does when it is a
    /// `__MSG_key__` reference, otherwise the folder name, otherwise the ID.
    /// Every candidate is third-party text, so it is length-capped and has
    /// control and format characters (including bidi overrides) removed.
    static func displayName(
        manifest: [String: Any],
        directory: URL,
        id: String,
        fileManager: FileManager = .default
    ) -> String {
        var candidates: [String] = []
        if let raw = manifest["name"] as? String {
            if let key = messageKey(in: raw) {
                if let resolved = localizedMessage(
                    key: key, manifest: manifest, directory: directory, fileManager: fileManager
                ) {
                    candidates.append(resolved)
                }
            } else {
                candidates.append(raw)
            }
        }
        candidates.append(directory.lastPathComponent)
        for candidate in candidates {
            let name = UntrustedText.sanitized(String(candidate.prefix(maximumRawNameLength)), limit: 60)
            if !name.isEmpty, messageKey(in: name) == nil { return name }
        }
        return id
    }

    /// The key of a whole-string Chrome i18n reference (`__MSG_appName__`),
    /// or nil when `raw` is ordinary text. Chrome message names are ASCII
    /// letters, digits, `_` and `@`.
    static func messageKey(in raw: String) -> String? {
        let prefix = "__MSG_", suffix = "__"
        guard raw.hasPrefix(prefix), raw.hasSuffix(suffix),
              raw.count > prefix.count + suffix.count,
              raw.count <= prefix.count + suffix.count + 128 else { return nil }
        let key = raw.dropFirst(prefix.count).dropLast(suffix.count)
        guard key.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "@")
        }) else { return nil }
        return String(key)
    }

    /// Looks `key` up in `_locales/<default_locale>/messages.json`. Chrome
    /// matches message names case-insensitively. Nil when the locale is
    /// missing or malformed, the file is absent, oversized, outside the
    /// extension root, or has no such message.
    static func localizedMessage(
        key: String,
        manifest: [String: Any],
        directory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        guard let locale = manifest["default_locale"] as? String,
              (1...16).contains(locale.count),
              locale.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
              }) else { return nil }
        let messagesURL = directory
            .appending(path: "_locales", directoryHint: .isDirectory)
            .appending(path: locale, directoryHint: .isDirectory)
            .appending(path: "messages.json", directoryHint: .notDirectory)
        guard let data = boundedContents(
            of: messagesURL, confinedTo: directory, limit: maximumMessagesBytes, fileManager: fileManager
        ), let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let entry = messages[key]
            ?? messages.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        return (entry as? [String: Any])?["message"] as? String
    }

    /// Reads a regular file of at most `limit` bytes whose resolved path stays
    /// inside `root`, so a symlink cannot point the read anywhere else and the
    /// read itself, not a prior size check, enforces the bound.
    private static func boundedContents(
        of url: URL,
        confinedTo root: URL,
        limit: Int,
        fileManager: FileManager
    ) -> Data? {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolved.path(percentEncoded: false).hasPrefix(rootPrefix),
              let attributes = try? fileManager.attributesOfItem(atPath: resolved.path(percentEncoded: false)),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1),
              !data.isEmpty, data.count <= limit else { return nil }
        return data
    }

    /// Chrome's unpacked-extension identifier: the first 16 bytes of the
    /// SHA-256 of the absolute directory path, hex-encoded, with each hex digit
    /// mapped `0…f` → `a…p`.
    static func identifier(forDirectory directory: URL) -> String {
        let path = directory.standardizedFileURL.path(percentEncoded: false)
        let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let scalarA = UnicodeScalar("a").value

        return digest.prefix(16).reduce(into: "") { output, byte in
            for nibble in [byte >> 4, byte & 0x0F] {
                output.unicodeScalars.append(UnicodeScalar(scalarA + UInt32(nibble))!)
            }
        }
    }

    /// The action popup declared by the manifest. MV3 uses `action`; MV2 used
    /// `browser_action`. A wallet with neither has no toolbar UI to show.
    private static func popupPath(in manifest: [String: Any]) -> String? {
        let action = (manifest["action"] as? [String: Any])
            ?? (manifest["browser_action"] as? [String: Any])
        guard let raw = action?["default_popup"] as? String else { return nil }
        return sanitizedRelativePath(raw)
    }

    /// Confine the manifest's popup to the extension root. The manifest is
    /// third-party text, and this string becomes a URL path, so an absolute
    /// path or a `..` segment is rejected outright rather than normalized.
    static func sanitizedRelativePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256 else { return nil }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("\\") else { return nil }
        guard !trimmed.contains("://") else { return nil }

        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ $0 != ".." && $0 != "." }) else { return nil }
        guard segments.allSatisfy({ segment in
            segment.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }) else { return nil }

        return trimmed
    }

    /// A manifest is a small JSON file; anything larger is not one.
    private static let maximumManifestBytes = 1024 * 1024
    /// A wallet's default-locale catalog holds every UI string (Rabby's is a
    /// few hundred KB), so allow more than a manifest but still bound it.
    private static let maximumMessagesBytes = 4 * 1024 * 1024
    /// Caps the work `UntrustedText.sanitized` does on a third-party string.
    private static let maximumRawNameLength = 1024
}
