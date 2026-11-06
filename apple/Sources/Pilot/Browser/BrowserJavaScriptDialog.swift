import AppKit

// JavaScript alert, confirm, prompt, and beforeunload dialogs from a browser
// pane, presented as a sheet on the pane's window. CEF's default dialog is a
// free-floating alert whose glass sampled the page behind it (3.3:1 text in
// dark mode over a white page), and its beforeunload buttons read OK/Cancel.
//
// Every page-provided string is untrusted: it is capped, stripped of control
// and bidirectional-override characters, and rendered as verbatim text. The
// title names the requesting origin, never page-provided text.

enum BrowserJavaScriptDialogKind: Equatable, Sendable {
    case alert
    case confirm
    case prompt(defaultText: String)
    case beforeUnload(isReload: Bool)
}

/// The sanitized, display-ready content of one dialog. Pure, so labels and
/// sanitizing are unit tested without a browser engine.
struct BrowserJavaScriptDialogContent: Equatable, Sendable {
    /// Upper bound, in Unicode scalars, for page text shown in a dialog or
    /// prefilled into a prompt. Chrome's own dialogs also elide long text.
    static let maximumTextLength = 1_000
    /// More consecutive line breaks than this collapse, so a page cannot
    /// push its message off the sheet with blank lines.
    static let maximumConsecutiveLineBreaks = 2
    static let beforeUnloadMessage = "Changes you made may not be saved."

    let kind: BrowserJavaScriptDialogKind
    let title: String
    /// The origin a beforeunload sheet names under its title; nil for the
    /// script dialogs, whose title already names it.
    let originLine: String?
    let message: String
    let confirmTitle: String
    /// Nil for alert, which only acknowledges.
    let cancelTitle: String?
    /// Whether confirming discards page state (beforeunload's Leave/Reload).
    let confirmIsDestructive: Bool

    init(kind: BrowserJavaScriptDialogKind, originURL: URL?, message: String) {
        let origin = Self.originName(for: originURL)
        switch kind {
        case .alert, .confirm, .prompt:
            title = origin.map { "\($0) says" } ?? "This page says"
            originLine = nil
            self.message = Self.sanitized(message, allowsLineBreaks: true)
        case let .beforeUnload(isReload):
            title = isReload ? "Reload site?" : "Leave site?"
            originLine = origin
            // Chromium ignores custom beforeunload text; so does Pilot.
            self.message = Self.beforeUnloadMessage
        }
        switch kind {
        case .alert:
            self.kind = kind
            confirmTitle = "OK"
            cancelTitle = nil
            confirmIsDestructive = false
        case .confirm:
            self.kind = kind
            confirmTitle = "OK"
            cancelTitle = "Cancel"
            confirmIsDestructive = false
        case let .prompt(defaultText):
            self.kind = .prompt(defaultText: Self.sanitized(defaultText, allowsLineBreaks: false))
            confirmTitle = "OK"
            cancelTitle = "Cancel"
            confirmIsDestructive = false
        case let .beforeUnload(isReload):
            self.kind = kind
            confirmTitle = isReload ? "Reload" : "Leave"
            cancelTitle = "Stay"
            confirmIsDestructive = true
        }
    }

    var promptDefaultText: String? {
        if case let .prompt(defaultText) = kind { return defaultText }
        return nil
    }

    /// The host (and non-default port) for web origins, like Chrome's
    /// "example.com says". Anything else (data:, blob:, file:, about:,
    /// extension pages) reads as "This page", so no page-chosen text can
    /// appear in the title.
    static func originName(for url: URL?) -> String? {
        guard let url, let origin = ChromiumOrigin(url: url) else { return nil }
        let host = sanitized(origin.host, allowsLineBreaks: false, limit: 253)
        guard !host.isEmpty else { return nil }
        let displayedHost = host.contains(":") ? "[\(host)]" : host
        return origin.port.map { "\(displayedHost):\($0)" } ?? displayedHost
    }

    /// Caps `text` at `limit` scalars (marking the cut with an ellipsis),
    /// removes control, format-control, and bidirectional-override
    /// characters, and normalizes line breaks.
    static func sanitized(
        _ text: String,
        allowsLineBreaks: Bool,
        limit: Int = maximumTextLength
    ) -> String {
        var scalars = String.UnicodeScalarView()
        var kept = 0
        // Bound the work by the input, not just the output: a page could
        // send megabytes of characters that are all stripped.
        var examined = 0
        var consecutiveLineBreaks = 0
        var previousWasCarriageReturn = false
        var truncated = false
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard kept < limit, examined < limit * 4 else {
                truncated = true
                break
            }
            examined += 1
            let isCarriageReturn = scalar == "\r"
            defer { previousWasCarriageReturn = isCarriageReturn }
            if scalar == "\n", previousWasCarriageReturn {
                continue // "\r\n" is one break.
            }
            if isCarriageReturn || scalar == "\n" || scalar == "\u{2028}" || scalar == "\u{2029}" {
                consecutiveLineBreaks += 1
                if !allowsLineBreaks {
                    scalars.append(" ")
                    kept += 1
                } else if consecutiveLineBreaks <= maximumConsecutiveLineBreaks {
                    scalars.append("\n")
                    kept += 1
                }
                continue
            }
            if isStripped(scalar) { continue }
            consecutiveLineBreaks = 0
            scalars.append(scalar == "\t" ? " " : scalar)
            kept += 1
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if truncated { result += "…" }
        return result
    }

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control:
            return scalar != "\t"
        case .surrogate, .privateUse, .unassigned:
            return true
        case .format:
            // Keep the joiners emoji sequences need; drop every other
            // invisible format character, including the bidi overrides
            // (U+202A–U+202E, U+2066–U+2069) that can reorder text.
            return scalar != "\u{200D}" && scalar != "\u{200C}" && scalar != "\u{FE0F}"
        default:
            return false
        }
    }
}

/// One dialog awaiting the user's answer. It answers the page exactly once:
/// accept, cancel, or cancel-on-release.
@MainActor
final class BrowserJavaScriptDialog: Identifiable {
    let id = UUID()
    let content: BrowserJavaScriptDialogContent
    private var respond: ((_ accepted: Bool, _ input: String?) -> Void)?
    /// Clears the pane's slot after an answer so the sheet dismisses.
    var onFinish: (() -> Void)?

    init(
        content: BrowserJavaScriptDialogContent,
        respond: @escaping (_ accepted: Bool, _ input: String?) -> Void
    ) {
        self.content = content
        self.respond = respond
    }

    var isResolved: Bool { respond == nil }

    func accept(input: String? = nil) {
        finish(accepted: true, input: content.promptDefaultText == nil ? nil : (input ?? ""))
    }

    func cancel() {
        finish(accepted: false, input: nil)
    }

    private func finish(accepted: Bool, input: String?) {
        guard let respond else { return }
        self.respond = nil
        respond(accepted, input)
        let onFinish = onFinish
        self.onFinish = nil
        onFinish?()
    }
}

/// Bounds dialog spam: a page that opens more than `limit` dialogs within
/// `window` has the rest cancelled until its next page load, like Chrome's
/// "prevent this page from creating additional dialogs".
struct BrowserJavaScriptDialogThrottle {
    static let limit = 5
    static let window: TimeInterval = 10

    private var recent: [Date] = []
    private(set) var isSuppressing = false

    mutating func admit(at now: Date) -> Bool {
        guard !isSuppressing else { return false }
        recent = recent.filter { now.timeIntervalSince($0) < Self.window }
        guard recent.count < Self.limit else {
            isSuppressing = true
            recent.removeAll()
            return false
        }
        recent.append(now)
        return true
    }

    mutating func reset() {
        recent.removeAll()
        isSuppressing = false
    }
}

extension BrowserState {
    var javaScriptDialog: BrowserJavaScriptDialog? {
        get { runtime.javaScriptDialog }
        set { runtime.javaScriptDialog = newValue }
    }

    /// Shows a page dialog in this pane. Returns nil, after answering Cancel,
    /// when another dialog is still waiting: a browser runs one at a time.
    @MainActor
    @discardableResult
    func presentJavaScriptDialog(
        _ content: BrowserJavaScriptDialogContent,
        respond: @escaping (_ accepted: Bool, _ input: String?) -> Void
    ) -> BrowserJavaScriptDialog? {
        guard javaScriptDialog == nil else {
            respond(false, nil)
            return nil
        }
        let dialog = BrowserJavaScriptDialog(content: content, respond: respond)
        dialog.onFinish = { [weak self, weak dialog] in
            guard let self, let dialog, self.javaScriptDialog === dialog else { return }
            self.javaScriptDialog = nil
        }
        javaScriptDialog = dialog
        return dialog
    }
}

/// Native sheet ownership is separate from the page callback. Closing a pane
/// or replacing its dialog cancels the callback exactly once.
@MainActor
final class BrowserJavaScriptDialogPresenter {
    let dialog: BrowserJavaScriptDialog
    private var alert: NSAlert?
    private weak var parent: NSWindow?

    init(dialog: BrowserJavaScriptDialog) { self.dialog = dialog }

    func present(on window: NSWindow) {
        guard alert == nil, !dialog.isResolved else { return }
        let content = dialog.content
        let alert = NSAlert()
        self.alert = alert
        parent = window
        alert.messageText = content.title
        alert.informativeText = [content.originLine, content.message].compactMap { $0 }.joined(separator: "\n\n")
        alert.alertStyle = content.confirmIsDestructive ? .warning : .informational
        var input: NSTextField?
        if let text = content.promptDefaultText {
            let field = NSTextField(string: text)
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
            field.setAccessibilityLabel("Response")
            field.setAccessibilityIdentifier("browser.javascript-dialog.response")
            alert.accessoryView = field
            input = field
        }
        if content.confirmIsDestructive, let cancelTitle = content.cancelTitle {
            alert.addButton(withTitle: cancelTitle)
            alert.addButton(withTitle: content.confirmTitle)
            alert.buttons[0].setAccessibilityIdentifier("browser.javascript-dialog.cancel")
            alert.buttons[1].setAccessibilityIdentifier("browser.javascript-dialog.confirm")
            alert.buttons[1].keyEquivalent = ""
        } else {
            alert.addButton(withTitle: content.confirmTitle)
            alert.buttons[0].setAccessibilityIdentifier("browser.javascript-dialog.confirm")
            if let cancelTitle = content.cancelTitle {
                alert.addButton(withTitle: cancelTitle)
                alert.buttons[1].setAccessibilityIdentifier("browser.javascript-dialog.cancel")
            }
        }
        alert.window.setAccessibilityIdentifier("browser.javascript-dialog")
        alert.beginSheetModal(for: window) { [weak self, input] result in
            guard let self else { return }
            self.alert = nil
            let confirmed = content.confirmIsDestructive ? result == .alertSecondButtonReturn : result == .alertFirstButtonReturn
            if confirmed { self.dialog.accept(input: input?.stringValue) } else { self.dialog.cancel() }
        }
        if let input { alert.window.makeFirstResponder(input) }
    }

    func dismiss() {
        if let alert, let parent { parent.endSheet(alert.window, returnCode: .abort) }
        alert = nil
        dialog.cancel()
    }

    isolated deinit { dismiss() }
}
