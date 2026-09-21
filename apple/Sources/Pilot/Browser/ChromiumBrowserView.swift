import AppKit
@preconcurrency import ChromiumKit
import SwiftData
import SwiftUI

enum ChromiumBrowserRuntimeState: Equatable, Sendable {
    case starting
    case ready
    case unavailable
    case navigationBlocked
    case navigationFailed
    case rendererTerminated
    case closed
}

/// The narrow Swift-side host boundary used by the Chromium pane.
///
/// Production uses `PilotChromiumBrowserHostView`; tests use a deterministic
/// fake so command ordering and close-during-create behavior do not require
/// starting CEF.
@MainActor
protocol ChromiumBrowserHosting: BrowserControlling {
    var delegate: (any ChromiumBrowserHostViewDelegate)? { get set }
    var isHidden: Bool { get set }
    var onSelect: (() -> Void)? { get set }

    func findText(
        _ text: String,
        forward: Bool,
        matchCase: Bool,
        findNext: Bool
    )
    func stopFindingAndClearSelection(_ clearSelection: Bool)
    func printPage()
    func savePage()
}

@MainActor
extension ChromiumBrowserHostView: BrowserControlling {
    func performBrowserCommand(_ command: BrowserControllerCommand) {
        switch command {
        case let .navigate(url):
            loadURL(url)
        case .back:
            back()
        case .forward:
            forward()
        case .reload:
            reload()
        case .stop:
            stop()
        case let .setZoom(zoom):
            setZoom(
                BrowserZoomConversion.chromiumLevel(
                    forLinearScale: zoom
                )
            )
        case .focus:
            window?.makeFirstResponder(self)
            focusBrowser()
        case let .setDeveloperToolsVisible(isVisible):
            if isVisible {
                openDevTools()
            } else {
                closeDevTools()
            }
        case let .openExternally(url):
            NSWorkspace.shared.open(url)
        case .close:
            close()
        }
    }
}

@MainActor
struct ChromiumBrowserView: NSViewRepresentable {
    @Environment(\.uiZoom) private var uiZoom

    let state: BrowserState
    let navigationRequestID: Int
    let inspectorToggleRequestID: Int
    let findRequestID: Int
    let stopFindingRequestID: Int
    let printRequestID: Int
    let savePageRequestID: Int
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    func makeNSView(context: Context) -> ChromiumBrowserContainerView {
        let container = ChromiumBrowserContainerView()
        container.runtimeState = .starting
        container.isHidden = !isActive
        ChromiumDiagnosticsCenter.shared.recordStarting()
        context.coordinator.container = container
        context.coordinator.onSelect = onSelect
        container.onRetry = { [weak coordinator = context.coordinator] in
            coordinator?.retry()
        }

        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            context.coordinator.runtimeUnavailable(errorCode: nil)
            return container
        }

        let profileLocation = ChromiumProfileLocation(
            applicationSupportDirectory: applicationSupport
        )
        let profileURL = profileLocation.defaultProfileURL

        do {
            try FileManager.default.createDirectory(
                at: profileURL,
                withIntermediateDirectories: true
            )
            guard profileLocation.isManagedProfileDirectory(profileURL) else {
                throw ChromiumProfileSecurityError.unmanagedProfileDirectory
            }
            try ChromiumProfileAccessCoordinator.shared.startEngine(
                profileDirectory: profileURL
            )
        } catch {
            context.coordinator.runtimeUnavailable(
                errorCode: (error as NSError).code
            )
            return container
        }

        guard ChromiumEngine.shared.isRunning else {
            context.coordinator.runtimeUnavailable(errorCode: nil)
            return container
        }

        let host = PilotChromiumBrowserHostView(frame: .zero)
        host.onSelect = onSelect
        container.install(host)
        context.coordinator.attach(
            host,
            navigationRequestID: navigationRequestID,
            inspectorToggleRequestID: inspectorToggleRequestID,
            findRequestID: findRequestID,
            stopFindingRequestID: stopFindingRequestID,
            printRequestID: printRequestID,
            savePageRequestID: savePageRequestID,
            initialURL: initialURL,
            zoom: uiZoom,
            isActive: isActive,
            isSelected: isSelected
        )
        return container
    }

    func updateNSView(
        _ nsView: ChromiumBrowserContainerView,
        context: Context
    ) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(
            navigationRequestID: navigationRequestID,
            inspectorToggleRequestID: inspectorToggleRequestID,
            findRequestID: findRequestID,
            stopFindingRequestID: stopFindingRequestID,
            printRequestID: printRequestID,
            savePageRequestID: savePageRequestID,
            zoom: uiZoom,
            isActive: isActive,
            isSelected: isSelected
        )
        nsView.isHidden = !isActive
    }

    static func dismantleNSView(
        _ nsView: ChromiumBrowserContainerView,
        coordinator: Coordinator
    ) {
        coordinator.close()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, onSelect: onSelect)
    }

    private var initialURL: URL? {
        if let pendingURL = state.pendingURL, pendingURL.scheme != "blau" {
            return pendingURL
        }

        let trimmed = state.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    @MainActor
    final class Coordinator: NSObject, ChromiumBrowserHostViewDelegate {
        let state: BrowserState
        var onSelect: () -> Void
        weak var container: ChromiumBrowserContainerView?
        private weak var host: (any ChromiumBrowserHosting)?
        private var lastNavigationRequestID: Int?
        private var lastInspectorToggleRequestID: Int?
        private var lastFindRequestID: Int?
        private var lastStopFindingRequestID: Int?
        private var lastPrintRequestID: Int?
        private var lastSavePageRequestID: Int?
        private var lastZoom: Double?
        private var wasFocused = false
        private var isActiveAndSelected = false
        private var pendingExternalOpenURL: URL?
        private(set) var lastDiagnostic: ChromiumDiagnosticRecord?

        init(
            state: BrowserState,
            onSelect: @escaping () -> Void
        ) {
            self.state = state
            self.onSelect = onSelect
        }

        func attach(
            _ host: any ChromiumBrowserHosting,
            navigationRequestID: Int,
            inspectorToggleRequestID: Int,
            findRequestID: Int,
            stopFindingRequestID: Int,
            printRequestID: Int,
            savePageRequestID: Int,
            initialURL: URL?,
            zoom: Double,
            isActive: Bool,
            isSelected: Bool
        ) {
            self.host = host
            host.delegate = self
            host.onSelect = onSelect
            container?.runtimeState = .ready
            ChromiumDiagnosticsCenter.shared.recordRunning()
            applyZoom(zoom)
            applyVisibilityAndFocus(isActive: isActive, isSelected: isSelected)

            if state.pendingURL != nil {
                consumeNavigationRequest()
            } else if let initialURL {
                load(initialURL)
            }
            lastNavigationRequestID = navigationRequestID
            lastFindRequestID = findRequestID
            lastStopFindingRequestID = stopFindingRequestID
            lastPrintRequestID = printRequestID
            lastSavePageRequestID = savePageRequestID
            consumeInspectorRequestIfNeeded(requestID: inspectorToggleRequestID)
        }

        func update(
            navigationRequestID: Int,
            inspectorToggleRequestID: Int,
            findRequestID: Int,
            stopFindingRequestID: Int,
            printRequestID: Int,
            savePageRequestID: Int,
            zoom: Double,
            isActive: Bool,
            isSelected: Bool
        ) {
            guard let host else { return }
            host.onSelect = onSelect
            applyZoom(zoom)
            applyVisibilityAndFocus(isActive: isActive, isSelected: isSelected)

            if lastNavigationRequestID != navigationRequestID {
                lastNavigationRequestID = navigationRequestID
                consumeNavigationRequest()
            }
            consumeInspectorRequestIfNeeded(requestID: inspectorToggleRequestID)
            consumeFindRequestIfNeeded(requestID: findRequestID)
            consumeStopFindingRequestIfNeeded(requestID: stopFindingRequestID)
            consumePrintRequestIfNeeded(requestID: printRequestID)
            consumeSavePageRequestIfNeeded(requestID: savePageRequestID)
        }

        func runtimeUnavailable(errorCode: Int?) {
            state.isLoading = false
            state.canGoBack = false
            state.canGoForward = false
            container?.runtimeState = .unavailable
            let diagnostic = ChromiumDiagnosticRecord.make(
                event: .launchRejected,
                errorCode: errorCode
            )
            lastDiagnostic = diagnostic
            ChromiumDiagnosticsCenter.shared.recordInitializationFailure(diagnostic)
        }

        func close() {
            host?.delegate = nil
            host?.performBrowserCommand(.close)
            host = nil
            state.isLoading = false
            state.canGoBack = false
            state.canGoForward = false
            state.estimatedProgress = 0
            container?.runtimeState = .closed
        }

        func retry() {
            if let host {
                container?.runtimeState = .ready
                state.isLoading = true
                host.performBrowserCommand(.reload)
            } else {
                state.requestRuntimeRetry()
            }
        }

        private func consumeNavigationRequest() {
            guard let host, let pendingURL = state.pendingURL else { return }
            defer { state.pendingURL = nil }

            let command = BrowserControllerCommandRouter.command(for: pendingURL)
            switch command {
            case .navigate:
                load(pendingURL)
            case .stop:
                host.performBrowserCommand(command)
                state.isLoading = false
            default:
                host.performBrowserCommand(command)
            }
        }

        private func load(_ url: URL) {
            guard let host else { return }
            let request = ChromiumNavigationRequest(
                url: url,
                hasTrustedUserGesture: true
            )
            switch ChromiumNavigationPolicy.disposition(for: request) {
            case .allowInCurrentPane:
                state.isLoading = true
                container?.runtimeState = .ready
                host.performBrowserCommand(.navigate(url))
            case .requestUserConfirmedExternalOpen:
                confirmExternalOpen(url)
            case .openInNewPane:
                container?.runtimeState = .navigationBlocked
            case .block:
                container?.runtimeState = .navigationBlocked
                lastDiagnostic = ChromiumDiagnosticRecord.make(
                    event: .popupBlocked,
                    url: url
                )
            }
        }

        private func confirmExternalOpen(_ url: URL) {
            guard confirmExternalOpenRequest(url) else { return }
            NSWorkspace.shared.open(url)
        }

        private func confirmExternalOpenRequest(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased() ?? "external"
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Open link in another application?"
            alert.informativeText = "Chromium requested a \(scheme) link."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        private func consumeInspectorRequestIfNeeded(requestID: Int) {
            guard lastInspectorToggleRequestID != requestID else { return }
            lastInspectorToggleRequestID = requestID
            guard state.needsInspectorToggle else { return }
            state.needsInspectorToggle = false
            if state.showDevTools,
               ChromiumDevToolsPolicy.productionDefault.disposition(
                   for: .trustedUserAction
               ) == .openManagedLocalInspector {
                host?.performBrowserCommand(.setDeveloperToolsVisible(true))
            } else {
                host?.performBrowserCommand(.setDeveloperToolsVisible(false))
            }
        }

        private func consumeFindRequestIfNeeded(requestID: Int) {
            guard lastFindRequestID != requestID else { return }
            lastFindRequestID = requestID
            guard !state.findQuery.isEmpty else { return }
            host?.findText(
                state.findQuery,
                forward: state.findForward,
                matchCase: state.findMatchCase,
                findNext: state.findNext
            )
        }

        private func consumeStopFindingRequestIfNeeded(requestID: Int) {
            guard lastStopFindingRequestID != requestID else { return }
            lastStopFindingRequestID = requestID
            host?.stopFindingAndClearSelection(true)
        }

        private func consumePrintRequestIfNeeded(requestID: Int) {
            guard lastPrintRequestID != requestID else { return }
            lastPrintRequestID = requestID
            host?.printPage()
        }

        private func consumeSavePageRequestIfNeeded(requestID: Int) {
            guard lastSavePageRequestID != requestID else { return }
            lastSavePageRequestID = requestID
            host?.savePage()
        }

        private func applyZoom(_ zoom: Double) {
            guard let host, lastZoom != zoom else { return }
            lastZoom = zoom
            host.performBrowserCommand(.setZoom(zoom))
        }

        private func applyVisibilityAndFocus(
            isActive: Bool,
            isSelected: Bool
        ) {
            guard let host else { return }
            host.isHidden = !isActive
            let shouldFocus = isActive && isSelected
            isActiveAndSelected = shouldFocus
            if shouldFocus, !wasFocused {
                DispatchQueue.main.async { [weak host] in
                    guard let host, !host.isHidden else { return }
                    host.performBrowserCommand(.focus)
                }
            }
            wasFocused = shouldFocus
        }

        @objc(chromiumBrowserHostView:decideNavigationToURL:userGesture:isRedirect:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            decideNavigationTo url: URL,
            userGesture: Bool,
            isRedirect: Bool
        ) -> ChromiumNavigationDecision {
            MainActor.assumeIsolated {
                _ = browserView
                _ = isRedirect
                let request = ChromiumNavigationRequest(
                    url: url,
                    hasTrustedUserGesture: userGesture
                )
                switch ChromiumNavigationPolicy.disposition(for: request) {
                case .allowInCurrentPane:
                    return .allow
                case .requestUserConfirmedExternalOpen:
                    pendingExternalOpenURL = url
                    return .openExternally
                case .openInNewPane:
                    openManagedPopup(url, activate: true)
                    return .cancel
                case .block:
                    recordBlockedNavigation(url)
                    return .cancel
                }
            }
        }

        @objc(chromiumBrowserHostView:didRequestPopup:disposition:userGesture:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didRequestPopup url: URL,
            disposition: ChromiumPopupDisposition,
            userGesture: Bool
        ) {
            MainActor.assumeIsolated {
                let target: ChromiumNavigationTarget
                let activate: Bool
                switch disposition {
                case .foregroundTab:
                    target = .newPane
                    activate = true
                case .backgroundTab:
                    target = .newPane
                    activate = false
                case .popup:
                    target = .popup
                    activate = true
                case .window:
                    target = .newWindow
                    activate = true
                case .unknown:
                    target = .popup
                    activate = false
                @unknown default:
                    target = .popup
                    activate = false
                }

                let request = ChromiumNavigationRequest(
                    url: url,
                    target: target,
                    hasTrustedUserGesture: userGesture
                )
                switch ChromiumNavigationPolicy.disposition(for: request) {
                case .openInNewPane:
                    openManagedPopup(url, activate: activate)
                case .requestUserConfirmedExternalOpen:
                    confirmExternalOpen(url)
                case .allowInCurrentPane:
                    browserView.loadURL(url)
                case .block:
                    recordBlockedNavigation(url)
                }
            }
        }

        @objc(chromiumBrowserHostView:shouldOpenExternalURL:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            shouldOpenExternalURL url: URL
        ) -> Bool {
            MainActor.assumeIsolated {
                _ = browserView
                guard pendingExternalOpenURL == url else { return false }
                pendingExternalOpenURL = nil
                return confirmExternalOpenRequest(url)
            }
        }

        @objc(chromiumBrowserHostView:didRequestPermission:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didRequestPermission request: ChromiumPermissionRequest
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                handlePermissionRequest(request)
            }
        }

        private func handlePermissionRequest(
            _ request: ChromiumPermissionRequest
        ) {
            guard let origin = ChromiumOrigin(url: request.origin),
                  let requestedPermissions =
                    ChromiumPermissionBridge.policyKinds(
                        for: request.kinds
                    ) else {
                request.deny()
                recordPermissionDenial(originURL: request.origin)
                return
            }

            let unresolved = requestedPermissions.filter {
                ChromiumPermissionDecisionStore.shared.recordedDecision(
                    for: $0,
                    origin: origin
                ) == nil
            }
            if !unresolved.isEmpty {
                let decision = promptForPermissions(
                    unresolved,
                    origin: origin
                )
                for permission in unresolved {
                    _ = ChromiumPermissionDecisionStore.shared.recordUserDecision(
                        decision,
                        for: permission,
                        origin: origin
                    )
                }
            }

            guard requestedPermissions.allSatisfy({
                ChromiumPermissionDecisionStore.shared.decision(
                    for: $0,
                    origin: origin
                ) == .allow
            }) else {
                request.deny()
                recordPermissionDenial(originURL: request.origin)
                return
            }
            request.allow()
        }

        private func promptForPermissions(
            _ permissions: [ChromiumPermissionKind],
            origin: ChromiumOrigin
        ) -> ChromiumPermissionDecision {
            let names = permissions.map {
                switch $0 {
                case .camera: "camera"
                case .microphone: "microphone"
                default: $0.rawValue
                }
            }.joined(separator: " and ")
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Allow \(names) access?"
            alert.informativeText =
                "\(origin.serialized) is requesting access. This decision applies only to this origin for this made session."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            return alert.runModal() == .alertFirstButtonReturn ? .allow : .deny
        }

        private func recordPermissionDenial(originURL: URL) {
            lastDiagnostic = ChromiumDiagnosticRecord.make(
                event: .permissionDenied,
                url: originURL
            )
        }

        @objc(chromiumBrowserHostView:shouldDownloadURL:suggestedFilename:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            shouldDownloadURL url: URL,
            suggestedFilename: String
        ) -> Bool {
            MainActor.assumeIsolated {
                _ = browserView
                return ChromiumUserInteractionPolicy.allowsDownload(
                    url: url,
                    suggestedFilename: suggestedFilename,
                    isActiveAndSelected: isActiveAndSelected
                )
            }
        }

        @objc(chromiumBrowserHostViewShouldPresentFileChooser:)
        nonisolated func chromiumBrowserHostViewShouldPresentFileChooser(
            _ browserView: ChromiumBrowserHostView
        ) -> Bool {
            MainActor.assumeIsolated {
                _ = browserView
                return ChromiumUserInteractionPolicy.allowsFileChooser(
                    isActiveAndSelected: isActiveAndSelected
                )
            }
        }

        @objc(chromiumBrowserHostView:shouldPresentContextMenu:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            shouldPresentContextMenu request: ChromiumContextMenuRequest
        ) -> Bool {
            MainActor.assumeIsolated {
                _ = browserView
                _ = request
                return ChromiumUserInteractionPolicy.allowsContextMenu(
                    isActiveAndSelected: isActiveAndSelected
                )
            }
        }

        @objc(chromiumBrowserHostView:didUpdateFindMatchCount:activeMatchOrdinal:finalUpdate:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didUpdateFindMatchCount matchCount: Int,
            activeMatchOrdinal: Int,
            finalUpdate: Bool
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                _ = finalUpdate
                state.findMatchCount = max(0, matchCount)
                state.activeFindMatchOrdinal = max(0, activeMatchOrdinal)
            }
        }

        @objc(chromiumBrowserHostViewShouldPrint:)
        nonisolated func chromiumBrowserHostViewShouldPrint(
            _ browserView: ChromiumBrowserHostView
        ) -> Bool {
            MainActor.assumeIsolated {
                _ = browserView
                return ChromiumUserInteractionPolicy.allowsPrint(
                    isActiveAndSelected: isActiveAndSelected
                )
            }
        }

        @objc(chromiumBrowserHostView:shouldSavePageURL:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            shouldSavePageURL url: URL
        ) -> Bool {
            MainActor.assumeIsolated {
                _ = browserView
                return ChromiumUserInteractionPolicy.allowsSavePage(
                    url: url,
                    isActiveAndSelected: isActiveAndSelected
                )
            }
        }

        @objc(chromiumBrowserHostView:didUpdateDownloadWithIdentifier:URL:suggestedFilename:receivedBytes:totalBytes:percentComplete:state:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didUpdateDownloadWithIdentifier identifier: UInt,
            url: URL,
            suggestedFilename: String,
            receivedBytes: Int64,
            totalBytes: Int64,
            percentComplete: Int,
            state downloadState: ChromiumDownloadState
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                _ = identifier
                _ = url
                _ = receivedBytes
                _ = totalBytes
                switch downloadState {
                case .inProgress:
                    state.downloadStatusText = "Downloading \(suggestedFilename)"
                    state.downloadProgress = percentComplete >= 0
                        ? min(max(Double(percentComplete) / 100, 0), 1)
                        : nil
                case .complete:
                    state.downloadStatusText = "Downloaded \(suggestedFilename)"
                    state.downloadProgress = nil
                case .canceled:
                    state.downloadStatusText = "Download canceled"
                    state.downloadProgress = nil
                case .interrupted:
                    state.downloadStatusText = "Download interrupted"
                    state.downloadProgress = nil
                @unknown default:
                    state.downloadStatusText = "Download status unavailable"
                    state.downloadProgress = nil
                }
            }
        }

        @objc(chromiumBrowserHostView:didRejectAuthenticationForURL:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didRejectAuthenticationFor url: URL?
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                lastDiagnostic = ChromiumDiagnosticRecord.make(
                    event: .navigationFailed,
                    errorCode: 401,
                    url: url
                )
            }
        }

        @objc(chromiumBrowserHostView:didRejectCertificateError:forURL:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didRejectCertificateError errorCode: Int,
            for url: URL?
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                lastDiagnostic = ChromiumDiagnosticRecord.make(
                    event: .navigationFailed,
                    errorCode: errorCode,
                    url: url
                )
            }
        }

        @objc(chromiumBrowserHostView:didRejectClientCertificateForHost:port:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didRejectClientCertificateForHost hostName: String,
            port: Int
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                _ = hostName
                lastDiagnostic = ChromiumDiagnosticRecord.make(
                    event: .navigationFailed,
                    errorCode: port
                )
            }
        }

        private func openManagedPopup(_ url: URL, activate: Bool) {
            guard let modelContext = state.modelContext,
                  let panes = try? modelContext.fetch(FetchDescriptor<Pane>()),
                  let owner = panes.first(where: { $0.browserState === state }),
                  let workspace = owner.workspace else {
                recordBlockedNavigation(url)
                return
            }

            let previousSelection = workspace.selectedPaneID
            let pane = workspace.addBrowserPane(engine: .chromium, side: .right)
            guard let popupState = pane.browserState else {
                recordBlockedNavigation(url)
                return
            }
            popupState.urlText = url.absoluteString
            popupState.requestNavigationCommand(url.absoluteString)
            if !activate {
                workspace.selectedPaneID = previousSelection
                _ = modelContext.saveReporting(operation: "Opening Chromium popup")
            }
        }

        private func recordBlockedNavigation(_ url: URL?) {
            container?.runtimeState = .navigationBlocked
            lastDiagnostic = ChromiumDiagnosticRecord.make(
                event: .popupBlocked,
                url: url
            )
        }

        @objc(chromiumBrowserHostViewDidCreate:)
        nonisolated func chromiumBrowserHostViewDidCreate(
            _ browserView: ChromiumBrowserHostView
        ) {
            MainActor.assumeIsolated {
                container?.runtimeState = .ready
                ChromiumDiagnosticsCenter.shared.recordRunning()
                if isActiveAndSelected {
                    browserView.focusBrowser()
                }
            }
        }

        @objc(chromiumBrowserHostView:didChangeURL:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didChange url: URL
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                state.acceptCommittedURL(url)
                state.commitFaviconPage(url)
            }
        }

        @objc(chromiumBrowserHostView:didChangeFaviconURLs:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didChangeFaviconURLs urls: [URL]
        ) {
            MainActor.assumeIsolated {
                guard host === browserView else { return }
                state.updateFaviconURLs(urls, for: browserView.url)
            }
        }

        @objc(chromiumBrowserHostView:didChangeTitle:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didChangeTitle title: String?
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                state.title = title ?? ""
            }
        }

        @objc(chromiumBrowserHostView:didChangeLoading:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didChangeLoading isLoading: Bool
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                state.isLoading = isLoading
                if isLoading {
                    container?.runtimeState = .ready
                    ChromiumDiagnosticsCenter.shared.recordRunning()
                } else {
                    state.estimatedProgress = 1
                }
            }
        }

        @objc(chromiumBrowserHostView:didChangeProgress:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didChangeProgress progress: Double
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                state.estimatedProgress = min(max(progress, 0), 1)
            }
        }

        @objc(chromiumBrowserHostView:didChangeCanGoBack:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didChangeCanGoBack canGoBack: Bool
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                state.canGoBack = canGoBack
            }
        }

        @objc(chromiumBrowserHostView:didChangeCanGoForward:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didChangeCanGoForward canGoForward: Bool
        ) {
            MainActor.assumeIsolated {
                _ = browserView
                state.canGoForward = canGoForward
            }
        }

        @objc(chromiumBrowserHostView:didFailNavigationWithError:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            didFailNavigationWithError error: any Error
        ) {
            MainActor.assumeIsolated {
                let nsError = error as NSError
                state.isLoading = false
                state.estimatedProgress = 0
                container?.runtimeState = .navigationFailed
                lastDiagnostic = ChromiumDiagnosticRecord.make(
                    event: .navigationFailed,
                    errorCode: nsError.code,
                    url: browserView.url
                )
            }
        }

        @objc(chromiumBrowserHostView:rendererTerminatedWithStatus:)
        nonisolated func chromiumBrowserHostView(
            _ browserView: ChromiumBrowserHostView,
            rendererTerminatedWith status: ChromiumRendererTerminationStatus
        ) {
            MainActor.assumeIsolated {
                state.isLoading = false
                state.canGoBack = false
                state.canGoForward = false
                state.estimatedProgress = 0
                container?.runtimeState = .rendererTerminated
                let diagnostic = ChromiumDiagnosticRecord.make(
                    event: .rendererTerminated,
                    errorCode: status.rawValue,
                    url: browserView.url
                )
                lastDiagnostic = diagnostic
                ChromiumDiagnosticsCenter.shared.recordRendererTermination(
                    diagnostic
                )
            }
        }

        @objc(chromiumBrowserHostViewDidClose:)
        nonisolated func chromiumBrowserHostViewDidClose(
            _ browserView: ChromiumBrowserHostView
        ) {
            MainActor.assumeIsolated {
                state.isLoading = false
                state.canGoBack = false
                state.canGoForward = false
                state.estimatedProgress = 0
                container?.runtimeState = .closed
                lastDiagnostic = ChromiumDiagnosticRecord.make(
                    event: .browserClosed,
                    url: browserView.url
                )
            }
        }
    }
}

@MainActor
final class ChromiumPermissionDecisionStore {
    static let shared = ChromiumPermissionDecisionStore()

    private var policy = ChromiumOriginPermissionPolicy()

    private init() {}

    func decision(
        for permission: ChromiumPermissionKind,
        origin: ChromiumOrigin
    ) -> ChromiumPermissionDecision {
        policy.decision(for: permission, origin: origin)
    }

    func recordedDecision(
        for permission: ChromiumPermissionKind,
        origin: ChromiumOrigin
    ) -> ChromiumPermissionDecision? {
        policy.recordedDecision(for: permission, origin: origin)
    }

    @discardableResult
    func recordUserDecision(
        _ decision: ChromiumPermissionDecision,
        for permission: ChromiumPermissionKind,
        origin: ChromiumOrigin
    ) -> Bool {
        policy.recordUserDecision(
            decision,
            for: permission,
            origin: origin
        )
    }

    func removeDecisions(for origin: ChromiumOrigin) {
        policy.removeDecisions(for: origin)
    }

    func removeAllDecisions() {
        policy.removeAllDecisions()
    }
}

@MainActor
final class ChromiumBrowserContainerView: NSView {
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var retryButton = NSButton(
        title: "Retry",
        target: self,
        action: #selector(retry)
    )

    var onRetry: (@MainActor () -> Void)?

    var runtimeState: ChromiumBrowserRuntimeState = .starting {
        didSet { updateMessage() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        addSubview(messageLabel)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded
        addSubview(retryButton)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: -16
            ),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.topAnchor.constraint(
                equalTo: messageLabel.bottomAnchor,
                constant: 12
            ),
        ])
        updateMessage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func install(_ host: ChromiumBrowserHostView) {
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host, positioned: .below, relativeTo: messageLabel)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        runtimeState = .ready
    }

    @objc
    private func retry() {
        onRetry?()
    }

    private func updateMessage() {
        switch runtimeState {
        case .starting:
            messageLabel.stringValue = "Starting Chromium..."
            messageLabel.isHidden = false
            retryButton.isHidden = true
        case .ready:
            messageLabel.stringValue = ""
            messageLabel.isHidden = true
            retryButton.isHidden = true
        case .unavailable:
            messageLabel.stringValue = "Chromium is unavailable in this build. WebKit browsers remain available."
            messageLabel.isHidden = false
            retryButton.isHidden = false
        case .navigationBlocked:
            messageLabel.stringValue = "Chromium blocked this navigation."
            messageLabel.isHidden = false
            retryButton.isHidden = true
        case .navigationFailed:
            messageLabel.stringValue = "Chromium could not load this page."
            messageLabel.isHidden = false
            retryButton.isHidden = false
        case .rendererTerminated:
            messageLabel.stringValue = "The Chromium renderer stopped. Reload to try again."
            messageLabel.isHidden = false
            retryButton.isHidden = false
        case .closed:
            messageLabel.stringValue = "Chromium browser closed."
            messageLabel.isHidden = false
            retryButton.isHidden = true
        }
    }
}

@MainActor
final class PilotChromiumBrowserHostView:
    ChromiumBrowserHostView,
    ChromiumBrowserHosting {
    var onSelect: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        super.mouseDown(with: event)
    }
}
