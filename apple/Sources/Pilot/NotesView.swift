import AppKit
import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pilotNoteTab = UTType(exportedAs: "app.blau.pilot.note-tab")
}

/// The note whose tab is being dragged to reorder it. A dedicated Transferable
/// type — rather than the note's bare UUID string — keeps the drag from being
/// confused with generic text drags (which is why a plain-`String` payload
/// dropped unreliably), and mirrors the workspace pane tabs' drag payload.
struct NoteTabTransfer: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pilotNoteTab)
    }
}

private enum NoteWordWrap: Int, CaseIterable, Identifiable {
    case eighty = 80
    case oneTwenty = 120
    case none = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .eighty: "80 characters"
        case .oneTwenty: "120 characters"
        case .none: "None"
        }
    }

    var compactTitle: String {
        switch self {
        case .eighty: "80"
        case .oneTwenty: "120"
        case .none: "None"
        }
    }

    var columnCount: Int? {
        self == .none ? nil : rawValue
    }
}

/// Detail-area view for the global Notes mode (toggled with ⌘0). Renders a
/// horizontal tab bar of notes across the top with a text editor below for
/// the selected note — the same shape as the browser/terminal tab strip.
struct NotesView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("notes.wordWrap") private var wordWrapRawValue = NoteWordWrap.eighty.rawValue
    @State private var showCopiedToast = false
    @State private var toastDismiss: DispatchWorkItem?
    /// Tab the dragged note would be inserted before; drives the insertion marker.
    @State private var dropTargetNoteID: UUID?

    var body: some View {
        let notes = store.notes
        VStack(spacing: 0) {
            tabBar(notes: notes)
            secretStorageDisclosure
            editor
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                CopiedSecretToast()
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { store.notePendingClose != nil },
                set: { if !$0 { store.notePendingClose = nil } }
            ),
            presenting: store.notePendingClose
        ) { note in
            Button("Delete Note", role: .destructive) {
                store.deleteNote(note)
                store.notePendingClose = nil
            }
            Button("Cancel", role: .cancel) { store.notePendingClose = nil }
        } message: { note in
            Text("“\(note.displayTitle)” will be permanently deleted. This can’t be undone.")
        }
    }

    private var secretStorageDisclosure: some View {
        Label(
            "Secret masking is visual only. Notes are stored locally as plaintext—do not use Notes as a secret manager.",
            systemImage: "eye.slash"
        )
        .scaledFont(size: 11)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityLabel(
            "Security notice: secret masking is visual only. Notes are stored locally as plaintext."
        )
    }

    private func flashCopiedToast() {
        toastDismiss?.cancel()
        withAnimation(.snappy(duration: 0.18)) { showCopiedToast = true }
        let work = DispatchWorkItem {
            withAnimation(.snappy(duration: 0.3)) { showCopiedToast = false }
        }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func tabBar(notes: [Note]) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                CompatGlassContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(notes) { note in
                            NoteTab(
                                title: note.displayTitle,
                                isSelected: note.id == store.selectedNoteID,
                                isDropTarget: dropTargetNoteID == note.id,
                                onSelect: { store.selectedNoteID = note.id },
                                onClose: { store.requestCloseNote(note) }
                            )
                            // Drag-to-reorder (issue #67). The note rides along as a
                            // dedicated Transferable payload; dropping onto another tab
                            // inserts the dragged note just before it and persists the
                            // new order.
                            .draggable(NoteTabTransfer(id: note.id)) {
                                // Legible chip under the cursor while dragging.
                                Text(note.displayTitle)
                                    .scaledFont(size: 12)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        .ultraThinMaterial,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                            }
                            .dropDestination(for: NoteTabTransfer.self) { items, _ in
                                dropTargetNoteID = nil
                                guard let dragged = items.first else { return false }
                                store.moveNote(dragged.id, before: note.id)
                                return true
                            } isTargeted: { targeted in
                                dropTargetNoteID = targeted ? note.id : nil
                            }
                        }

                        Button {
                            store.addNote()
                        } label: {
                            Image(systemName: "plus")
                                .scaledFont(size: 12, weight: .medium)
                        }
                        .compatGlassButtonStyle()
                        .buttonBorderShape(.circle)
                        .foregroundStyle(.primary)
                        .help("New Note")
                        // Dropping a tab on (or past) the + button sends it to the end.
                        .dropDestination(for: NoteTabTransfer.self) { items, _ in
                            guard let dragged = items.first else { return false }
                            store.moveNoteToEnd(dragged.id)
                            return true
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            wordWrapMenu
                .padding(.horizontal, 12)
        }
    }

    private var selectedWordWrap: NoteWordWrap {
        NoteWordWrap(rawValue: wordWrapRawValue) ?? .eighty
    }

    private var wordWrapMenu: some View {
        Menu {
            ForEach(NoteWordWrap.allCases) { option in
                Button {
                    wordWrapRawValue = option.rawValue
                } label: {
                    if option == selectedWordWrap {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Label("Word Wrap: \(selectedWordWrap.compactTitle)", systemImage: "text.word.spacing")
                .scaledFont(size: 11, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Word Wrap")
    }

    @ViewBuilder
    private var editor: some View {
        if let note = store.selectedNote {
            NoteEditor(
                note: note,
                wordWrapColumns: selectedWordWrap.columnCount,
                onCopySecret: flashCopiedToast
            )
                // Re-create the editor when the selected note changes so the
                // text view rebinds cleanly instead of reusing stale state.
                .id(note.id)
        } else {
            ContentUnavailableView(
                "No Note",
                systemImage: "note.text",
                description: Text("Create a note with the + button.")
            )
        }
    }
}

private struct NoteEditor: View {
    @Bindable var note: Note
    let wordWrapColumns: Int?
    let onCopySecret: () -> Void
    @Environment(\.uiZoom) private var uiZoom

    var body: some View {
        NoteTextView(
            text: $note.body,
            fontSize: 13 * uiZoom,
            wordWrapColumns: wordWrapColumns,
            onCopySecret: onCopySecret
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: note.body) {
                _ = note.modelContext?.saveReporting(operation: "Saving note")
            }
    }
}

/// `NSTextView`-backed editor with live GitHub-Flavored-Markdown styling. We
/// drop out of SwiftUI's `TextEditor` for two reasons: driving `selectedRanges`
/// directly (⇧⌘L multi-cursor), and attaching a `MarkdownStyler` as the text
/// storage delegate so markdown renders in place as you type. The raw markdown
/// source stays editable and is what we persist — only attributes change.
private struct NoteTextView: NSViewRepresentable {
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
            textView.reorderCompletedTasks()
            textView.formatMarkdownTables()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Reveal the secret on the line being edited, re-mask the rest.
            maskController.refresh()
        }
    }
}

/// Borderless SF Symbol button used for the editor's gutter affordances.
private final class GutterButton: NSButton {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A small color swatch placed just after an inline-code color (e.g. `#00FF3F`).
/// Clicking it copies the color string to the pasteboard.
private final class ColorChipButton: NSButton {
    var onClick: (() -> Void)?
    var swatch: NSColor = .clear { didSet { needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        swatch.setFill()
        path.fill()
        // A hairline border keeps light/white swatches visible against the page.
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Streams and downsamples image data away from the main actor. The byte cap
/// applies while reading, not after allocation, and preview-sized decoding
/// avoids expanding a large source image at full resolution.
private enum MarkdownImagePayload: @unchecked Sendable {
    case raster(CGImage)
    case svg(Data)
}

private actor MarkdownImageLoader {
    static let shared = MarkdownImageLoader()

    private let maximumDownloadBytes = 25 * 1_024 * 1_024
    private let streamChunkBytes = 64 * 1_024
    private let maximumPreviewPixels = 1_440
    private let maximumSVGBytes = 5 * 1_024 * 1_024

    func image(from url: URL) async throws -> MarkdownImagePayload {
        let data = url.isFileURL
            ? try boundedFileData(from: url)
            : try await boundedRemoteData(from: url)
        try Task.checkCancellation()

        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPreviewPixels,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return .raster(image)
            }
        }

        // AppKit supports SVG even though ImageIO doesn't expose it as a
        // raster source. Keep this fallback narrower than the general byte cap
        // because parsing vector markup happens when NSImage is constructed.
        guard data.count <= maximumSVGBytes, Self.looksLikeSVG(data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return .svg(data)
    }

    private nonisolated static func looksLikeSVG(_ data: Data) -> Bool {
        let prefix = data.prefix(64 * 1_024)
        guard let text = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<svg")
    }

    private func boundedRemoteData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .returnCacheDataElseLoad
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if response.expectedContentLength > Int64(maximumDownloadBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumDownloadBytes))
        }
        var chunk: [UInt8] = []
        chunk.reserveCapacity(streamChunkBytes)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count + chunk.count < maximumDownloadBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            chunk.append(byte)
            if chunk.count == streamChunkBytes {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: chunk)
        return data
    }

    private func boundedFileData(from url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maximumDownloadBytes {
            throw URLError(.dataLengthExceedsMaximum)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        if let size = values.fileSize { data.reserveCapacity(size) }
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: streamChunkBytes) ?? Data()
            guard data.count + chunk.count <= maximumDownloadBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
    }
}

/// Async image preview used by the live Markdown editor. Loading and failure
/// states stay visible in the reserved area; only a successful decode calls
/// `onRender`, which enables the matching gutter copy button.
private final class MarkdownImagePreviewView: NSView {
    private static let cache = NSCache<NSURL, NSImage>()

    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var loadTask: Task<Void, Never>?
    private let sourceURL: URL
    private let sourceURLString: String
    private let onRender: (String) -> Void

    init(frame: NSRect, match: MarkdownImage.Match, onRender: @escaping (String) -> Void) {
        sourceURL = match.url
        sourceURLString = match.urlString
        self.onRender = onRender
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel(match.altText.isEmpty ? "Markdown image" : match.altText)
        addSubview(imageView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        addSubview(spinner)

        statusLabel.stringValue = match.altText.isEmpty ? "Loading image…" : "Loading \(match.altText)…"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11)
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 10, dy: 10)
        spinner.frame = NSRect(x: bounds.midX - 8, y: bounds.midY - 18, width: 16, height: 16)
        statusLabel.frame = NSRect(x: 12, y: bounds.midY + 4, width: max(0, bounds.width - 24), height: 18)
    }

    func update(frame: NSRect, altText: String) {
        if self.frame != frame { self.frame = frame }
        imageView.setAccessibilityLabel(altText.isEmpty ? "Markdown image" : altText)
        if !spinner.isHidden {
            statusLabel.stringValue = altText.isEmpty ? "Loading image…" : "Loading \(altText)…"
        }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { loadTask?.cancel() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    func startLoading() {
        guard loadTask == nil, imageView.image == nil else { return }
        loadImage()
    }

    private func loadImage() {
        if let cached = Self.cache.object(forKey: sourceURL as NSURL) {
            show(cached)
            return
        }

        let url = sourceURL
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let decoded = try await MarkdownImageLoader.shared.image(from: url)
                try Task.checkCancellation()
                let image: NSImage
                switch decoded {
                case .raster(let cgImage):
                    image = NSImage(cgImage: cgImage, size: .zero)
                case .svg(let data):
                    guard let svgImage = NSImage(data: data) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    image = svgImage
                }
                Self.cache.setObject(image, forKey: url as NSURL)
                show(image)
            } catch is CancellationError {
                return
            } catch {
                showFailure()
            }
        }
    }

    private func show(_ image: NSImage) {
        guard !Task.isCancelled else { return }
        imageView.image = image
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.isHidden = true
        onRender(sourceURLString)
    }

    private func showFailure() {
        guard !Task.isCancelled else { return }
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        imageView.image = NSImage(
            systemSymbolName: "photo.badge.exclamationmark",
            accessibilityDescription: "Image failed to load"
        )
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        statusLabel.stringValue = "Couldn’t load image"
    }
}

/// `NSTextView` subclass that adds ⇧⌘L "split selection into lines" — the
/// Sublime/VS Code multi-cursor gesture. Each line touched by the selection
/// gets a collapsed insertion point at the end of its selected content;
/// `NSTextView` then types into all of them simultaneously.
final class MultiCursorTextView: NSTextView, NSViewToolTipOwner {
    weak var maskController: EnvMaskController?
    var onCopySecret: (() -> Void)?
    private let lockSize: CGFloat = 16
    private var isReordering = false
    private var gutterButtons: [NSButton] = []
    /// Signature of the gutter buttons currently installed. `layout()` runs on
    /// every display pass; rebuilding the gutter subviews each time
    /// (removeFromSuperview + addSubview) re-dirties Auto Layout and makes the
    /// window perpetually "need another Update Constraints pass", which AppKit
    /// eventually aborts with an NSGenericException. We only touch the subview
    /// tree when this signature actually changes.
    private var gutterSignature = ""
    /// Color swatches placed after inline-code colors, with their own
    /// churn-guard signature (same rationale as `gutterSignature`).
    private var colorChips: [NSButton] = []
    private var colorChipSignature = ""
    /// Inline previews keyed by URL occurrence, so layout changes can move an
    /// in-flight view without cancelling and restarting its download.
    private var imagePreviews: [String: MarkdownImagePreviewView] = [:]
    private var imagePreviewSignature = ""
    /// URLs that have decoded into a real image. A gutter copy button is only
    /// offered after that point, so broken/loading previews don't imply a
    /// successful render.
    private var renderedImageURLs: Set<String> = []
    /// Layout-pass scan caches: `layout()` runs on every scroll/resize pass
    /// and previously re-ran the fenced-block and color-chip regexes over the
    /// whole document each time. The scans depend only on the text, so they
    /// hold until it changes — typing and the programmatic reflows both funnel
    /// through `didChangeText()`, and SwiftUI's binding pushes via `string`.
    private var cachedFencedBlocks: [(range: NSRange, content: String)]?
    private var cachedColorChipMatches: [ColorChip.Match]?
    private var cachedMarkdownImageMatches: [MarkdownImage.Match]?

    /// Keep the editable storage plaintext while exposing the controller's
    /// redacted presentation to assistive technologies. Calling
    /// `setAccessibilityValue` on NSTextView edits the document and emits
    /// `textDidChange`, so masking must be implemented as a getter only.
    override func accessibilityValue() -> String? {
        maskController?.accessibilityText ?? super.accessibilityValue()
    }

    private func invalidateTextScanCaches() {
        cachedFencedBlocks = nil
        cachedColorChipMatches = nil
        cachedMarkdownImageMatches = nil
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateTextScanCaches()
    }

    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            invalidateTextScanCaches()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            splitSelectionIntoLines()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Clicking the hover lock toggles a secret's visibility; clicking a masked
    /// `.env` value copies it; clicking a `[ ]` / `[x]` toggles it. Any other
    /// click behaves normally.
    override func mouseDown(with event: NSEvent) {
        if openLink(at: event) { return }
        if copySecret(at: event) { return }
        if toggleTaskCheckbox(at: event) { return }
        super.mouseDown(with: event)
    }

    /// Single-click on a link (bare URL or markdown link) opens it in the
    /// user's default browser via NSWorkspace.
    private func openLink(at event: NSEvent) -> Bool {
        guard event.clickCount == 1, let layoutManager, let textContainer, let textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction
        )
        // Ignore clicks past the end of the line's text (in the trailing margin).
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard containerPoint.x <= used.maxX else { return false }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < ns.length,
              let value = textStorage.attribute(.link, at: charIndex, effectiveRange: nil) else { return false }
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: - Per-line secret lock toggle (always shown in the left gutter)

    private func lockRect(for match: EnvSecret.Match) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: match.keyRange, actualCharacterRange: nil)
        let keyRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        // Centered in the left gutter (the area left of the text), on the
        // secret's line.
        let x = max(4, (origin.x - lockSize) / 2)
        let y = keyRect.midY + origin.y - lockSize / 2
        return NSRect(x: x, y: y, width: lockSize, height: lockSize)
    }

    override func layout() {
        super.layout()
        layoutMarkdownImages()
        layoutGutterIcons()
        layoutColorChips()
    }

    /// Places a fixed-height, aspect-fit preview below every Markdown image
    /// line. `MarkdownStyler` reserves the matching paragraph space, so these
    /// subviews never cover editable source or surrounding text.
    private func layoutMarkdownImages() {
        guard let layoutManager, let textContainer else { return }
        let ns = string as NSString
        let matches = markdownImages()
        renderedImageURLs.formIntersection(Set(matches.map(\.urlString)))

        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        let availableWidth = max(80, textContainer.containerSize.width - padding * 2)
        let previewWidth = min(720, availableWidth)
        var indicesByLine: [Int: Int] = [:]
        var occurrencesByURL: [String: Int] = [:]

        struct Spec {
            let key: String
            let match: MarkdownImage.Match
            let frame: NSRect
        }
        var specs: [Spec] = []
        for match in matches {
            guard NSMaxRange(match.range) <= ns.length else { continue }
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            let lineIndex = indicesByLine[lineRange.location, default: 0]
            indicesByLine[lineRange.location] = lineIndex + 1

            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            let frame = NSRect(
                x: origin.x + padding,
                y: lineRect.maxY + origin.y + MarkdownImagePresentation.gap
                    + CGFloat(lineIndex) * MarkdownImagePresentation.stride,
                width: previewWidth,
                height: MarkdownImagePresentation.previewHeight
            )
            let occurrence = occurrencesByURL[match.urlString, default: 0]
            occurrencesByURL[match.urlString] = occurrence + 1
            specs.append(Spec(
                key: "\(match.urlString)|\(occurrence)",
                match: match,
                frame: frame
            ))
        }

        let signature = specs.map {
            "\($0.key)|\($0.match.altText)@\(NSStringFromRect($0.frame))"
        }.joined(separator: ";")
        guard signature != imagePreviewSignature else { return }
        imagePreviewSignature = signature

        let liveKeys = Set(specs.map(\.key))
        for key in Array(imagePreviews.keys) where !liveKeys.contains(key) {
            imagePreviews.removeValue(forKey: key)?.removeFromSuperview()
        }
        for spec in specs {
            if let preview = imagePreviews[spec.key] {
                preview.update(frame: spec.frame, altText: spec.match.altText)
                continue
            }
            let preview = MarkdownImagePreviewView(
                frame: spec.frame,
                match: spec.match
            ) { [weak self] renderedURL in
                guard let self,
                      self.imagePreviews[spec.key] != nil,
                      self.markdownImages().contains(where: { $0.urlString == renderedURL }) else { return }
                self.renderedImageURLs.insert(renderedURL)
                self.needsLayout = true
            }
            addSubview(preview)
            imagePreviews[spec.key] = preview
            preview.startLoading()
        }
    }

    private func markdownImages() -> [MarkdownImage.Match] {
        if let cachedMarkdownImageMatches { return cachedMarkdownImageMatches }
        let matches = MarkdownImage.matches(in: string)
        cachedMarkdownImageMatches = matches
        return matches
    }

    /// Places a clickable color swatch just after each inline-code span whose
    /// content is a color (e.g. `#00FF3F`, `rgb(...)`, `oklch(...)`, `cmyk(...)`).
    /// Clicking the swatch copies the color string. Same signature-guard
    /// discipline as the gutter icons so repeated layout passes don't churn the
    /// subview tree.
    private func layoutColorChips() {
        guard let layoutManager, let textContainer else { return }
        let ns = string as NSString
        let chipSize: CGFloat = 12
        let origin = textContainerOrigin

        struct Spec { let value: String; let color: NSColor; let frame: NSRect }
        var specs: [Spec] = []
        let matches: [ColorChip.Match]
        if let cachedColorChipMatches {
            matches = cachedColorChipMatches
        } else {
            matches = ColorChip.matches(in: ns as String)
            cachedColorChipMatches = matches
        }
        for match in matches {
            guard NSMaxRange(match.range) <= ns.length else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            // Sit the swatch just past the end of the code span, vertically centered.
            let frame = NSRect(x: rect.maxX + origin.x + 6,
                               y: rect.midY + origin.y - chipSize / 2,
                               width: chipSize, height: chipSize)
            specs.append(Spec(value: match.value, color: match.color, frame: frame))
        }

        let signature = specs.map { "\($0.value)@\(NSStringFromRect($0.frame))" }
            .joined(separator: ";")
        guard signature != colorChipSignature else { return }
        colorChipSignature = signature

        colorChips.forEach { $0.removeFromSuperview() }
        colorChips.removeAll()
        for spec in specs {
            let chip = ColorChipButton(frame: spec.frame)
            chip.swatch = spec.color
            chip.toolTip = "Copy \(spec.value)"
            let value = spec.value
            chip.onClick = { [weak self] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
                self?.onCopySecret?()
            }
            addSubview(chip)
            colorChips.append(chip)
        }
    }

    /// Gutter affordances are real buttons (custom drawing in `NSTextView.draw`
    /// doesn't composite reliably): a lock per secret line and a copy button per
    /// fenced code block, positioned in the left gutter. They live in the text
    /// view's flipped coordinate space, so they scroll with the content.
    private func layoutGutterIcons() {
        // Build the desired button specs first, derive a signature, and bail
        // before touching the subview tree if nothing changed since the last
        // pass. Mutating subviews inside `layout()` on every pass is what trips
        // the window's Update-Constraints budget (see `gutterSignature`).
        struct Spec {
            let symbol: String
            let tint: NSColor
            let frame: NSRect
            let help: String
            let key: String
            let action: () -> Void
        }
        var specs: [Spec] = []

        if let maskController {
            for secret in maskController.secrets {
                guard let rect = lockRect(for: secret) else { continue }
                let revealed = maskController.isRevealed(secret.key)
                let key = secret.key
                specs.append(Spec(
                    symbol: revealed ? "lock.open.fill" : "lock.fill",
                    tint: revealed ? .controlAccentColor : .secondaryLabelColor,
                    frame: rect,
                    help: revealed ? "Hide value" : "Reveal value",
                    key: "S|\(key)|\(revealed)"
                ) { [weak self] in
                    self?.maskController?.toggleReveal(key)
                })
            }
        }

        for block in fencedBlocks() {
            guard let rect = copyIconRect(for: block.range) else { continue }
            let content = block.content
            specs.append(Spec(
                symbol: "doc.on.doc",
                tint: .secondaryLabelColor,
                frame: rect,
                help: "Copy code block",
                key: "C|\(content.hashValue)"
            ) { [weak self] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(content, forType: .string)
                self?.onCopySecret?()
            })
        }

        var imageIndicesByLine: [Int: Int] = [:]
        let noteText = string as NSString
        for image in markdownImages() where renderedImageURLs.contains(image.urlString) {
            let lineRange = noteText.lineRange(for: NSRange(location: image.range.location, length: 0))
            let imageIndex = imageIndicesByLine[lineRange.location, default: 0]
            imageIndicesByLine[lineRange.location] = imageIndex + 1
            guard let rect = imageCopyIconRect(for: image.range, indexOnLine: imageIndex) else { continue }
            let urlString = image.urlString
            specs.append(Spec(
                symbol: "link",
                tint: .secondaryLabelColor,
                frame: rect,
                help: "Copy image URL",
                key: "I|\(image.range.location)|\(urlString)"
            ) { [weak self] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(urlString, forType: .string)
                self?.onCopySecret?()
            })
        }

        let signature = specs.map { "\($0.key)@\(NSStringFromRect($0.frame))" }
            .joined(separator: ";")
        guard signature != gutterSignature else { return }
        gutterSignature = signature

        gutterButtons.forEach { $0.removeFromSuperview() }
        gutterButtons.removeAll()
        for spec in specs {
            addGutterButton(symbol: spec.symbol, tint: spec.tint, frame: spec.frame,
                            help: spec.help, action: spec.action)
        }
    }

    private func addGutterButton(symbol: String, tint: NSColor, frame: NSRect,
                                 help: String, action: @escaping () -> Void) {
        let button = GutterButton(frame: frame)
        button.onClick = action
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = help
        button.contentTintColor = tint
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
        }
        addSubview(button)
        gutterButtons.append(button)
    }

    // MARK: - Fenced code block copy

    private static let fencedCodeBlock = try! NSRegularExpression(pattern: #"```[\s\S]*?```"#)

    /// Each fenced code block's full range plus its inner code (fences stripped).
    /// Cached between text changes — see `cachedFencedBlocks`.
    private func fencedBlocks() -> [(range: NSRange, content: String)] {
        if let cachedFencedBlocks { return cachedFencedBlocks }
        let ns = string as NSString
        guard ns.length > 0 else { return [] }
        var result: [(NSRange, String)] = []
        Self.fencedCodeBlock.enumerateMatches(in: ns as String,
                                              range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let range = match?.range else { return }
            var content = ns.substring(with: range)
            // Drop the opening ```lang line.
            if let firstNewline = content.firstIndex(of: "\n") {
                content = String(content[content.index(after: firstNewline)...])
            } else {
                content = ""
            }
            // Drop the closing fence (and the newline before it).
            if let close = content.range(of: "```", options: .backwards) {
                content = String(content[..<close.lowerBound])
            }
            if content.hasSuffix("\n") { content.removeLast() }
            result.append((range, content))
        }
        cachedFencedBlocks = result
        return result
    }

    private func copyIconRect(for blockRange: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let firstLine = (string as NSString).lineRange(for: NSRange(location: blockRange.location, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: firstLine, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        let x = max(4, (origin.x - lockSize) / 2)
        return NSRect(x: x, y: rect.midY + origin.y - lockSize / 2, width: lockSize, height: lockSize)
    }

    private func imageCopyIconRect(for imageRange: NSRange, indexOnLine: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let line = (string as NSString).lineRange(for: NSRange(location: imageRange.location, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        let x = max(4, (origin.x - lockSize) / 2)
        let y = rect.maxY + origin.y + MarkdownImagePresentation.gap + 4
            + CGFloat(indexOnLine) * MarkdownImagePresentation.stride
        return NSRect(x: x, y: y, width: lockSize, height: lockSize)
    }

    // MARK: - Env secret copy + hover affordances

    /// View-space rects of the currently masked secret values.
    private func secretRects() -> [NSRect] {
        guard let maskController, let layoutManager, let textContainer else { return [] }
        let origin = textContainerOrigin
        return maskController.maskedRanges.compactMap { range in
            guard NSMaxRange(range) <= (string as NSString).length else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            return rect
        }
    }

    /// Refresh the pointing-hand cursor rects and "Click to copy" tooltips over
    /// the masked secrets. Called by `EnvMaskController` when the set changes.
    func updateSecretAffordances() {
        removeAllToolTips()
        for rect in secretRects() {
            addToolTip(rect, owner: self, userData: nil)
        }
        window?.invalidateCursorRects(for: self)
        layoutGutterIcons()
        layoutColorChips()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in secretRects() {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "Click to copy"
    }

    private func copySecret(at event: NSEvent) -> Bool {
        guard let maskController, !maskController.maskedRanges.isEmpty,
              let layoutManager, let textContainer else { return false }
        let ns = string as NSString
        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)

        for range in maskController.maskedRanges {
            guard NSMaxRange(range) <= ns.length else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .insetBy(dx: -3, dy: -2)
            guard rect.contains(containerPoint) else { continue }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ns.substring(with: range), forType: .string)
            onCopySecret?()
            return true
        }
        return false
    }

    private static let taskCheckbox = try! NSRegularExpression(
        pattern: #"^[ \t]*[-*+][ \t]+(\[[ xX]\])"#
    )

    private func toggleTaskCheckbox(at event: NSEvent) -> Bool {
        guard let layoutManager, let textContainer, let textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction
        )
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < ns.length else { return false }

        // Find a checkbox on the clicked line.
        let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = ns.substring(with: lineRange)
        let lineNSRange = NSRange(location: 0, length: (line as NSString).length)
        guard let match = Self.taskCheckbox.firstMatch(in: line, range: lineNSRange) else {
            return false
        }
        let boxInLine = match.range(at: 1)
        guard boxInLine.location != NSNotFound else { return false }
        let boxRange = NSRange(location: lineRange.location + boxInLine.location, length: boxInLine.length)

        // Only toggle if the click actually landed on the checkbox glyphs.
        let boxGlyphs = layoutManager.glyphRange(forCharacterRange: boxRange, actualCharacterRange: nil)
        let boxRect = layoutManager.boundingRect(forGlyphRange: boxGlyphs, in: textContainer)
            .insetBy(dx: -4, dy: -2)
        guard boxRect.contains(containerPoint) else { return false }

        // Flip the mark character ([ ] <-> [x]) through the normal edit path
        // so undo, re-styling, and the binding/save all fire.
        let markRange = NSRange(location: boxRange.location + 1, length: 1)
        let current = ns.substring(with: markRange)
        let replacement = current.lowercased() == "x" ? " " : "x"
        guard shouldChangeText(in: markRange, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: markRange, with: replacement)
        didChangeText()
        return true
    }

    /// Auto-sort every contiguous task group so incomplete root tasks stay on
    /// top and completed roots sink to the bottom. Indented subtasks move with
    /// their root as one block, so checking a child never detaches or reorders
    /// it. A no-op unless some group is actually out of order; the caret follows
    /// its line to the new position.
    func reorderCompletedTasks() {
        guard !isReordering, let textStorage else { return }
        let ns = string as NSString
        guard ns.length > 0 else { return }
        guard let newText = MarkdownTaskFormatter.reflow(string) else { return }

        // Remember the caret's line + column so it can follow the moved line.
        let sel = selectedRange()
        let caretLineRange = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let caretLine = ns.substring(with: caretLineRange).trimmingCharacters(in: .newlines)
        let caretColumn = sel.location - caretLineRange.location

        let full = NSRange(location: 0, length: ns.length)
        isReordering = true
        if shouldChangeText(in: full, replacementString: newText) {
            textStorage.replaceCharacters(in: full, with: newText)
            didChangeText()
        }
        isReordering = false

        // Restore the caret onto the same line in the reordered text.
        let newNS = string as NSString
        var restored = min(sel.location, newNS.length)
        var offset = 0
        for line in newText.components(separatedBy: "\n") {
            if line == caretLine {
                restored = min(offset + caretColumn, offset + (line as NSString).length)
                break
            }
            offset += (line as NSString).length + 1
        }
        setSelectedRange(NSRange(location: min(restored, newNS.length), length: 0))
    }

    /// Align markdown tables to fit their content (issue #79). Mirrors
    /// `reorderCompletedTasks`: a non-destructive reflow of the live text that
    /// preserves the caret. When `protectingCaret` is true the table block the
    /// caret sits in is left alone, so alignment never fights the cursor while
    /// you're typing inside a cell.
    func formatMarkdownTables(protectingCaret: Bool = true) {
        guard !isReordering, let textStorage else { return }
        let ns = string as NSString
        guard ns.length > 0 else { return }

        let skip: Set<Int> = protectingCaret ? caretLineIndices() : []
        guard let newText = MarkdownTableFormatter.reflow(string, skipLines: skip) else { return }

        // Remember the caret's line + column so it can follow the reflow.
        let sel = selectedRange()
        let caretLineRange = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let caretLine = ns.substring(with: caretLineRange).trimmingCharacters(in: .newlines)
        let caretColumn = sel.location - caretLineRange.location

        let full = NSRange(location: 0, length: ns.length)
        isReordering = true
        if shouldChangeText(in: full, replacementString: newText) {
            textStorage.replaceCharacters(in: full, with: newText)
            didChangeText()
        }
        isReordering = false

        // Restore the caret onto the same line in the reflowed text.
        let newNS = string as NSString
        var restored = min(sel.location, newNS.length)
        var offset = 0
        for line in newText.components(separatedBy: "\n") {
            if line == caretLine {
                restored = min(offset + caretColumn, offset + (line as NSString).length)
                break
            }
            offset += (line as NSString).length + 1
        }
        setSelectedRange(NSRange(location: min(restored, newNS.length), length: 0))
    }

    /// 0-based line indices touched by any selection/caret, so the table block
    /// the user is editing can be skipped during reflow.
    private func caretLineIndices() -> Set<Int> {
        let ns = string as NSString
        var indices: Set<Int> = []
        for value in selectedRanges {
            let r = value.rangeValue
            let start = lineIndex(at: min(r.location, ns.length), in: ns)
            let end = lineIndex(at: min(r.location + r.length, ns.length), in: ns)
            for i in start...end { indices.insert(i) }
        }
        return indices
    }

    private func lineIndex(at location: Int, in ns: NSString) -> Int {
        guard location > 0 else { return 0 }
        return ns.substring(to: min(location, ns.length)).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    private func splitSelectionIntoLines() {
        let ns = string as NSString
        var cursors: [NSRange] = []

        for value in selectedRanges {
            let selection = value.rangeValue

            // A bare caret (no selected text) stays as-is — there's nothing
            // to split, but we preserve any pre-existing multi-cursor state.
            guard selection.length > 0 else {
                cursors.append(selection)
                continue
            }

            let selectionEnd = selection.location + selection.length
            var lineStart = selection.location
            while lineStart < selectionEnd {
                let searchRange = NSRange(location: lineStart, length: selectionEnd - lineStart)
                let newline = ns.rangeOfCharacter(from: .newlines, options: [], range: searchRange)
                let lineEnd = newline.location == NSNotFound ? selectionEnd : newline.location
                cursors.append(NSRange(location: lineEnd, length: 0))
                if newline.location == NSNotFound { break }
                lineStart = newline.location + newline.length
            }
        }

        // `NSTextView` requires sorted, de-duplicated ranges.
        let sorted = cursors
            .sorted { $0.location < $1.location }
            .reduce(into: [NSRange]()) { result, range in
                if result.last?.location != range.location { result.append(range) }
            }

        guard !sorted.isEmpty else { return }
        selectedRanges = sorted.map { NSValue(range: $0) }
    }
}

private struct CopiedSecretToast: View {
    var body: some View {
        Label("Copied", systemImage: "checkmark.circle.fill")
            .scaledFont(size: 13, weight: .semibold)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}

private struct NoteTab: View {
    let title: String
    let isSelected: Bool
    let isDropTarget: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .scaledFont(size: 12, weight: isSelected ? .semibold : .regular)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(size: 9, weight: .bold)
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Reserve the trailing slot so hovering never shifts the title.
            .opacity(isHovering || isSelected ? 1 : 0)
            .disabled(!isHovering && !isSelected)
            .allowsHitTesting(isHovering || isSelected)
            .accessibilityHidden(!isHovering && !isSelected)
            .help("Close Note")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 170, alignment: .leading)
        .compatGlassEffect(
            tint: isSelected ? Color.accentColor.opacity(0.14) : nil,
            interactive: true,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        // Insertion marker on the leading edge — a drop places the dragged tab
        // just before this one.
        .overlay(alignment: .leading) {
            if isDropTarget {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .offset(x: -4)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isDropTarget)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}
