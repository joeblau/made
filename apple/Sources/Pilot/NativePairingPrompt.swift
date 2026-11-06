import AppKit

/// A prompt decision is consumed before its callback runs. Window-close,
/// disconnect, and delayed sheet-completion callbacks can therefore never
/// approve an already-cancelled request or resolve it twice.
@MainActor
final class NativePairingDecision {
    private var completion: ((Bool) -> Void)?

    init(completion: @escaping (Bool) -> Void) { self.completion = completion }

    func resolve(approved: Bool) {
        guard let completion else { return }
        self.completion = nil
        completion(approved)
    }
}

@MainActor
final class PairingPromptCoordinator {
    @MainActor
    private final class Request {
        let id: UUID
        let title: String
        let message: String
        weak var window: NSWindow?
        let decision: NativePairingDecision

        init(id: UUID, title: String, message: String, window: NSWindow, completion: @escaping (Bool) -> Void) {
            self.id = id
            self.title = title
            self.message = message
            self.window = window
            decision = NativePairingDecision(completion: completion)
        }
    }

    private var queue: [Request] = []
    private var active: Request?
    private var alert: NSAlert?
    private var isShutDown = false
    nonisolated(unsafe) private var closeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var sheetObserver: NSObjectProtocol?

    init() {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let closingWindow = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window = closingWindow else { return }
                self?.cancelRequests(for: window)
            }
        }
        sheetObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // AppKit may post during its sheet teardown. The next main-actor
            // turn sees the owner after attachedSheet has been cleared.
            Task { @MainActor [weak self] in self?.presentNext() }
        }
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    }

    /// Returns false for a duplicate ID. A new request without a usable owner
    /// is explicitly rejected rather than shown as an unowned modal dialog.
    @discardableResult
    func present(id: UUID, title: String, message: String, window: NSWindow?, completion: @escaping (Bool) -> Void) -> Bool {
        guard active?.id != id, !queue.contains(where: { $0.id == id }) else { return false }
        guard !isShutDown, let window else { completion(false); return false }
        queue.append(Request(id: id, title: title, message: message, window: window, completion: completion))
        presentNext()
        return true
    }

    func cancel(id: UUID) { finish(id: id, approved: false) }

    func cancelAll() {
        let pending = queue
        queue.removeAll()
        pending.forEach { $0.decision.resolve(approved: false) }
        if let active { finish(id: active.id, approved: false) }
    }

    func shutdown() {
        isShutDown = true
        cancelAll()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
        sheetObserver = nil
    }

    private func cancelRequests(for window: NSWindow) {
        let cancelled = queue.filter { $0.window === window }
        queue.removeAll { $0.window === window }
        cancelled.forEach { $0.decision.resolve(approved: false) }
        if let active, active.window === window { finish(id: active.id, approved: false) }
    }

    private func presentNext() {
        guard !isShutDown, active == nil, !queue.isEmpty else { return }
        let request = queue[0]
        guard let window = request.window else {
            queue.removeFirst()
            request.decision.resolve(approved: false)
            presentNext()
            return
        }
        // Save/open panels and other app-owned sheets retain their modal
        // focus. A pairing request waits for that sheet to finish.
        guard window.attachedSheet == nil else { return }
        queue.removeFirst()
        active = request
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.message
        alert.addButton(withTitle: "Pair")
        let reject = alert.addButton(withTitle: "Reject")
        // Pairing must be deliberate: Return does not approve a prompt that
        // appeared while someone was typing in the underlying terminal.
        alert.buttons[0].keyEquivalent = ""
        reject.keyEquivalent = "\u{1b}"
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.finish(id: request.id, approved: response == .alertFirstButtonReturn)
        }
    }

    private func finish(id: UUID, approved: Bool) {
        if let request = active, request.id == id {
            let sheet = alert?.window
            active = nil
            alert = nil
            if let sheet, let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: .cancel) }
            request.decision.resolve(approved: approved)
            presentNext()
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            let request = queue.remove(at: index)
            request.decision.resolve(approved: false)
        }
    }
}
