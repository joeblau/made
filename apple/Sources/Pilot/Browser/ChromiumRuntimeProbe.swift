import AppKit
@preconcurrency import ChromiumKit
import Foundation
import OSLog

/// Result of the offline, native-child-view Chromium feasibility probe. This is
/// kept in the Pilot target (rather than re-linking ChromiumKit into a test
/// bundle) so the probe exercises the exact process-wide CEF singleton used by
/// production.
struct ChromiumRuntimeProbeReport: Equatable, Sendable {
    let startupDuration: TimeInterval
    let firstNavigationDuration: TimeInterval
    let helperCleanupDuration: TimeInterval
    let idleCPUPercent: Double
    let idleMessagePumpWatchdogWorkCount: Int
    let residentMemoryBytes: UInt64
    let firstJavaScriptTitle: String
    let secondJavaScriptTitle: String
    let survivingBrowserTitle: String
    let historyBackURL: URL
    let historyForwardURL: URL
    let restoredBrowserTitle: String
    let policy: ChromiumRuntimePolicyProbeReport
    let rendererTerminationStatus: Int
    let rendererRecoveryTitle: String
    let peakBrowserCount: Int
    let browserCountAfterFirstClose: Int
    let browserCountAfterSecondClose: Int
    let browserCountAfterRecoveryClose: Int
    let helperProcessCountAfterShutdown: Int
    let rendererHelperLaunched: Bool
    let gpuHelperLaunched: Bool
}

struct ChromiumRuntimePolicyProbeReport: Equatable, Sendable {
    let blockedNavigationURL: URL
    let blockedScriptPopupTitle: String
    let interceptedPopupURL: URL
    let deniedPermissionRequests: Int
    let deniedGeolocationPermission: Bool
    let deniedFileChooserRequests: Int
    let deniedDownloadURL: URL
    let deniedAuthenticationRequests: Int
    let deniedAuthenticationURL: URL?
    let rejectedCertificateErrors: [Int]
    let rejectedCertificateURL: URL?
    let hostileMessageSurvivorTitle: String
}

enum ChromiumRuntimeProbeError: LocalizedError {
    case engineAlreadyUsed
    case timedOut(String)
    case navigationFailed(String)
    case rendererTerminated(Int)
    case javaScriptRejected(String)
    case helperDidNotLaunch(String)
    case invalidLifecycle(String)
    case processObservationFailed(operation: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .engineAlreadyUsed:
            "The Chromium runtime probe requires a fresh process."
        case let .timedOut(operation):
            "The Chromium runtime probe timed out while \(operation)."
        case let .navigationFailed(message):
            "The Chromium runtime probe navigation failed: \(message)"
        case let .rendererTerminated(status):
            "The Chromium renderer terminated with status \(status)."
        case let .javaScriptRejected(browser):
            "Chromium rejected JavaScript execution in the \(browser) browser."
        case let .helperDidNotLaunch(role):
            "The Chromium \(role) helper did not launch."
        case let .invalidLifecycle(message):
            "The Chromium runtime lifecycle was invalid: \(message)"
        case let .processObservationFailed(operation, reason):
            "The Chromium runtime probe could not observe Cockpit processes while \(operation): \(reason)"
        }
    }
}

@MainActor
enum ChromiumRuntimeProbe {
    private static let logger = Logger(
        subsystem: "app.blau.pilot",
        category: "ChromiumRuntimeProbe"
    )
    private static let processObserver = ChromiumProcessObserver(
        scope: .current()
    )

    static func run(
        profileDirectory: URL,
        firstURL: URL,
        secondURL: URL,
        invalidCertificateURL: URL,
        timeout: TimeInterval = 20
    ) async throws -> ChromiumRuntimeProbeReport {
        let engine = ChromiumEngine.shared
        guard !engine.isRunning, engine.activeBrowserCount == 0 else {
            throw ChromiumRuntimeProbeError.engineAlreadyUsed
        }

        try FileManager.default.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true
        )
        let startedAt = Date()
        _ = try engine.start(profileDirectory: profileDirectory)
        logger.notice("CEF engine start requested")

        let firstDelegate = ChromiumRuntimeProbeDelegate()
        let secondDelegate = ChromiumRuntimeProbeDelegate()
        let firstHost = ChromiumBrowserHostView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 640)
        )
        let secondHost = ChromiumBrowserHostView(
            frame: NSRect(x: 480, y: 0, width: 480, height: 640)
        )
        firstHost.delegate = firstDelegate
        secondHost.delegate = secondDelegate
        let window = makeWindow(
            firstHost: firstHost,
            secondHost: secondHost
        )

        firstHost.loadURL(firstURL)
        secondHost.loadURL(firstURL)

        do {
            try await wait(
                for: "creating two native child browsers",
                timeout: timeout,
                delegates: [firstDelegate, secondDelegate]
            ) {
                firstHost.lifecycleState == .created
                    && secondHost.lifecycleState == .created
                    && engine.activeBrowserCount == 2
            }
            logger.notice(
                "Two browsers created; active count: \(engine.activeBrowserCount)"
            )
            let startupDuration = Date().timeIntervalSince(startedAt)

            let navigationStartedAt = Date()
            try await wait(
                for: "loading the offline fixture and its JavaScript",
                timeout: timeout,
                delegates: [firstDelegate, secondDelegate]
            ) {
                firstDelegate.lastURL == firstURL
                    && secondDelegate.lastURL == firstURL
                    && firstDelegate.lastTitle?.contains("[ready]") == true
                    && secondDelegate.lastTitle?.contains("[ready]") == true
                    && !firstHost.isLoading
                    && !secondHost.isLoading
            }
            logger.notice("Offline fixture JavaScript observed in both browsers")
            let firstNavigationDuration = Date().timeIntervalSince(navigationStartedAt)

            let scriptTitles = try await verifyJavaScript(
                firstHost: firstHost,
                secondHost: secondHost,
                firstDelegate: firstDelegate,
                secondDelegate: secondDelegate,
                sourceURL: firstURL,
                timeout: timeout
            )

            try await verifySameDocumentHistory(
                host: firstHost, delegate: firstDelegate,
                pageURL: firstURL, timeout: timeout
            )

            let helpers = try await verifyHelpersAndMeasureResources(
                delegates: [firstDelegate, secondDelegate],
                timeout: timeout
            )
            logger.notice(
                "Idle process sample: \(helpers.resources.cpuPercent) percent CPU, \(helpers.resources.messagePumpWatchdogWorkCount) watchdog message-pump turns, \(helpers.resources.residentMemoryBytes) resident bytes"
            )

            let peakBrowserCount = Int(engine.activeBrowserCount)
            logger.notice("Requesting first browser close")
            firstHost.close()
            try await wait(
                for: "closing only the first browser",
                timeout: timeout,
                delegates: [secondDelegate]
            ) {
                firstHost.lifecycleState == .closed
                    && secondHost.lifecycleState == .created
                    && engine.activeBrowserCount == 1
            }
            logger.notice(
                "First browser closed; active count: \(engine.activeBrowserCount)"
            )
            let browserCountAfterFirstClose = Int(engine.activeBrowserCount)

            logger.notice("Navigating surviving browser")
            secondHost.loadURL(secondURL)
            try await wait(
                for: "navigating the surviving browser",
                timeout: timeout,
                delegates: [secondDelegate]
            ) {
                secondDelegate.lastURL == secondURL
                    && secondDelegate.lastTitle?.contains("[ready]") == true
                    && !secondHost.isLoading
            }
            logger.notice("Surviving browser navigation observed")
            let survivingTitle = "Cockpit Chromium probe survivor"
            guard secondHost.executeJavaScript(
                "document.title = '\(survivingTitle)';",
                sourceURL: secondURL,
                line: 1
            ) else {
                throw ChromiumRuntimeProbeError.javaScriptRejected("surviving")
            }
            try await wait(
                for: "executing JavaScript after the other browser closed",
                timeout: timeout,
                delegates: [secondDelegate]
            ) {
                secondDelegate.lastTitle == survivingTitle
            }
            logger.notice("Surviving browser JavaScript observed")

            let history = try await verifyHistory(
                host: secondHost,
                delegate: secondDelegate,
                firstURL: firstURL,
                secondURL: secondURL,
                timeout: timeout
            )

            logger.notice("Requesting final browser close")
            secondHost.close()
            try await wait(
                for: "closing the final browser",
                timeout: timeout,
                delegates: []
            ) {
                secondHost.lifecycleState == .closed
                    && engine.activeBrowserCount == 0
            }
            logger.notice("Final browser closed")
            let browserCountAfterSecondClose = Int(engine.activeBrowserCount)
            let recovery = try await verifyRestorationAndRendererRecovery(
                in: window,
                engine: engine,
                restoredURL: secondURL,
                recoveryURL: firstURL,
                invalidCertificateURL: invalidCertificateURL,
                timeout: timeout
            )
            logger.notice("Requesting CEF engine shutdown")
            let helperCleanup = try await finish(
                engine: engine,
                window: window,
                timeout: timeout
            )
            logger.notice("Probe durations: startup \(startupDuration) s, first navigation \(firstNavigationDuration) s, helper cleanup \(helperCleanup.duration) s")

            return ChromiumRuntimeProbeReport(
                startupDuration: startupDuration,
                firstNavigationDuration: firstNavigationDuration,
                helperCleanupDuration: helperCleanup.duration,
                idleCPUPercent: helpers.resources.cpuPercent,
                idleMessagePumpWatchdogWorkCount: helpers.resources.messagePumpWatchdogWorkCount,
                residentMemoryBytes: helpers.resources.residentMemoryBytes,
                firstJavaScriptTitle: scriptTitles.first,
                secondJavaScriptTitle: scriptTitles.second,
                survivingBrowserTitle: survivingTitle,
                historyBackURL: history.backURL,
                historyForwardURL: history.forwardURL,
                restoredBrowserTitle: recovery.restoredTitle,
                policy: recovery.policy,
                rendererTerminationStatus: recovery.terminationStatus,
                rendererRecoveryTitle: recovery.recoveryTitle,
                peakBrowserCount: peakBrowserCount,
                browserCountAfterFirstClose: browserCountAfterFirstClose,
                browserCountAfterSecondClose: browserCountAfterSecondClose,
                browserCountAfterRecoveryClose: recovery.browserCountAfterClose,
                helperProcessCountAfterShutdown: helperCleanup.processCount,
                rendererHelperLaunched: helpers.renderer,
                gpuHelperLaunched: helpers.gpu
            )
        } catch {
            logger.error(
                "Probe failed; engine: \(engine.state.rawValue); first host: \(firstHost.lifecycleState.rawValue); second host: \(secondHost.lifecycleState.rawValue); active count: \(engine.activeBrowserCount); error: \(error.localizedDescription, privacy: .public)"
            )
            firstHost.delegate = nil
            secondHost.delegate = nil
            firstHost.close()
            secondHost.close()
            try? await wait(
                for: "emergency browser cleanup",
                timeout: min(timeout, 5),
                delegates: []
            ) {
                engine.activeBrowserCount == 0
            }
            logger.notice(
                "Emergency cleanup finished with active count: \(engine.activeBrowserCount)"
            )
            await shutdown(engine)
            logger.notice("CEF engine shutdown completed after probe failure")
            window.close()
            throw error
        }
    }

    private static func verifyJavaScript(
        firstHost: ChromiumBrowserHostView,
        secondHost: ChromiumBrowserHostView,
        firstDelegate: ChromiumRuntimeProbeDelegate,
        secondDelegate: ChromiumRuntimeProbeDelegate,
        sourceURL: URL,
        timeout: TimeInterval
    ) async throws -> (first: String, second: String) {
        let firstTitle = "Cockpit Chromium probe first"
        let secondTitle = "Cockpit Chromium probe second"
        guard firstHost.executeJavaScript(
            "document.title = '\(firstTitle)';",
            sourceURL: sourceURL,
            line: 1
        ) else {
            throw ChromiumRuntimeProbeError.javaScriptRejected("first")
        }
        guard secondHost.executeJavaScript(
            "document.title = '\(secondTitle)';",
            sourceURL: sourceURL,
            line: 1
        ) else {
            throw ChromiumRuntimeProbeError.javaScriptRejected("second")
        }
        try await wait(
            for: "observing explicit JavaScript in both browsers",
            timeout: timeout,
            delegates: [firstDelegate, secondDelegate]
        ) {
            firstDelegate.lastTitle == firstTitle
                && secondDelegate.lastTitle == secondTitle
        }
        logger.notice("Explicit JavaScript observed in both browsers")
        return (firstTitle, secondTitle)
    }

    private struct HelperCleanupResult {
        let duration: TimeInterval
        let processCount: Int
    }

    private static func finish(
        engine: ChromiumEngine,
        window: NSWindow,
        timeout: TimeInterval
    ) async throws -> HelperCleanupResult {
        let startedAt = Date()
        await shutdown(engine)
        let deadline = Date().addingTimeInterval(timeout)
        var helperCount: Int
        while true {
            helperCount = try await observeProcesses(
                while: "waiting for Chromium helpers to exit"
            ).helperCommands.count
            if helperCount == 0 {
                break
            }
            guard Date() < deadline else {
                throw ChromiumRuntimeProbeError.timedOut(
                    "waiting for Chromium helpers to exit"
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let duration = Date().timeIntervalSince(startedAt)
        logger.notice(
            "CEF shutdown completed in \(duration) seconds with \(helperCount) helpers"
        )
        window.close()
        return HelperCleanupResult(
            duration: duration,
            processCount: helperCount
        )
    }

    private struct HelperVerificationResult {
        let renderer: Bool
        let gpu: Bool
        let resources: ResourceMeasurement
    }

    private static func verifyHelpersAndMeasureResources(
        delegates: [ChromiumRuntimeProbeDelegate],
        timeout: TimeInterval
    ) async throws -> HelperVerificationResult {
        var roles = ChromiumHelperRoles()
        try await wait(
            for: "launching renderer and GPU helpers",
            timeout: timeout,
            delegates: delegates
        ) {
            roles = roles.union(
                try await observeProcesses(
                    while: "launching renderer and GPU helpers"
                ).helperRoles
            )
            return roles.renderer && roles.gpu
        }
        logger.notice("Renderer and GPU helper roles observed")
        return HelperVerificationResult(
            renderer: roles.renderer,
            gpu: roles.gpu,
            resources: try await measureIdleResources()
        )
    }

    private struct RecoveryResult {
        let restoredTitle: String
        let policy: ChromiumRuntimePolicyProbeReport
        let terminationStatus: Int
        let recoveryTitle: String
        let browserCountAfterClose: Int
    }

    private static func verifyRestorationAndRendererRecovery(
        in window: NSWindow,
        engine: ChromiumEngine,
        restoredURL: URL,
        recoveryURL: URL,
        invalidCertificateURL: URL,
        timeout: TimeInterval
    ) async throws -> RecoveryResult {
        let delegate = ChromiumRuntimeProbeDelegate()
        let host = ChromiumBrowserHostView(
            frame: NSRect(x: 240, y: 0, width: 480, height: 640)
        )
        host.delegate = delegate
        window.contentView?.addSubview(host)

        do {
            logger.notice("Recreating a browser from its persisted URL")
            host.loadURL(restoredURL)
            try await wait(
                for: "restoring the final Chromium URL in a new browser",
                timeout: timeout,
                delegates: [delegate]
            ) {
                host.lifecycleState == .created
                    && engine.activeBrowserCount == 1
                    && delegate.lastURL == restoredURL
                    && delegate.lastTitle?.contains("[ready]") == true
                    && !host.isLoading
            }
            let restoredTitle = "Cockpit Chromium probe restored"
            guard host.executeJavaScript(
                "document.title = '\(restoredTitle)';",
                sourceURL: restoredURL,
                line: 1
            ) else {
                throw ChromiumRuntimeProbeError.javaScriptRejected("restored")
            }
            try await wait(
                for: "executing JavaScript in the restored browser",
                timeout: timeout,
                delegates: [delegate]
            ) {
                delegate.lastTitle == restoredTitle
            }
            logger.notice("Restored browser navigation and JavaScript observed")

            let policy = try await verifySecurityPolicies(
                host: host,
                delegate: delegate,
                engine: engine,
                baseURL: recoveryURL,
                invalidCertificateURL: invalidCertificateURL,
                timeout: timeout
            )

            logger.notice("Intentionally terminating the restored renderer")
            delegate.allowsIntentionalRendererCrash = true
            host.loadURL(URL(string: "chrome://crash")!)
            let terminationStatus = try await waitForRendererTermination(
                delegate: delegate,
                timeout: timeout
            )
            delegate.prepareForRendererRecovery()

            logger.notice("Recovering navigation after renderer termination")
            host.loadURL(recoveryURL)
            try await wait(
                for: "recovering navigation after renderer termination",
                timeout: timeout,
                delegates: [delegate]
            ) {
                delegate.lastURL == recoveryURL
                    && delegate.lastTitle?.contains("[ready]") == true
                    && !host.isLoading
            }
            let recoveryTitle = "Cockpit Chromium probe renderer recovered"
            guard host.executeJavaScript(
                "document.title = '\(recoveryTitle)';",
                sourceURL: recoveryURL,
                line: 1
            ) else {
                throw ChromiumRuntimeProbeError.javaScriptRejected("recovered")
            }
            try await wait(
                for: "executing JavaScript after renderer recovery",
                timeout: timeout,
                delegates: [delegate]
            ) {
                delegate.lastTitle == recoveryTitle
            }
            logger.notice("Renderer recovery navigation and JavaScript observed")

            host.close()
            try await wait(
                for: "closing the recovered browser",
                timeout: timeout,
                delegates: []
            ) {
                host.lifecycleState == .closed
                    && engine.activeBrowserCount == 0
            }
            host.removeFromSuperview()
            return RecoveryResult(
                restoredTitle: restoredTitle,
                policy: policy,
                terminationStatus: terminationStatus.rawValue,
                recoveryTitle: recoveryTitle,
                browserCountAfterClose: Int(engine.activeBrowserCount)
            )
        } catch {
            host.delegate = nil
            host.close()
            try? await wait(
                for: "cleaning up the recovery browser",
                timeout: min(timeout, 5),
                delegates: []
            ) {
                engine.activeBrowserCount == 0
            }
            host.removeFromSuperview()
            throw error
        }
    }

    private static func verifySecurityPolicies(
        host: ChromiumBrowserHostView,
        delegate: ChromiumRuntimeProbeDelegate,
        engine: ChromiumEngine,
        baseURL: URL,
        invalidCertificateURL: URL,
        timeout: TimeInterval
    ) async throws -> ChromiumRuntimePolicyProbeReport {
        let prohibitedURL = URL(fileURLWithPath: "/etc/passwd")
        host.loadURL(prohibitedURL)
        try await wait(
            for: "blocking a prohibited file navigation",
            timeout: timeout,
            delegates: []
        ) {
            delegate.blockedNavigationURLs.contains(prohibitedURL)
        }
        delegate.clearExpectedNavigationFailure()

        let popupPageURL = baseURL.appendingPathComponent("popup.html")
        let popupTargetURL = baseURL.appendingPathComponent("second-page.html")
        try await navigate(
            host: host,
            delegate: delegate,
            to: popupPageURL,
            timeout: timeout
        )
        let blockedScriptPopupTitle = "Cockpit Chromium script popup blocked"
        guard host.executeJavaScript(
            """
            document.title =
              window.open('/second-page.html', 'pilot-policy-probe')
                ? 'unexpected script popup'
                : '\(blockedScriptPopupTitle)';
            """,
            sourceURL: popupPageURL,
            line: 1
        ) else {
            throw ChromiumRuntimeProbeError.javaScriptRejected("popup policy")
        }
        try await wait(
            for: "blocking a script-initiated popup",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.lastTitle == blockedScriptPopupTitle
                && engine.activeBrowserCount == 1
        }
        try await clickElement(
            "#target-blank",
            in: host,
            delegate: delegate,
            sourceURL: popupPageURL,
            timeout: timeout
        )
        try await wait(
            for: "intercepting a trusted target-blank popup",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.interceptedPopupURLs.contains(popupTargetURL)
                && engine.activeBrowserCount == 1
        }

        let permissionPageURL = baseURL.appendingPathComponent(
            "permissions.html"
        )
        try await navigate(
            host: host,
            delegate: delegate,
            to: permissionPageURL,
            timeout: timeout
        )
        let permissionDeniedTitle = "Cockpit Chromium permission denied"
        guard host.executeJavaScript(
            """
            navigator.mediaDevices.getUserMedia({audio: true})
              .then(() => { document.title = 'unexpected permission grant'; })
              .catch(() => { document.title = '\(permissionDeniedTitle)'; });
            """,
            sourceURL: permissionPageURL,
            line: 1
        ) else {
            throw ChromiumRuntimeProbeError.javaScriptRejected(
                "permission policy"
            )
        }
        try await wait(
            for: "denying an unapproved media permission",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.deniedPermissionRequests > 0
                && delegate.lastTitle == permissionDeniedTitle
        }
        try await clickElement(
            "[data-permission=\"geolocation\"]",
            in: host,
            delegate: delegate,
            sourceURL: permissionPageURL,
            timeout: timeout
        )
        try await wait(
            for: "denying an unapproved geolocation permission",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.deniedGeolocationPermission
        }
        let fileInputURL = baseURL.appendingPathComponent("file-input.html")
        try await navigate(
            host: host,
            delegate: delegate,
            to: fileInputURL,
            timeout: timeout
        )
        try await clickElement(
            "#file-input",
            in: host,
            delegate: delegate,
            sourceURL: fileInputURL,
            timeout: timeout
        )
        try await wait(
            for: "denying an inactive file chooser",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.deniedFileChooserRequests > 0
        }

        try await ChromiumRuntimeTransportSecurityProbe.verifyRejections(
            host: host,
            delegate: delegate,
            baseURL: baseURL,
            invalidCertificateURL: invalidCertificateURL,
            timeout: timeout
        )

        let downloadURL = baseURL.appendingPathComponent("download.txt")
        host.loadURL(downloadURL)
        try await wait(
            for: "denying an inactive download",
            timeout: timeout,
            delegates: []
        ) {
            delegate.deniedDownloadURLs.contains(downloadURL)
        }
        delegate.clearExpectedNavigationFailure()

        let hostileURL = baseURL.appendingPathComponent(
            "hostile-messages.html"
        )
        try await navigate(
            host: host,
            delegate: delegate,
            to: hostileURL,
            timeout: timeout
        )
        let survivorTitle = "Cockpit Chromium hostile messages ignored"
        guard host.executeJavaScript(
            """
            document.querySelector('#send').click();
            document.title = '\(survivorTitle)';
            """,
            sourceURL: hostileURL,
            line: 1
        ) else {
            throw ChromiumRuntimeProbeError.javaScriptRejected(
                "hostile-message policy"
            )
        }
        try await wait(
            for: "surviving hostile page messages",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.lastTitle == survivorTitle
                && engine.activeBrowserCount == 1
        }
        logger.notice("Live Chromium security-policy callbacks observed")

        return ChromiumRuntimePolicyProbeReport(
            blockedNavigationURL: prohibitedURL,
            blockedScriptPopupTitle: blockedScriptPopupTitle,
            interceptedPopupURL: popupTargetURL,
            deniedPermissionRequests: delegate.deniedPermissionRequests,
            deniedGeolocationPermission:
                delegate.deniedGeolocationPermission,
            deniedFileChooserRequests: delegate.deniedFileChooserRequests,
            deniedDownloadURL: downloadURL,
            deniedAuthenticationRequests:
                delegate.deniedAuthenticationRequests,
            deniedAuthenticationURL:
                delegate.deniedAuthenticationURLs.first,
            rejectedCertificateErrors:
                delegate.rejectedCertificateErrors,
            rejectedCertificateURL:
                delegate.rejectedCertificateURLs.first,
            hostileMessageSurvivorTitle: survivorTitle
        )
    }

    private static func clickElement(
        _ selector: String,
        in host: ChromiumBrowserHostView,
        delegate: ChromiumRuntimeProbeDelegate,
        sourceURL: URL,
        timeout: TimeInterval
    ) async throws {
        let titlePrefix = "Cockpit Chromium click location:"
        guard host.executeJavaScript(
            """
            (() => {
              const rect = document.querySelector('\(selector)')
                .getBoundingClientRect();
              document.title =
                '\(titlePrefix)' +
                (rect.left + rect.width / 2) + ':' +
                (rect.top + rect.height / 2);
            })();
            """,
            sourceURL: sourceURL,
            line: 1
        ) else {
            throw ChromiumRuntimeProbeError.javaScriptRejected(
                "locating \(selector)"
            )
        }
        try await wait(
            for: "locating \(selector)",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.lastTitle?.hasPrefix(titlePrefix) == true
        }
        let coordinates = delegate.lastTitle?
            .dropFirst(titlePrefix.count)
            .split(separator: ":")
            .compactMap { Double($0) }
        guard let coordinates, coordinates.count == 2,
              let window = host.window else {
            throw ChromiumRuntimeProbeError.invalidLifecycle(
                "CEF did not expose a clickable \(selector) location."
            )
        }
        let hostPoint = NSPoint(
            x: coordinates[0],
            y: host.bounds.height - coordinates[1]
        )
        window.makeKeyAndOrderFront(nil)
        host.focusBrowser()
        guard host.sendMouseClick(at: hostPoint) else {
            throw ChromiumRuntimeProbeError.invalidLifecycle(
                "CEF rejected a \(selector) click."
            )
        }
    }

    fileprivate static func navigate(
        host: ChromiumBrowserHostView,
        delegate: ChromiumRuntimeProbeDelegate,
        to url: URL,
        timeout: TimeInterval
    ) async throws {
        host.loadURL(url)
        try await wait(
            for: "loading \(url.lastPathComponent)",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.lastURL == url
                && delegate.lastTitle?.contains("[ready]") == true
                && !host.isLoading
        }
    }

    private static func waitForRendererTermination(
        delegate: ChromiumRuntimeProbeDelegate,
        timeout: TimeInterval
    ) async throws -> ChromiumRendererTerminationStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while delegate.rendererTerminationStatus == nil {
            guard Date() < deadline else {
                throw ChromiumRuntimeProbeError.timedOut(
                    "waiting for intentional renderer termination"
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return delegate.rendererTerminationStatus!
    }

    private static func makeWindow(
        firstHost: ChromiumBrowserHostView,
        secondHost: ChromiumBrowserHostView
    ) -> NSWindow {
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 640)
        )
        container.addSubview(firstHost)
        container.addSubview(secondHost)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFront(nil)
        return window
    }

    /// Observes the app's processes through the bounded process runner, so
    /// `ps` never blocks the main actor that drives CEF's message pump.
    /// Cancellation propagates unchanged; every other failure names the step.
    private static func observeProcesses(
        while operation: String
    ) async throws -> ChromiumProcessSnapshot {
        do {
            let snapshot = try await processObserver.snapshot()
            if snapshot.malformedRowCount > 0 {
                logger.notice(
                    "Ignored \(snapshot.malformedRowCount) malformed process rows while \(operation, privacy: .public)"
                )
            }
            return snapshot
        } catch let error as ChromiumProcessObservationError {
            throw ChromiumRuntimeProbeError.processObservationFailed(
                operation: operation,
                reason: error.localizedDescription
            )
        }
    }

    private struct ResourceMeasurement {
        let cpuPercent: Double
        let messagePumpWatchdogWorkCount: Int
        let residentMemoryBytes: UInt64
    }

    /// CPU and resident memory come from two process observations one idle
    /// second apart, measured over the interval between their midpoints. The
    /// watchdog count covers only the idle sleep between the observations.
    private static func measureIdleResources() async throws
        -> ResourceMeasurement {
        try await Task.sleep(for: .seconds(1))
        let before = try await observeProcesses(while: "sampling idle resources")
        let messagePumpCountBefore =
            ChromiumEngine.shared.messagePumpWatchdogWorkCount
        try await Task.sleep(for: .seconds(1))
        let messagePumpCountAfter =
            ChromiumEngine.shared.messagePumpWatchdogWorkCount
        let after = try await observeProcesses(while: "sampling idle resources")
        let idle: ChromiumIdleResourceMeasurement
        do {
            idle = try ChromiumIdleResources.measure(before: before, after: after)
        } catch let error as ChromiumIdleResourceError {
            throw ChromiumRuntimeProbeError.invalidLifecycle(
                error.localizedDescription
            )
        }
        logger.notice(
            "Idle sample window: \(idle.window.description, privacy: .public) across \(idle.comparedProcessCount) processes"
        )
        return ResourceMeasurement(
            cpuPercent: idle.cpuPercent,
            messagePumpWatchdogWorkCount: messagePumpCountAfter >= messagePumpCountBefore
                ? Int(messagePumpCountAfter - messagePumpCountBefore)
                : 0,
            residentMemoryBytes: idle.residentMemoryBytes
        )
    }

    fileprivate static func wait(
        for operation: String,
        timeout: TimeInterval,
        delegates: [ChromiumRuntimeProbeDelegate],
        until condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !condition() {
            for delegate in delegates {
                if let error = delegate.lastFailure {
                    throw ChromiumRuntimeProbeError.navigationFailed(
                        "\(operation): \(error.localizedDescription)"
                    )
                }
                if let status = delegate.rendererTerminationStatus {
                    throw ChromiumRuntimeProbeError.rendererTerminated(
                        status.rawValue
                    )
                }
            }
            guard Date() < deadline else {
                throw ChromiumRuntimeProbeError.timedOut(operation)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func shutdown(_ engine: ChromiumEngine) async {
        await withCheckedContinuation { continuation in
            engine.shutdown(completion: {
                continuation.resume()
            })
        }
    }
}

// MARK: - History probes

extension ChromiumRuntimeProbe {
    private struct HistoryResult {
        let backURL: URL
        let forwardURL: URL
    }

    /// IDE previews commonly use the History API instead of full document
    /// loads. CEF reports those through OnAddressChange, so the native host's
    /// Back/Forward state must refresh on that callback as well.
    private static func verifySameDocumentHistory(
        host: ChromiumBrowserHostView,
        delegate: ChromiumRuntimeProbeDelegate,
        pageURL: URL,
        timeout: TimeInterval
    ) async throws {
        var components = URLComponents(
            url: pageURL,
            resolvingAgainstBaseURL: false
        )
        components?.fragment = "cockpit-spa-route"
        guard let pushedURL = components?.url else {
            throw ChromiumRuntimeProbeError.javaScriptRejected(
                "same-document history URL"
            )
        }
        let historyStateChangeCount = delegate.historyStateChangeCount
        guard host.executeJavaScript(
            "history.pushState({}, '', '#cockpit-spa-route');",
            sourceURL: pageURL,
            line: 1
        ) else {
            throw ChromiumRuntimeProbeError.javaScriptRejected(
                "same-document history"
            )
        }
        try await wait(
            for: "enabling back navigation after History API navigation",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.lastURL == pushedURL
                && delegate.historyStateChangeCount > historyStateChangeCount
                && delegate.lastCanGoBack
                && host.canGoBack
        }

        host.back()
        try await wait(
            for: "navigating backward after History API navigation",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.lastURL == pageURL
                && !host.isLoading
                && host.canGoForward
        }
        logger.notice("Chromium same-document history state observed")
    }

    private static func verifyHistory(
        host: ChromiumBrowserHostView,
        delegate: ChromiumRuntimeProbeDelegate,
        firstURL: URL,
        secondURL: URL,
        timeout: TimeInterval
    ) async throws -> HistoryResult {
        try await wait(
            for: "enabling back navigation",
            timeout: timeout,
            delegates: [delegate]
        ) {
            host.canGoBack
        }
        logger.notice("Navigating backward through Chromium history")
        host.back()
        try await wait(
            for: "navigating backward through Chromium history",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.lastURL == firstURL
                && !host.isLoading
                && host.canGoForward
        }
        let backURL = delegate.lastURL ?? firstURL

        logger.notice("Navigating forward through Chromium history")
        host.forward()
        try await wait(
            for: "navigating forward through Chromium history",
            timeout: timeout,
            delegates: [delegate]
        ) {
            delegate.lastURL == secondURL
                && !host.isLoading
                && host.canGoBack
        }
        logger.notice("Chromium back and forward history observed")
        return HistoryResult(
            backURL: backURL,
            forwardURL: delegate.lastURL ?? secondURL
        )
    }
}

@MainActor
private enum ChromiumRuntimeTransportSecurityProbe {
    static func verifyRejections(
        host: ChromiumBrowserHostView,
        delegate: ChromiumRuntimeProbeDelegate,
        baseURL: URL,
        invalidCertificateURL: URL,
        timeout: TimeInterval
    ) async throws {
        host.loadURL(
            baseURL.appendingPathComponent("authentication-required")
        )
        try await ChromiumRuntimeProbe.wait(
            for: "rejecting an authentication challenge",
            timeout: timeout,
            delegates: []
        ) {
            delegate.deniedAuthenticationRequests > 0
        }
        delegate.clearExpectedNavigationFailure()
        try await ChromiumRuntimeProbe.navigate(
            host: host,
            delegate: delegate,
            to: baseURL,
            timeout: timeout
        )
        try await ChromiumRuntimeCertificateProbe.verifyRejection(
            host: host,
            delegate: delegate,
            url: invalidCertificateURL,
            timeout: timeout
        )
    }
}

@MainActor
private enum ChromiumRuntimeCertificateProbe {
    static func verifyRejection(
        host: ChromiumBrowserHostView,
        delegate: ChromiumRuntimeProbeDelegate,
        url: URL,
        timeout: TimeInterval
    ) async throws {
        host.loadURL(url)
        do {
            try await ChromiumRuntimeProbe.wait(
                for: "rejecting an invalid TLS certificate",
                timeout: min(timeout, 5),
                delegates: []
            ) {
                !delegate.rejectedCertificateErrors.isEmpty
            }
        } catch {
            throw ChromiumRuntimeProbeError.invalidLifecycle(
                "CEF did not report the invalid TLS certificate; "
                    + "URL: \(delegate.lastURL?.absoluteString ?? "nil"); "
                    + "title: \(delegate.lastTitle ?? "nil"); "
                    + "loading: \(host.isLoading); "
                    + "failure: \(delegate.lastFailure?.localizedDescription ?? "nil")."
            )
        }
        try await ChromiumRuntimeProbe.wait(
            for: "finishing invalid TLS cancellation",
            timeout: timeout,
            delegates: []
        ) {
            !host.isLoading
        }
        delegate.clearExpectedNavigationFailure()
    }
}
