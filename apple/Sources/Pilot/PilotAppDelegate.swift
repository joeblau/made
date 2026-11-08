import AppKit
@preconcurrency import ChromiumKit

/// What quitting must do about a Chromium engine in a given state.
///
/// CEF must close browsers and finish shutdown before process exit. The
/// application delegate keeps the normal event loop running while that completes.
enum ChromiumTerminationPolicy: Equatable {
    /// Nothing is running, or the shutdown already finished or timed out.
    case terminateNow
    /// Cancel this request, shut the engine down, then quit again.
    case shutDownFirst
    /// A shutdown started by an earlier request is still running.
    case alreadyPending

    /// Bounds the wait so a browser that never finishes closing cannot leave
    /// Cockpit unable to quit. Exiting without `CefShutdown` is what an
    /// unclean exit does anyway; helper processes exit when the browser
    /// process goes away.
    static let shutdownTimeout: Duration = .seconds(5)

    /// How long the main thread may go without answering once the shutdown
    /// timeout has passed before the quit backstop ends the process.
    static let mainThreadResponseTimeout: Duration = .seconds(1)

    /// - Parameters:
    ///   - shutdownPending: a shutdown for an earlier quit request is running.
    ///   - shutdownFinished: that shutdown completed or timed out, so the
    ///     follow-up quit must go through even if the engine is still closing.
    ///   - systemPoweringOff: logout, restart or shutdown is in progress.
    ///     Cancelling a quit then would abort the logout, so Cockpit exits
    ///     without the clean CEF shutdown, as it would on any unclean exit.
    static func decision(
        engineState: ChromiumEngineState,
        shutdownPending: Bool,
        shutdownFinished: Bool = false,
        systemPoweringOff: Bool = false
    ) -> Self {
        if shutdownFinished || systemPoweringOff { return .terminateNow }
        switch engineState {
        case .notStarted, .failed, .shutDown:
            return .terminateNow
        case .initializing, .running, .shuttingDown:
            return shutdownPending ? .alreadyPending : .shutDownFirst
        @unknown default:
            return shutdownPending ? .alreadyPending : .shutDownFirst
        }
    }
}

private extension Duration {
    /// Whole and fractional seconds, for Dispatch deadlines.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

@MainActor
final class PilotAppDelegate: NSObject, NSApplicationDelegate {
    private var application: PilotApp?
    private var pendingURLs: [URL] = []
    private var quitPreflightPending = false
    private var quitPrepared = false
    private var shutdownPending = false
    private var shutdownFinished = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any Chromium pane can start the engine, so every event that
        // CEF can observe is dispatched through the wrapped -sendEvent:.
        #if BLAU_CHROMIUM_CEF_ENABLED
        ChromiumEngine.installApplicationIntegration()
        // Before the engine starts, so a page an extension opens at startup
        // is routed too.
        WalletPopupController.shared.installExtensionPageRouting()
        #endif
    }

    /// True when the quit being asked about comes from logout, restart or
    /// shutdown. Read from the quit Apple Event itself rather than a sticky
    /// `willPowerOff` flag, so a logout that is cancelled elsewhere cannot
    /// make a later ⌘Q skip the clean shutdown.
    private var isSystemPowerOffQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        let systemReasons: Set<OSType> = [
            OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
            OSType(kAEShowShutdownDialog), OSType(kAERestart), OSType(kAEShutDown),
        ]
        return systemReasons.contains(reason)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitPrepared, !isSystemPowerOffQuit, application?.validateCloseReadiness() == false {
            quitPrepared = false
        }
        if !quitPrepared, !isSystemPowerOffQuit {
            guard !quitPreflightPending else { return .terminateCancel }
            quitPreflightPending = true
            prepareToQuit { [weak self] approved in
                guard let self else { return }
                quitPreflightPending = false
                guard approved else { return }
                quitPrepared = true
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return .terminateCancel
        }
        #if BLAU_CHROMIUM_CEF_ENABLED
        let engine = ChromiumEngine.shared
        switch ChromiumTerminationPolicy.decision(
            engineState: engine.state,
            shutdownPending: shutdownPending,
            shutdownFinished: shutdownFinished,
            systemPoweringOff: isSystemPowerOffQuit
        ) {
        case .terminateNow:
            return finalTerminationReply()
        case .alreadyPending:
            return .terminateCancel
        case .shutDownFirst:
            break
        }
        shutdownPending = true
        engine.shutdown(completion: { [weak self] in
            // ChromiumEngine invokes completions on the main thread.
            MainActor.assumeIsolated { self?.finishShutdown() }
        })
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ChromiumTerminationPolicy.shutdownTimeout)
            self?.finishShutdown()
        }
        Self.startUnresponsiveMainThreadBackstop()
        return .terminateCancel
        #else
        return finalTerminationReply()
        #endif
    }

    private func finalTerminationReply() -> NSApplication.TerminateReply {
        guard !isSystemPowerOffQuit else { return .terminateNow }
        guard application?.saveForFinalTermination() != false else {
            quitPrepared = false
            return .terminateCancel
        }
        return .terminateNow
    }

    /// The timeout above runs on the main thread, so it cannot help when
    /// Chromium blocks that thread itself. Observed in the macOS 27 VM: with
    /// the GPU helper stopped, closing a pane's browser (`DoClose` removing
    /// its view) waits in a synchronous Mach message to the GPU process, and
    /// Cockpit never quit. This off-main check ends the process only when the
    /// main thread has not answered for `mainThreadResponseTimeout` after the
    /// shutdown timeout, which is a hung quit by definition; a responsive main
    /// thread is left to finish (or cancel) the quit normally.
    private nonisolated static func startUnresponsiveMainThreadBackstop() {
        let queue = DispatchQueue(label: "app.blau.pilot.quit-backstop", qos: .userInitiated)
        queue.asyncAfter(deadline: .now() + ChromiumTerminationPolicy.shutdownTimeout.timeInterval) {
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            let deadline = DispatchTime.now()
                + ChromiumTerminationPolicy.mainThreadResponseTimeout.timeInterval
            if answered.wait(timeout: deadline) == .timedOut {
                // No clean CefShutdown is possible from here; this is the
                // unclean exit the timeout already accepts. `_exit` skips
                // atexit handlers that could wait on the same stuck thread.
                _exit(EXIT_SUCCESS)
            }
        }
    }

    /// Re-issues the quit exactly once, whichever of shutdown completion and
    /// the timeout arrives first.
    private func finishShutdown() {
        guard shutdownPending else { return }
        shutdownPending = false
        shutdownFinished = true
        // Outside the engine's completion callout, which may still be
        // iterating its completion list.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted tests construct isolated stores/controllers themselves.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let isolated = ProcessInfo.processInfo.environment["BLAU_COCKPIT_FIXTURE"] != nil
            || UserDefaults.standard.bool(forKey: "demoMode")
        application = PilotApp(isolated: isolated)
        application?.start()
        if !isolated { MobileDeviceCache.shared.warmUp() }
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach { application?.openDashboard($0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        application?.showMain()
        return true
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let application else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        urls.forEach { application.openDashboard($0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        application?.stop()
    }

    private func prepareToQuit(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let application else { completion(true); return }
        let finish: @MainActor (Bool) -> Void = { approved in
            guard approved else { completion(false); return }
            application.commitPendingEdits()
            completion(application.modelContainer.mainContext.saveReporting(operation: "Saving Cockpit before quit"))
        }
        let prepareExtension: @MainActor (Bool) -> Void = { approved in
            guard approved else { completion(false); return }
            if let window = application.extensionWindow {
                window.prepareForTermination(completion: finish)
            } else { finish(true) }
        }
        if let window = application.mainWindow {
            window.prepareForTermination(completion: prepareExtension)
        } else { prepareExtension(true) }
    }
}
