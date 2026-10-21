import Foundation
import SQLite3

/// Reads the OAuth sessions that the `codex`, `claude`, `grok`, and `kimi`
/// CLIs and the Cursor editor already store on this Mac, so we can query each
/// provider's plan-usage endpoint **without asking the user to log in again**
/// (the approach popularized by CodexBar).
///
/// Everything here is **read-only** with one deliberate exception: Grok. xAI
/// rotates refresh tokens on every use and issues six-hour access tokens, so a
/// Grok card that never refreshes goes dark within hours of the last CLI run.
/// `GrokSession.refresh` exchanges the CLI's refresh token and must then write
/// the rotated pair back to `auth.json` — an unpersisted rotation would strand
/// the CLI's own session. Every other provider stays strictly read-only: we
/// never write back or refresh (those CLIs own that lifecycle), and an expired
/// token surfaces a "re-run the CLI" message rather than mutating anyone
/// else's state.
///
/// ⚠️ These endpoints (`chatgpt.com/backend-api/wham/usage`,
/// `api.anthropic.com/api/oauth/usage`, Grok's CLI billing endpoint, Kimi
/// Code's `/usages` endpoint, and Cursor's dashboard usage endpoints) are the
/// internal endpoints the CLIs and apps call. They are undocumented and can
/// change without notice.
enum UsageSessions {

    // MARK: - Codex (OpenAI)

    /// The `codex` CLI's OAuth session, read from `~/.codex/auth.json`.
    struct CodexSession: Sendable {
        let accessToken: String
        let accountId: String?

        /// Load from `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`).
        static func load() -> CodexSession? {
            let home: URL
            if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
                home = URL(fileURLWithPath: codexHome)
            } else {
                home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            }
            let url = home.appendingPathComponent("auth.json")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = root["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String,
                  !access.isEmpty else { return nil }
            return CodexSession(accessToken: access, accountId: tokens["account_id"] as? String)
        }
    }

    // MARK: - Kimi (Moonshot AI)

    /// Kimi Code's OAuth session, read without refreshing or rewriting it.
    ///
    /// Current Kimi Code stores credentials below `$KIMI_CODE_HOME` (default
    /// `~/.kimi-code`). The former Python CLI used `$KIMI_SHARE_DIR` (default
    /// `~/.kimi`), so that location remains a read-only fallback for users who
    /// have not migrated yet.
    struct KimiSession: Sendable {
        let accessToken: String
        let expiresAt: Date?
        var refreshToken: String? = nil
        /// The credential file this session was read from; refresh writes the
        /// rotated pair back here.
        var fileURL: URL? = nil

        var isExpired: Bool { isExpired(at: Date()) }

        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= date
        }

        /// Whether the entry carries everything a refresh-token grant needs.
        var canRefresh: Bool {
            refreshToken != nil && fileURL != nil
        }

        /// Load the newest usable credential from the current Kimi Code
        /// home, falling back to the pre-migration home.
        static func load() -> KimiSession? {
            load(roots: credentialRoots())
        }

        /// Internal so tests can point discovery at temporary directories
        /// instead of a developer's real credential store.
        static func load(roots: [URL]) -> KimiSession? {
            for root in roots {
                for url in credentialFiles(in: root) {
                    guard let data = try? Data(contentsOf: url),
                          var session = parse(data: data)
                    else { continue }
                    session.fileURL = url
                    // A present current credential still owns account
                    // selection, so the first root holding a real token wins
                    // and an expired one is surfaced by the usage store. A
                    // file whose `access_token` is empty is not a credential
                    // at all: Kimi Code blanks the pre-migration file instead
                    // of deleting it, and treating that as "signed out" would
                    // hide the environment-scoped token beside it.
                    return session
                }
            }
            return nil
        }

        /// Parse the CLI's snake-case token wire format. Internal so tests can
        /// validate it without ever reading a developer's real credentials.
        static func parse(data: Data) -> KimiSession? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = nonemptyString(root["access_token"])
            else { return nil }

            let expiresAt = parseDate(root["expires_at"])
            return KimiSession(
                accessToken: accessToken,
                expiresAt: expiresAt,
                refreshToken: nonemptyString(root["refresh_token"])
            )
        }

        /// Kimi Code's device-flow OAuth client; public by design, baked into
        /// the CLI the same way Grok's is.
        static let oauthClientId = "17e5f671-d194-4dfb-9706-5516cb48c098"
        /// The user agent matters: Kimi's token endpoint sits behind a WAF
        /// that rejects generic clients.
        static let oauthUserAgent = "kimi-code-cli/2.3.0"

        /// Token endpoint host: the CLI config's `oauth_host` when present,
        /// else Kimi's default.
        static func oauthHost() -> String {
            let configURL = (ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]
                .flatMap(nonemptyString).map(expandedFileURL)
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code"))
                .appendingPathComponent("config.toml")
            if let contents = try? String(contentsOf: configURL, encoding: .utf8) {
                for line in contents.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("oauth_host") else { continue }
                    let parts = trimmed.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let host = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !host.isEmpty { return host }
                }
            }
            return "https://auth.kimi.ai"
        }

        /// Exchange the stored refresh token for a fresh access token and
        /// persist the result back to the CLI's credential file.
        ///
        /// Kimi issues 900-second access tokens and **rotates refresh tokens
        /// on every grant**, so without this the usage card is stale within
        /// minutes of the last CLI run, and an unpersisted rotation would
        /// strand the CLI's session. Mirrors `GrokSession.refresh`.
        static func refresh(
            session: KimiSession,
            transport: UsageHTTP.Transport = UsageHTTP.live,
            host: String? = nil,
            now: Date = Date()
        ) async -> KimiSession? {
            guard let refreshToken = session.refreshToken,
                  let fileURL = session.fileURL,
                  let tokenURL = URL(string: (host ?? oauthHost()) + "/api/oauth/token")
            else { return nil }

            let granted: [String: Any]
            do {
                granted = try await UsageHTTP.postForm(
                    url: tokenURL,
                    fields: [
                        "client_id": oauthClientId,
                        "grant_type": "refresh_token",
                        "refresh_token": refreshToken,
                    ],
                    // Kimi's token endpoint sits behind a WAF that rejects
                    // generic clients, so it must look like the CLI.
                    headers: ["User-Agent": oauthUserAgent],
                    transport: transport
                )
            } catch {
                // The CLI may have refreshed and rotated the chain under us;
                // prefer whatever usable session the file now holds.
                guard let data = try? Data(contentsOf: fileURL),
                      let current = parse(data: data),
                      !current.isExpired(at: now),
                      current.accessToken != session.accessToken else { return nil }
                return KimiSession(
                    accessToken: current.accessToken,
                    expiresAt: current.expiresAt,
                    refreshToken: current.refreshToken,
                    fileURL: fileURL
                )
            }

            guard let accessToken = nonemptyString(granted["access_token"]) else { return nil }
            let rotatedRefreshToken = nonemptyString(granted["refresh_token"]) ?? refreshToken
            let expiresAt = (granted["expires_in"] as? NSNumber).map {
                now.addingTimeInterval($0.doubleValue)
            }
            persist(
                rotated: (accessToken, rotatedRefreshToken, expiresAt, granted),
                to: fileURL
            )
            return KimiSession(
                accessToken: accessToken,
                expiresAt: expiresAt,
                refreshToken: rotatedRefreshToken,
                fileURL: fileURL
            )
        }

        /// Rewrite the credential file with rotated tokens, preserving every
        /// other field the CLI wrote. Best effort: the rotation already
        /// happened server-side, so a failed write must not discard the
        /// in-memory session.
        private static func persist(
            rotated: (accessToken: String, refreshToken: String, expiresAt: Date?, granted: [String: Any]),
            to fileURL: URL
        ) {
            guard let data = try? Data(contentsOf: fileURL),
                  var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            root["access_token"] = rotated.accessToken
            root["refresh_token"] = rotated.refreshToken
            // Keep both the relative and absolute expiry fields the CLI stores
            // in lockstep so its own refresh math stays correct.
            if let expiresIn = rotated.granted["expires_in"] as? NSNumber {
                root["expires_in"] = expiresIn
            }
            if let expiresAt = rotated.expiresAt {
                root["expires_at"] = Int(expiresAt.timeIntervalSince1970)
            }
            for key in ["scope", "token_type"] {
                if let value = nonemptyString(rotated.granted[key]) { root[key] = value }
            }
            guard let encoded = try? JSONSerialization.data(withJSONObject: root) else { return }
            let temporary = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(fileURL.lastPathComponent).cockpit-\(ProcessInfo.processInfo.processIdentifier)")
            do {
                try encoded.write(to: temporary, options: [])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: temporary.path
                )
                // Without `.usingNewMetadataOnly` the replaced file keeps the
                // original's mode, which would undo the owner-only tightening.
                _ = try FileManager.default.replaceItemAt(
                    fileURL, withItemAt: temporary, options: [.usingNewMetadataOnly]
                )
            } catch {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        /// Credential roots in preference order: the current Kimi Code home,
        /// then the pre-migration Python CLI home.
        private static func credentialRoots() -> [URL] {
            let environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser
            let currentHome = environment["KIMI_CODE_HOME"].flatMap(nonemptyString)
                .map(expandedFileURL)
                ?? home.appendingPathComponent(".kimi-code")
            let legacyHome = environment["KIMI_SHARE_DIR"].flatMap(nonemptyString)
                .map(expandedFileURL)
                ?? home.appendingPathComponent(".kimi")

            var seen = Set<String>()
            return [currentHome, legacyHome].filter {
                seen.insert($0.standardizedFileURL.path).inserted
            }
        }

        /// Candidate credential files inside one root, newest first.
        ///
        /// Kimi Code writes one credential per environment
        /// (`kimi-code-env-<id>.json`) and leaves the pre-migration
        /// `kimi-code.json` behind with an emptied token, so the fixed name is
        /// tried last rather than first. Internal so tests can assert the
        /// ordering without reading a developer's real credentials.
        static func credentialFiles(in root: URL) -> [URL] {
            let directory = root.appendingPathComponent("credentials", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            let environmentScoped = entries
                .filter {
                    let name = $0.lastPathComponent
                    return name.hasPrefix("kimi-code-env-") && name.hasSuffix(".json")
                }
                // Ties break on name so discovery is deterministic when two
                // environments are written within the same filesystem tick.
                .sorted { lhs, rhs in
                    let left = modificationDate(of: lhs)
                    let right = modificationDate(of: rhs)
                    if left != right { return left > right }
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }

            return environmentScoped
                + [directory.appendingPathComponent("kimi-code.json")]
        }

        private static func modificationDate(of url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }

        private static func expandedFileURL(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        private static func nonemptyString(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func parseDate(_ value: Any?) -> Date? {
            if let number = value as? NSNumber {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
            guard let string = nonemptyString(value), let seconds = Double(string) else {
                return nil
            }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    // MARK: - Grok (xAI)

    /// The Grok CLI's OAuth session, read from `~/.grok/auth.json`.
    ///
    /// Unlike Codex and Claude, Grok stores a map keyed by OAuth scope. A
    /// current OIDC entry is preferred, but an older grok.com sign-in entry is
    /// still accepted so existing CLI sessions continue to work.
    struct GrokSession: Sendable {
        let accessToken: String
        let scope: String
        let authMode: String?
        let email: String?
        let teamId: String?
        let expiresAt: Date?
        let refreshToken: String?
        let oidcClientId: String?
        let oidcIssuer: String?

        var isExpired: Bool { isExpired(at: Date()) }

        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            // The sixty-second margin keeps a token that would expire mid-request
            // from being sent at all.
            return expiresAt.timeIntervalSince(date) <= 60
        }

        /// Whether the entry carries everything a refresh-token grant needs.
        var canRefresh: Bool {
            refreshToken != nil && oidcClientId != nil
        }

        /// Load from `$GROK_HOME/auth.json` (default `~/.grok/auth.json`).
        static func load() -> GrokSession? {
            guard let data = try? Data(contentsOf: homeURL().appendingPathComponent("auth.json")) else {
                return nil
            }
            return parse(data: data)
        }

        /// Version sent by the installed CLI to its billing endpoint.
        static func installedVersion() -> String? {
            let url = homeURL().appendingPathComponent("version.json")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return nonemptyString(root["version"])
        }

        /// Parse Grok's scope-keyed auth file. Internal so fixture-based tests
        /// can cover scope preference without reading a developer's credentials.
        static func parse(data: Data, now: Date = Date()) -> GrokSession? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let entries: [(scope: String, value: [String: Any])] = root.compactMap { scope, value in
                guard let value = value as? [String: Any], nonemptyString(value["key"]) != nil else {
                    return nil
                }
                return (scope, value)
            }.sorted { $0.scope < $1.scope }

            let activeEntries = entries.filter { entry in
                guard let expiresAt = parseDate(entry.value["expires_at"]) else { return true }
                return expiresAt > now
            }
            // An expired entry that still holds a refresh token is a session we
            // can revive (see `refresh`), so it is only a fallback behind any
            // still-active entry — never a reason to report "not signed in".
            let refreshableEntries = entries.filter {
                nonemptyString($0.value["refresh_token"]) != nil
                    && nonemptyString($0.value["oidc_client_id"]) != nil
            }
            func newest(_ candidates: [(scope: String, value: [String: Any])])
                -> (scope: String, value: [String: Any])? {
                candidates.max { lhs, rhs in
                    let lhsExpiry = parseDate(lhs.value["expires_at"]) ?? .distantPast
                    let rhsExpiry = parseDate(rhs.value["expires_at"]) ?? .distantPast
                    if lhsExpiry == rhsExpiry { return lhs.scope > rhs.scope }
                    return lhsExpiry < rhsExpiry
                }
            }
            func preferred(_ candidates: [(scope: String, value: [String: Any])])
                -> (scope: String, value: [String: Any])? {
                newest(candidates.filter {
                    $0.scope.hasPrefix("https://auth.x.ai::")
                }) ?? newest(candidates.filter {
                    $0.scope == "https://accounts.x.ai/sign-in" || $0.scope.contains("/sign-in")
                })
            }
            let selected = preferred(activeEntries) ?? preferred(refreshableEntries)
            guard let selected, let accessToken = nonemptyString(selected.value["key"]) else {
                return nil
            }

            return GrokSession(
                accessToken: accessToken,
                scope: selected.scope,
                authMode: nonemptyString(selected.value["auth_mode"]),
                email: nonemptyString(selected.value["email"]),
                teamId: nonemptyString(selected.value["team_id"]),
                expiresAt: parseDate(selected.value["expires_at"]),
                refreshToken: nonemptyString(selected.value["refresh_token"]),
                oidcClientId: nonemptyString(selected.value["oidc_client_id"]),
                oidcIssuer: nonemptyString(selected.value["oidc_issuer"])
            )
        }

        /// Exchange the stored refresh token for a fresh access token and
        /// persist the result back to the CLI's `auth.json`.
        ///
        /// xAI **rotates refresh tokens on every grant**, so the write-back is
        /// not optional: once the exchange succeeds, the token in the file is
        /// dead and only the rotated pair keeps both Cockpit and the `grok`
        /// CLI signed in. The entry is rewritten in place (atomic rename,
        /// owner-only permissions) with every unrelated field preserved. If
        /// the grant fails — typically because the CLI refreshed concurrently
        /// and rotated the chain first — the file is re-read and whatever
        /// fresher session it now holds is returned instead.
        static func refresh(
            session: GrokSession,
            transport: UsageHTTP.Transport = UsageHTTP.live,
            authFileURL: URL? = nil,
            now: Date = Date()
        ) async -> GrokSession? {
            guard let refreshToken = session.refreshToken,
                  let clientId = session.oidcClientId else { return nil }
            let issuer = session.oidcIssuer ?? "https://auth.x.ai"
            guard let tokenURL = URL(string: issuer + "/oauth2/token") else { return nil }
            let fileURL = authFileURL ?? homeURL().appendingPathComponent("auth.json")

            let granted: [String: Any]
            do {
                granted = try await UsageHTTP.postForm(
                    url: tokenURL,
                    fields: [
                        "grant_type": "refresh_token",
                        "refresh_token": refreshToken,
                        "client_id": clientId,
                    ],
                    transport: transport
                )
            } catch {
                // The chain may have been rotated under us by the CLI; prefer
                // whatever the file holds now over giving up outright.
                guard let data = try? Data(contentsOf: fileURL),
                      let current = parse(data: data, now: now),
                      !current.isExpired(at: now),
                      current.accessToken != session.accessToken else { return nil }
                return current
            }

            guard let accessToken = nonemptyString(granted["access_token"]) else { return nil }
            let rotatedRefreshToken = nonemptyString(granted["refresh_token"]) ?? refreshToken
            let expiresAt = (granted["expires_in"] as? NSNumber).map {
                now.addingTimeInterval($0.doubleValue)
            }
            persist(
                rotated: (accessToken, rotatedRefreshToken, expiresAt),
                scope: session.scope,
                to: fileURL
            )
            return GrokSession(
                accessToken: accessToken,
                scope: session.scope,
                authMode: session.authMode,
                email: session.email,
                teamId: session.teamId,
                expiresAt: expiresAt,
                refreshToken: rotatedRefreshToken,
                oidcClientId: clientId,
                oidcIssuer: session.oidcIssuer
            )
        }

        /// Rewrite one entry of the scope-keyed auth file with rotated tokens,
        /// preserving every other field and entry. Best effort: the rotation
        /// already happened server-side, so a failed write must not discard
        /// the in-memory session.
        private static func persist(
            rotated: (accessToken: String, refreshToken: String, expiresAt: Date?),
            scope: String,
            to fileURL: URL
        ) {
            guard let data = try? Data(contentsOf: fileURL),
                  var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var entry = root[scope] as? [String: Any] else { return }
            entry["key"] = rotated.accessToken
            entry["refresh_token"] = rotated.refreshToken
            if let expiresAt = rotated.expiresAt {
                entry["expires_at"] = expiryFormatter.string(from: expiresAt)
            }
            root[scope] = entry
            guard let encoded = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            ) else { return }
            let temporary = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(fileURL.lastPathComponent).cockpit-\(ProcessInfo.processInfo.processIdentifier)")
            do {
                try encoded.write(to: temporary, options: [])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: temporary.path
                )
                // Without `.usingNewMetadataOnly` the replaced file keeps the
                // original's mode, which would undo the owner-only tightening.
                _ = try FileManager.default.replaceItemAt(
                    fileURL, withItemAt: temporary, options: [.usingNewMetadataOnly]
                )
            } catch {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        /// The CLI writes fractional-second UTC timestamps
        /// (`2026-10-14T16:28:25.653188Z`); milliseconds keep its parser happy.
        private static let expiryFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
            return formatter
        }()

        private static func nonemptyString(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func homeURL() -> URL {
            if let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"], !grokHome.isEmpty {
                return URL(fileURLWithPath: (grokHome as NSString).expandingTildeInPath)
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        }

        private static func parseDate(_ value: Any?) -> Date? {
            if let number = value as? NSNumber {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
            guard let string = nonemptyString(value) else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: string) { return parsed }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }
    }

    // MARK: - Cursor (Anysphere)

    /// The Cursor editor's web session, read from the IDE's local state
    /// database. Cursor's CLI config holds only identity (no tokens), so the
    /// IDE's `cursorAuth/accessToken` item is the one usable credential on
    /// disk. The token is a JWT whose `sub` claim doubles as the dashboard
    /// user id (`WorkosCursorSessionToken` is `sub::token`).
    struct CursorSession: Sendable {
        let accessToken: String
        /// JWT `sub`, e.g. `github|1218847`.
        let userId: String
        let expiresAt: Date?

        var isExpired: Bool { isExpired(at: Date()) }

        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(date) <= 60
        }

        /// Load from the IDE's state database (read-only).
        static func load() -> CursorSession? {
            guard let token = readStateItem(
                key: "cursorAuth/accessToken",
                databaseURL: stateDatabaseURL()
            ) else { return nil }
            return parse(token: token)
        }

        /// Decode the JWT's `sub` and `exp` claims. Internal so tests can
        /// cover it with fabricated tokens.
        static func parse(token: String) -> CursorSession? {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = trimmed.split(separator: ".")
            guard segments.count == 3,
                  let payload = base64URLDecode(String(segments[1])),
                  let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                  let subject = claims["sub"] as? String,
                  !subject.isEmpty else { return nil }
            let expiresAt = (claims["exp"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            return CursorSession(accessToken: trimmed, userId: subject, expiresAt: expiresAt)
        }

        static func stateDatabaseURL() -> URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        }

        /// Read one `ItemTable` value. Internal so tests can point at a
        /// fixture database instead of a developer's real IDE state.
        static func readStateItem(key: String, databaseURL: URL) -> String? {
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                databaseURL.path, &database, SQLITE_OPEN_READONLY, nil
            ) == SQLITE_OK, let database else {
                sqlite3_close(database)
                return nil
            }
            defer { sqlite3_close(database) }

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database, "SELECT value FROM ItemTable WHERE key = ?1", -1, &statement, nil
            ) == SQLITE_OK, let statement else { return nil }
            defer { sqlite3_finalize(statement) }

            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0) else { return nil }
            let text = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        private static func base64URLDecode(_ segment: String) -> Data? {
            var base64 = segment
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64.append("=") }
            return Data(base64Encoded: base64)
        }
    }

    // MARK: - Claude (Claude Code)

    /// Claude Code's OAuth session. Needs the `user:profile` scope to read usage.
    struct ClaudeSession: Sendable {
        let accessToken: String
        let scopes: [String]
        let subscriptionType: String?

        var hasProfileScope: Bool { scopes.contains("user:profile") }

        /// Load Claude Code's credentials — file first, then the macOS Keychain
        /// item Claude Code writes (via the `security` CLI, which may prompt once).
        static func load() -> ClaudeSession? {
            let fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: fileURL), let session = parse(data) {
                return session
            }
            if let data = readKeychainViaSecurityCLI(service: keychainService), let session = parse(data) {
                return session
            }
            return nil
        }

        /// Keychain generic-password service Claude Code stores its creds under.
        static let keychainService = "Claude Code-credentials"

        private static func parse(_ data: Data) -> ClaudeSession? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any],
                  let access = oauth["accessToken"] as? String,
                  !access.isEmpty else { return nil }
            return ClaudeSession(
                accessToken: access,
                scopes: (oauth["scopes"] as? [String]) ?? [],
                subscriptionType: oauth["subscriptionType"] as? String
            )
        }

        /// Read a generic-password item created by another app via `/usr/bin/security`.
        /// A direct `SecItemCopyMatching` from a different app is blocked by the
        /// item's ACL; the `security` CLI is the item's trusted reader and, on
        /// first access, macOS prompts the user to Allow. Read-only.
        private static func readKeychainViaSecurityCLI(service: String) -> Data? {
            let invocation = ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-s", service, "-w"],
                timeout: .seconds(30),
                standardOutputLimit: 1 * 1_024 * 1_024,
                standardErrorLimit: 64 * 1_024,
                redactedArgumentIndexes: [2]
            )
            guard let result = try? ProcessRunner.runBlocking(invocation),
                  let value = String(data: result.standardOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value.data(using: .utf8)
        }
    }
}
