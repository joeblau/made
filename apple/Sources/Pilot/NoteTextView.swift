import AppKit
import SwiftUI

/// `NSTextView`-backed editor with live GitHub-Flavored-Markdown styling. We
/// drop out of SwiftUI's `TextEditor` for two reasons: driving `selectedRanges`
/// directly (⇧⌘L multi-cursor), and attaching a `MarkdownStyler` as the text
/// storage delegate so markdown renders in place as you type. The raw markdown
/// source stays editable and is what we persist — only attributes change.
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let wordWrapColumns: Int?
    let onCopySecret: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MultiCursorTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? MultiCursorTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.allowsUndo = true
        // Rich so our programmatic attributes render reliably; the user can't
        // introduce their own formatting (no Format menu) and we store plain
        // `.string`, so the document stays markdown source either way.
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Wider horizontal inset carves out a left gutter for the secret lock.
        textView.textContainerInset = NSSize(width: 28, height: 10)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        let styler = context.coordinator.styler
        styler.baseSize = fontSize
        textView.textStorage?.delegate = styler

        // Touching `layoutManager` forces TextKit 1, which the secret-masking
        // glyph substitution (and checkbox hit-testing) depend on.
        let maskController = context.coordinator.maskController
        maskController.textView = textView
        textView.maskController = maskController
        textView.onCopySecret = onCopySecret
        textView.layoutManager?.delegate = maskController

        textView.string = text
        if let storage = textView.textStorage {
            styler.style(storage)
        }
        maskController.refresh()
        // Sort any already-completed tasks to the bottom of their group, and
        // align every markdown table, on load.
        DispatchQueue.main.async {
            textView.reorderCompletedTasks()
            textView.formatMarkdownTables(protectingCaret: false)
        }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        applyWordWrap(to: textView, in: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MultiCursorTextView else { return }
        let styler = context.coordinator.styler

        if styler.baseSize != fontSize {
            styler.baseSize = fontSize
            textView.typingAttributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            if let storage = textView.textStorage {
                styler.style(storage)
            }
        }

        applyWordWrap(to: textView, in: scrollView)

        // Only overwrite when the model diverges from the view (e.g. an
        // external edit) — never on the user's own keystrokes, which would
        // stomp the cursor(s). Setting `.string` re-triggers styling via the
        // storage delegate.
        if textView.string != text {
            textView.string = text
        }
    }

    private func applyWordWrap(to textView: NSTextView, in scrollView: NSScrollView) {
        guard let textContainer = textView.textContainer else { return }

        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false

        if let wordWrapColumns {
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            let lineWidth = ceil(characterWidth * CGFloat(wordWrapColumns))
                + (textContainer.lineFragmentPadding * 2)

            textView.isHorizontallyResizable = false
            textContainer.containerSize = NSSize(
                width: lineWidth,
                height: .greatestFiniteMagnitude
            )
            scrollView.hasHorizontalScroller = false
        } else {
            textView.isHorizontallyResizable = true
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.hasHorizontalScroller = true
        }

        textView.layoutManager?.ensureLayout(for: textContainer)
        textView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: NoteTextView
        let styler: MarkdownStyler
        let maskController = EnvMaskController()

        init(_ parent: NoteTextView) {
            self.parent = parent
            self.styler = MarkdownStyler(baseSize: parent.fontSize)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MultiCursorTextView else { return }
            parent.text = textView.string
            maskController.refresh()
            textView.applyAutomaticReflows()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Reveal the secret on the line being edited, re-mask the rest.
            maskController.refresh()
        }
    }
}
