import SwiftUI

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

/// The sheet for one page dialog. It is opaque window background, not glass
/// over the page, so its text keeps system contrast whatever the page shows;
/// its controls are the shared glass field and capsule buttons.
struct BrowserJavaScriptDialogSheet: View {
    let dialog: BrowserJavaScriptDialog

    @State private var input: String
    @FocusState private var isFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(dialog: BrowserJavaScriptDialog) {
        self.dialog = dialog
        _input = State(initialValue: dialog.content.promptDefaultText ?? "")
    }

    private var content: BrowserJavaScriptDialogContent { dialog.content }

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.medium) {
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Text(verbatim: content.title)
                    .font(.headline)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let originLine = content.originLine {
                    Text(verbatim: originLine)
                        .font(.subheadline)
                        // The parent hierarchy does not reach a child's own
                        // `.secondary`, which measured 3.95:1 in light mode.
                        .glassLegibleForeground(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !content.message.isEmpty {
                ScrollView {
                    Text(verbatim: content.message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
            }

            if content.promptDefaultText != nil {
                TextField("Response", text: $input)
                    .accessibilityLabel("Response")
                    .focused($isFieldFocused)
                    .onSubmit { dialog.accept(input: input) }
                    .liquidGlassField(isFocused: isFieldFocused)
            }

            CompatGlassContainer(spacing: 0) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Spacer()
                    buttons
                }
            }
            .padding(.top, LiquidGlassMetrics.Spacing.xxSmall)
        }
        .padding(LiquidGlassMetrics.Spacing.xLarge)
        .frame(width: 400)
        .legibleSecondaryHierarchy()
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled()
        .onExitCommand { dialog.cancel() }
        .onAppear { isFieldFocused = content.promptDefaultText != nil }
        // Any dismissal that did not answer (window closed, pane removed)
        // answers Cancel, so the page never stays blocked.
        .onDisappear { dialog.cancel() }
        .accessibilityIdentifier("browser.javascript-dialog")
    }

    /// The darkened red on the light capsule (4.8:1). System red on the dark
    /// capsule measured 3.4:1, so dark mode uses a lighter red (4.8:1).
    private var destructiveLabelColor: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 1, green: 0.54, blue: 0.5)
            : DashboardTone.red.adaptiveColor
    }

    @ViewBuilder
    private var buttons: some View {
        if content.confirmIsDestructive, let cancelTitle = content.cancelTitle {
            // beforeunload: staying keeps the user's work, so Stay is the
            // default (Return) action and the single prominent button; Leave
            // is destructive and never the default.
            Button(content.confirmTitle, role: .destructive) { dialog.accept() }
                .compatGlassButtonStyle()
                .foregroundStyle(destructiveLabelColor)
                .accessibilityIdentifier("browser.javascript-dialog.confirm")
            Button(cancelTitle) { dialog.cancel() }
                .keyboardShortcut(.defaultAction)
                .compatGlassProminentButtonStyle()
                .accessibilityIdentifier("browser.javascript-dialog.cancel")
        } else {
            if let cancelTitle = content.cancelTitle {
                Button(cancelTitle, role: .cancel) { dialog.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .compatGlassButtonStyle()
                    .accessibilityIdentifier("browser.javascript-dialog.cancel")
            }
            Button(content.confirmTitle) { dialog.accept(input: input) }
                .keyboardShortcut(.defaultAction)
                .compatGlassProminentButtonStyle()
                .accessibilityIdentifier("browser.javascript-dialog.confirm")
        }
    }
}
