import SwiftUI
import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

private struct WingmanDoublePinchPayload: Sendable {
    let commandID: UUID
    let source: String
    let sentAt: Double

    var dictionary: [String: Any] {
        [
            "gesture": "doublePinch",
            "commandID": commandID.uuidString,
            "source": source,
            "sentAt": sentAt
        ]
    }
}

@Observable
@MainActor
final class WatchSessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    var isReachable = false
    var deliveryStatus = "Ready"
    private var deliveryState = WingmanDeliveryState()
    private var replyTimeoutTask: Task<Void, Never>?

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if error == nil {
            let isReachable = session.isReachable
            Task { @MainActor in
                self.updateReachability(isReachable)
            }
        }
    }

    // `WCSessionDelegate` declares these as required in the Swift import
    // even though the headers mark them `__WATCHOS_UNAVAILABLE`. Empty
    // stubs satisfy the conformance for any iOS slice (e.g. Designed
    // for iPad) that ever picks up this file. Compiling them under
    // watchOS would fail with "marked unavailable", so the iOS guard.
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.updateReachability(isReachable)
        }
    }

    @MainActor
    private func updateReachability(_ isReachable: Bool) {
        if self.isReachable != isReachable { self.isReachable = isReachable }
        if !isReachable, !deliveryState.isInFlight, deliveryStatus != "Walkie unavailable" {
            deliveryStatus = "Walkie unavailable"
        }
    }

    func sendDoublePinch(source: String) {
        let session = WCSession.default
        guard !deliveryState.isInFlight else {
            deliveryStatus = "Still sending…"
            play(.failure)
            return
        }
        let payload = WingmanDoublePinchPayload(
            commandID: UUID(),
            source: source,
            sentAt: Date().timeIntervalSince1970
        )

        guard session.activationState == .activated else {
            deliveryStatus = "Walkie unavailable"
            play(.failure)
            return
        }

        // `isCompanionAppInstalled` only exists on watchOS — the
        // counterpart iPhone always has the Watch app considered
        // "installed" from its perspective.
        #if os(watchOS)
        guard session.isCompanionAppInstalled else {
            deliveryStatus = "Install Walkie first"
            play(.failure)
            return
        }
        #endif

        guard session.isReachable else {
            deliveryStatus = "Walkie unavailable"
            play(.failure)
            return
        }

        guard deliveryState.begin(commandID: payload.commandID) else { return }
        deliveryStatus = "Sending…"
        transmit(
            payload,
            sentAt: Date(timeIntervalSince1970: payload.sentAt),
            attempt: 0
        )
    }

    private func transmit(
        _ payload: WingmanDoublePinchPayload,
        sentAt: Date,
        attempt: Int
    ) {
        let commandID = payload.commandID
        guard deliveryState.isCurrent(commandID: commandID, attempt: attempt) else { return }
        replyTimeoutTask?.cancel()
        replyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: WingmanDeliveryRetryPolicy.replyTimeout)
            guard !Task.isCancelled else { return }
            self?.retryOrFail(
                payload,
                sentAt: sentAt,
                attempt: attempt
            )
        }

        WCSession.default.sendMessage(payload.dictionary, replyHandler: { [weak self] reply in
            let accepted = reply["status"] as? String == "accepted"
            Task { @MainActor in
                self?.finish(commandID: commandID, attempt: attempt, accepted: accepted)
            }
        }, errorHandler: { [weak self] _ in
            // Retry once immediately over the live path, reusing the same ID.
            // Copilot acknowledges the duplicate without pressing Enter twice.
            Task { @MainActor in
                self?.retryOrFail(
                    payload,
                    sentAt: sentAt,
                    attempt: attempt
                )
            }
        })
    }

    private func retryOrFail(
        _ payload: WingmanDoublePinchPayload,
        sentAt: Date,
        attempt: Int
    ) {
        let commandID = payload.commandID
        let session = WCSession.default
        switch deliveryState.decideRetry(
            commandID: commandID,
            attempt: attempt,
            sentAt: sentAt,
            now: Date(),
            isReachable: session.isReachable
        ) {
        case .retry(let nextAttempt):
            deliveryStatus = "Confirming…"
            transmit(
                payload,
                sentAt: sentAt,
                attempt: nextAttempt
            )
        case .fail:
            finish(
                commandID: commandID,
                attempt: attempt,
                accepted: false,
                unavailable: !session.isReachable
            )
        case .ignoreStaleCallback:
            break
        }
    }

    private func finish(
        commandID: UUID,
        attempt: Int,
        accepted: Bool,
        unavailable: Bool = false
    ) {
        guard deliveryState.finish(
            commandID: commandID,
            attempt: attempt,
            accepted: accepted
        ) else { return }
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        deliveryStatus = accepted ? "Delivered" : (unavailable ? "Walkie unavailable" : "Not delivered")
        play(accepted ? .success : .failure)
    }

    private enum DeliveryHaptic {
        case success
        case failure
    }

    private func play(_ haptic: DeliveryHaptic) {
        #if os(watchOS)
        switch haptic {
        case .success: WKInterfaceDevice.current().play(.success)
        case .failure: WKInterfaceDevice.current().play(.failure)
        }
        #endif
    }
}

@main
struct WingmanApp: App {
    @State private var sessionDelegate = WatchSessionDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView(sessionDelegate: sessionDelegate)
        }
    }

    init() {
        let delegate = WatchSessionDelegate()
        _sessionDelegate = State(initialValue: delegate)

        // Demo mode: skip activating the live WatchConnectivity session
        // so the app renders fixture content with no real peer. Guarded
        // so a normal launch (no arg) activates the session as before.
        let isDemoMode = UserDefaults.standard.bool(forKey: "demoMode")
        if !isDemoMode, WCSession.isSupported() {
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        }
    }
}
