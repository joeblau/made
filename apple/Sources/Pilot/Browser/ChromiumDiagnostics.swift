@preconcurrency import ChromiumKit
import Foundation

enum BrowserPaneCreationPolicy {
    static func permitsCreation(
        for engine: BrowserEngine,
        chromiumCreationEnabled: Bool
    ) -> Bool {
        switch engine {
        case .webKit:
            true
        case .chromium:
            chromiumCreationEnabled
        }
    }
}

enum ChromiumBrowserCreationPolicy {
    static func permitsCreation(
        runtimeAvailable: Bool,
        engineCanStartOrIsRunning: Bool,
        initializationFailed: Bool,
        profileClearInProgress: Bool
    ) -> Bool {
        runtimeAvailable
            && engineCanStartOrIsRunning
            && !initializationFailed
            && !profileClearInProgress
    }

    @MainActor
    static var isCreationEnabled: Bool {
        let engine = ChromiumEngine.shared
        let engineCanStartOrIsRunning: Bool
        switch engine.state {
        case .notStarted, .initializing, .running:
            engineCanStartOrIsRunning = true
        case .shuttingDown, .shutDown, .failed:
            engineCanStartOrIsRunning = false
        @unknown default:
            engineCanStartOrIsRunning = false
        }

        return permitsCreation(
            runtimeAvailable: engine.isRuntimeAvailable,
            engineCanStartOrIsRunning: engineCanStartOrIsRunning,
            initializationFailed:
                ChromiumDiagnosticsCenter.shared.runtimeStatus == .unavailable,
            profileClearInProgress:
                ChromiumProfileAccessCoordinator.shared.isClearing
        )
    }

    /// Why the Chromium entry point is disabled, worded for someone looking at a
    /// greyed-out menu item. The three causes need different answers, so they are
    /// reported separately rather than as one generic "see diagnostics" line —
    /// diagnostics only helps for the third.
    @MainActor
    static var unavailableReason: ChromiumUnavailableReason? {
        guard !isCreationEnabled else { return nil }
        if !ChromiumEngine.shared.isRuntimeAvailable { return .notInThisBuild }
        if ChromiumProfileAccessCoordinator.shared.isClearing { return .clearingBrowsingData }
        return .engineUnavailable
    }
}

/// The reasons a Chromium pane cannot be created right now.
enum ChromiumUnavailableReason: Equatable, Sendable {
    /// The overwhelmingly common one: clean Debug and Release builds compile
    /// ChromiumKit's stub bridge and never link CEF, so there is no runtime to
    /// start. Nothing is wrong — the fix is to build a different configuration.
    case notInThisBuild
    /// Transient. Creation is blocked until the detached filesystem work ends.
    case clearingBrowsingData
    /// The runtime is present but the engine failed to start, shut down, or
    /// recorded an initialization failure. This is the case worth diagnosing.
    case engineUnavailable

    var message: String {
        switch self {
        case .notInThisBuild:
            "Chromium isn't in this build. Build the Chromium configuration to enable it."
        case .clearingBrowsingData:
            "Cockpit is clearing Chromium browsing data."
        case .engineUnavailable:
            "Chromium couldn't start. See Settings → Chromium diagnostics."
        }
    }
}

enum ChromiumDiagnosticEvent: String, CaseIterable, Hashable, Sendable {
    case browserClosed
    case launchRejected
    case navigationFailed
    case permissionDenied
    case popupBlocked
    case rendererTerminated
}

enum ChromiumDiagnosticRedaction: String, CaseIterable, Hashable, Sendable {
    case credentials
    case headers
    case localPath
    case pageContent
    case urlFragment
    case urlPath
    case urlQuery
}

/// A log-safe diagnostic value. It stores no raw URL details, credentials,
/// headers, local paths, or page-controlled content.
struct ChromiumDiagnosticRecord: Equatable, Sendable, CustomStringConvertible {
    static let maximumReportedHeaderCount = 64
    static let maximumReportedPageContentBytes = 4_096

    let event: ChromiumDiagnosticEvent
    let errorCode: Int?
    let origin: String?
    let redactions: [ChromiumDiagnosticRedaction]
    let redactedHeaderCount: Int
    let redactedPageContentByteCount: Int?
    let pageContentWasTruncated: Bool

    private init(
        event: ChromiumDiagnosticEvent,
        errorCode: Int?,
        origin: String?,
        redactions: [ChromiumDiagnosticRedaction],
        redactedHeaderCount: Int,
        redactedPageContentByteCount: Int?,
        pageContentWasTruncated: Bool
    ) {
        self.event = event
        self.errorCode = errorCode
        self.origin = origin
        self.redactions = redactions
        self.redactedHeaderCount = redactedHeaderCount
        self.redactedPageContentByteCount = redactedPageContentByteCount
        self.pageContentWasTruncated = pageContentWasTruncated
    }

    static func make(
        event: ChromiumDiagnosticEvent,
        errorCode: Int? = nil,
        url: URL? = nil,
        headers: [String: String] = [:],
        localPath: String? = nil,
        pageContent: String? = nil
    ) -> ChromiumDiagnosticRecord {
        var redactions = Set<ChromiumDiagnosticRedaction>()

        if let url {
            if url.user != nil || url.password != nil {
                redactions.insert(.credentials)
            }
            if !url.path.isEmpty, url.path != "/" {
                redactions.insert(.urlPath)
            }
            if url.query != nil {
                redactions.insert(.urlQuery)
            }
            if url.fragment != nil {
                redactions.insert(.urlFragment)
            }
        }
        if !headers.isEmpty {
            redactions.insert(.headers)
        }
        if localPath != nil {
            redactions.insert(.localPath)
        }
        if pageContent != nil {
            redactions.insert(.pageContent)
        }

        let sampledPageByteCount = pageContent.map {
            $0.utf8.prefix(maximumReportedPageContentBytes + 1).count
        }
        let pageContentWasTruncated = (sampledPageByteCount ?? 0) > maximumReportedPageContentBytes

        return ChromiumDiagnosticRecord(
            event: event,
            errorCode: errorCode,
            origin: safeOrigin(from: url),
            redactions: redactions.sorted { $0.rawValue < $1.rawValue },
            redactedHeaderCount: min(headers.count, maximumReportedHeaderCount),
            redactedPageContentByteCount: sampledPageByteCount.map {
                min($0, maximumReportedPageContentBytes)
            },
            pageContentWasTruncated: pageContentWasTruncated
        )
    }

    var description: String {
        var fields = ["event=\(event.rawValue)"]
        if let errorCode {
            fields.append("errorCode=\(errorCode)")
        }
        if let origin {
            fields.append("origin=\(origin)")
        }
        if redactedHeaderCount > 0 {
            fields.append("redactedHeaders=\(redactedHeaderCount)")
        }
        if let redactedPageContentByteCount {
            let suffix = pageContentWasTruncated ? "+" : ""
            fields.append("redactedPageBytes=\(redactedPageContentByteCount)\(suffix)")
        }
        if !redactions.isEmpty {
            fields.append("redacted=\(redactions.map(\.rawValue).joined(separator: ","))")
        }
        return fields.joined(separator: " ")
    }

    private static func safeOrigin(from url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedHost = components.percentEncodedHost,
              !encodedHost.isEmpty,
              encodedHost.utf8.count <= 255,
              encodedHost.unicodeScalars.allSatisfy({ 33...126 ~= $0.value }) else {
            return nil
        }

        let displayedHost = encodedHost.contains(":") && !encodedHost.hasPrefix("[")
            ? "[\(encodedHost)]"
            : encodedHost
        let port: Int?
        switch (scheme, components.port) {
        case ("http", 80), ("https", 443):
            port = nil
        default:
            port = components.port
        }
        if let port {
            return "\(scheme)://\(displayedHost):\(port)"
        }
        return "\(scheme)://\(displayedHost)"
    }
}
