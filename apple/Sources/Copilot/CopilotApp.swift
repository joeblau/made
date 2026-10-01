import SwiftUI
import WatchConnectivity
import UserNotifications
import OSLog
import UIKit

private let copilotConnectivityLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.blau.copilot",
    category: "WatchConnectivity"
)

enum WingmanGesturePayload {
    static let gestureKey = "gesture"
    static let doublePinch = "doublePinch"
    static let commandIDKey = "commandID"
    static let sentAtKey = "sentAt"
    static let maximumAge: TimeInterval = 3

    struct Command: Sendable {
        let id: UUID
        let sentAt: Date
    }

    static func command(from payload: [String: Any]) -> Command? {
        guard payload[gestureKey] as? String == doublePinch,
              let idString = payload[commandIDKey] as? String,
              let id = UUID(uuidString: idString),
              let timestamp = payload[sentAtKey] as? Double,
              timestamp.isFinite else { return nil }
        return Command(id: id, sentAt: Date(timeIntervalSince1970: timestamp))
    }
}

enum WingmanCommandDecision: Equatable {
    case acceptAndExecute
    case acknowledgeDuplicate
    case rejectStale
    case rejectUnavailable
}

/// A tiny, deterministic idempotency boundary for time-sensitive Watch
/// commands. Duplicate live deliveries are acknowledged (so a lost reply can
/// be retried safely) but are never executed twice.
struct WingmanCommandLedger {
    private(set) var accepted: [UUID: Date] = [:]

    mutating func decide(
        _ command: WingmanGesturePayload.Command,
        now: Date,
        isPilotConnected: Bool
    ) -> WingmanCommandDecision {
        accepted = accepted.filter {
            now.timeIntervalSince($0.value) <= WingmanGesturePayload.maximumAge
        }

        let age = now.timeIntervalSince(command.sentAt)
        guard age >= -1, age <= WingmanGesturePayload.maximumAge else {
            return .rejectStale
        }
        if accepted[command.id] != nil {
            return .acknowledgeDuplicate
        }
        guard isPilotConnected else {
            return .rejectUnavailable
        }
        accepted[command.id] = now
        return .acceptAndExecute
    }
}

/// WatchConnectivity imports its Objective-C reply block without Sendable
/// conformance. The framework owns and serializes this callback; wrapping it
/// makes that contract explicit at the Swift concurrency boundary.
private struct WingmanReplyHandler: @unchecked Sendable {
    let call: ([String: Any]) -> Void
}

@Observable
final class PhoneSessionDelegate: NSObject, WCSessionDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var isWatchReachable = false
    var syncService: PeerSyncService?
    private var wingmanLedger = WingmanCommandLedger()

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            copilotConnectivityLogger.error("WCSession activation failed: \(error.localizedDescription, privacy: .public)")
        } else {
            let isWatchReachable = session.isReachable
            copilotConnectivityLogger.info(
                """
                WCSession activated. state=\(String(describing: activationState), privacy: .public) \
                reachable=\(isWatchReachable, privacy: .public)
                """
            )
            Task { @MainActor in
                self.updateWatchReachability(isWatchReachable)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        copilotConnectivityLogger.info("WCSession became inactive.")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        copilotConnectivityLogger.info("WCSession deactivated. Reactivating default session.")
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWingmanPayload(message, transport: "sendMessage")
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = WingmanGesturePayload.command(from: message) else {
            replyHandler(["status": "invalid"])
            return
        }
        let reply = WingmanReplyHandler(call: replyHandler)
        Task { @MainActor in
            let accepted = self.acceptWingmanCommand(command, transport: "sendMessageWithReply")
            reply.call([
                "status": accepted ? "accepted" : "rejected",
                "receivedAt": Date().timeIntervalSince1970
            ])
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        // Terminal controls are intentionally live-only. Ignore queued payloads
        // from older Wingman builds instead of pressing Enter after reconnect.
        copilotConnectivityLogger.notice("Ignored queued Trigger transferUserInfo payload.")
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        copilotConnectivityLogger.notice("Ignored queued Trigger applicationContext payload.")
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isWatchReachable = session.isReachable
        copilotConnectivityLogger.info("Reachability changed. reachable=\(isWatchReachable, privacy: .public)")
        Task { @MainActor in
            self.updateWatchReachability(isWatchReachable)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        copilotConnectivityLogger.info("Presenting Trigger notification while app is foregrounded.")
        completionHandler([.banner, .list, .sound])
    }

    private func handleWingmanPayload(_ payload: [String: Any], transport: String) {
        guard let command = WingmanGesturePayload.command(from: payload) else { return }
        Task { @MainActor in
            _ = self.acceptWingmanCommand(command, transport: transport)
        }
    }

    @MainActor
    @discardableResult
    private func acceptWingmanCommand(_ command: WingmanGesturePayload.Command, transport: String) -> Bool {
        let now = Date()
        switch wingmanLedger.decide(
            command,
            now: now,
            isPilotConnected: syncService?.isConnected == true
        ) {
        case .rejectStale:
            copilotConnectivityLogger.notice("Rejected stale Trigger command over \(transport, privacy: .public).")
            return false
        case .rejectUnavailable:
            copilotConnectivityLogger.notice("Rejected Trigger command because Cockpit is disconnected.")
            return false
        case .acknowledgeDuplicate:
            copilotConnectivityLogger.info("Acknowledged already-executed Trigger command over \(transport, privacy: .public).")
            return true
        case .acceptAndExecute:
            copilotConnectivityLogger.info("Accepted fresh double pinch over \(transport, privacy: .public). Forwarding as Enter to Cockpit.")
            PhoneSessionDelegate.playDoublePinchHaptic()
            syncService?.send(.terminalInput(.enter))
            return true
        }
    }

    @MainActor
    private static func playDoublePinchHaptic() {
        copilotConnectivityLogger.info("Playing double pinch haptic feedback.")
        let feedback = UINotificationFeedbackGenerator()
        feedback.prepare()
        feedback.notificationOccurred(.success)
    }

    @MainActor
    private func updateWatchReachability(_ isReachable: Bool) {
        self.isWatchReachable = isReachable
    }
}

@main
struct CopilotApp: App {
    @State private var syncService = PeerSyncService(
        role: .browser,
        displayName: UIDevice.current.name
    )
    @State private var phoneSessionDelegate = PhoneSessionDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView(
                syncService: syncService,
                watchDelegate: phoneSessionDelegate
            )
            .task {
                phoneSessionDelegate.syncService = syncService
            }
        }
    }

    init() {
        let delegate = PhoneSessionDelegate()
        _phoneSessionDelegate = State(initialValue: delegate)

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = delegate

        if WCSession.isSupported() {
            copilotConnectivityLogger.info("Activating default WCSession for Walkie.")
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        } else {
            copilotConnectivityLogger.error("WCSession is not supported on this device.")
        }

        // Skip the permission prompt in demo mode so it doesn't cover the UI in
        // captured screenshots. Check the launch arguments directly too, since
        // the UserDefaults argument domain may not be applied yet this early.
        let demoMode = UserDefaults.standard.bool(forKey: "demoMode")
            || ProcessInfo.processInfo.arguments.contains("-demoMode")
        if !demoMode {
            notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    copilotConnectivityLogger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    copilotConnectivityLogger.info("Notification authorization granted=\(granted, privacy: .public)")
                }
            }
        }
    }
}
