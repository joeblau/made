import AppKit
import CoreTransferable
import Observation
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    static let pilotNoteTab = UTType(exportedAs: "app.blau.pilot.note-tab")
}

struct NoteTabTransfer: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pilotNoteTab)
    }

    static let pasteboardType = NSPasteboard.PasteboardType(UTType.pilotNoteTab.identifier)

    static func read(from pasteboard: NSPasteboard) -> Self? {
        guard let data = pasteboard.data(forType: pasteboardType), data.count <= 1_024 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum NoteWordWrap: Int, CaseIterable {
    case eighty = 80
    case oneTwenty = 120
    case none = 0

    var title: String {
        switch self {
        case .eighty: "80 characters"
        case .oneTwenty: "120 characters"
        case .none: "None"
        }
    }

    var columnCount: Int? { self == .none ? nil : rawValue }
}

/// Native Notes presentation owns a small editor cache so switching recent
/// notes preserves caret, scroll and undo without retaining every text view.
@MainActor
final class NotesViewController: NSViewController, CockpitPanePresenting {
    let store: WorkspaceStore
    private let defaults: UserDefaults
    private let canvas = NotesCanvasView()
    private var tabs: [UUID: NoteTabView] = [:]
    private var editors: [UUID: NoteTextView] = [:]
    private var recentEditors: [UUID] = []
    private var currentNoteID: UUID?
    private var pendingSave: DispatchWorkItem?
    private var hasUnsavedChanges = false
    private var toastDismiss: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var observationGeneration = 0
    private var presentationActive = true
    private var presentedCloseID: UUID?
    private var closeAlert: NSAlert?
    private var lastTabOrder: [UUID] = []
    private var lastZoom: Double = 0

    init(store: WorkspaceStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = canvas
        canvas.newNoteButton.target = self
        canvas.newNoteButton.action = #selector(addNote)
        canvas.newNoteButton.onDrop = { [weak self] id in
            self?.store.moveNoteToEnd(id)
            self?.refresh()
        }
        canvas.emptyCreateButton.target = self
        canvas.emptyCreateButton.action = #selector(addNote)
        canvas.wordWrapPopup.target = self
        canvas.wordWrapPopup.action = #selector(changeWordWrap)
        for option in NoteWordWrap.allCases {
            canvas.wordWrapPopup.addItem(withTitle: option.title)
            canvas.wordWrapPopup.lastItem?.tag = option.rawValue
        }
        installNotifications()
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        presentationActive = true
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        presentPendingClose()
    }

    override func viewWillDisappear() {
        commitPendingEdits()
        flushPendingSave()
        presentationActive = false
        observationGeneration += 1
        dismissPendingClose()
        toastDismiss?.cancel()
        canvas.toast.isHidden = true
        super.viewWillDisappear()
    }

    isolated deinit {
        commitPendingEdits()
        flushPendingSave()
        dismissPendingClose()
        toastDismiss?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        presentationActive = isActive
        if isActive {
            refresh()
        } else {
            observationGeneration += 1
            commitPendingEdits()
            flushPendingSave()
            dismissPendingClose()
            toastDismiss?.cancel()
            canvas.toast.isHidden = true
        }
    }

    func refresh() {
        guard isViewLoaded else { return }
        let notes = store.notes
        updateTabs(notes)
        updateEditor(notes)
        updatePreferences()
        presentPendingClose()
        observeChanges()
    }

    /// End IME composition at an explicit navigation or quit boundary. Marked
    /// text does not emit `textDidChange` until committed. Keep this separate
    /// from the debounce save, which must never interrupt ongoing composition.
    func commitPendingEdits() {
        for (id, editor) in editors where editor.textView.hasMarkedText() {
            editor.textView.unmarkText()
            // During teardown the editor's weak callback may no longer reach
            // this controller. Copy the final text before saving in that case.
            if let note = store.notes.first(where: { $0.id == id }), note.body != editor.textView.string {
                note.body = editor.textView.string
                hasUnsavedChanges = true
            }
        }
    }

    /// Save failures retain the dirty flag so a later lifecycle flush retries.
    func flushPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasUnsavedChanges else { return }
        if store.modelContext.saveReporting(operation: "Saving note") { hasUnsavedChanges = false }
    }

    func closeSelectedNote() {
        commitPendingEdits()
        guard let note = store.selectedNote else { return }
        store.requestCloseNote(note)
        refresh()
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        for name in [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.commitPendingEdits()
                    self?.flushPendingSave()
                }
            })
        }
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePreferences() }
        })
        observers.append(center.addObserver(
            forName: .cockpitUIZoomDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePreferences() }
        })
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, window === self.view.window else { return }
                self.commitPendingEdits()
                self.flushPendingSave()
            }
        })
    }

    private func observeChanges() {
        observationGeneration += 1
        let generation = observationGeneration
        guard presentationActive else { return }
        withObservationTracking {
            _ = store.selectedNoteID
            _ = store.notePendingClose?.id
            for note in store.notes {
                _ = note.id
                _ = note.sortOrder
                _ = note.displayTitle
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.presentationActive,
                      self.observationGeneration == generation else { return }
                self.refresh()
            }
        }
    }

    private func updateTabs(_ notes: [Note]) {
        let ids = notes.map(\.id)
        var presentationChanged = false
        for id in Array(tabs.keys) where !ids.contains(id) {
            tabs.removeValue(forKey: id)?.removeFromSuperview()
            editors.removeValue(forKey: id)
            recentEditors.removeAll { $0 == id }
        }
        for note in notes {
            let tab = tabs[note.id] ?? makeTab(note)
            if tab.update(title: note.displayTitle, selected: store.selectedNoteID == note.id) {
                presentationChanged = true
            }
            tab.applyZoom(zoom)
            tabs[note.id] = tab
        }
        if lastTabOrder != ids {
            lastTabOrder = ids
            canvas.setTabs(ids.compactMap { tabs[$0] })
        } else if presentationChanged {
            canvas.needsLayout = true
        }
    }

    private func makeTab(_ note: Note) -> NoteTabView {
        let id = note.id
        let tab = NoteTabView(noteID: id)
        tab.onSelect = { [weak self] in self?.selectNote(id) }
        tab.onClose = { [weak self, weak note] in
            guard let self, let note else { return }
            self.commitPendingEdits()
            self.store.requestCloseNote(note)
            self.refresh()
        }
        tab.onRename = { [weak self] in self?.editTitle(id) }
        tab.onDrop = { [weak self] draggedID in
            self?.store.moveNote(draggedID, before: id)
            self?.refresh()
        }
        return tab
    }

    private func selectNote(_ id: UUID) {
        commitPendingEdits()
        flushPendingSave()
        store.selectedNoteID = id
        refresh()
        if let editor = editors[id] { view.window?.makeFirstResponder(editor.textView) }
        canvas.layoutSubtreeIfNeeded()
        if let tab = tabs[id] { canvas.tabDocument.scrollToVisible(tab.frame) }
    }

    /// Titles are derived from the first content line. Rename edits that line
    /// in place, preserving the editor's masking and undo instead of creating
    /// a second title field or exposing a secret in another dialog.
    private func editTitle(_ id: UUID) {
        selectNote(id)
        guard let textView = editors[id]?.textView else { return }
        let source = textView.string as NSString
        var offset = 0
        var selection = NSRange(location: 0, length: 0)
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let line = source.substring(with: range)
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selection = NSRange(location: range.location,
                                    length: (line.trimmingCharacters(in: .newlines) as NSString).length)
                break
            }
            offset = NSMaxRange(range)
        }
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
    }

    private func updateEditor(_ notes: [Note]) {
        let selected = notes.first { $0.id == store.selectedNoteID }
        if selected?.id != currentNoteID {
            commitPendingEdits()
            flushPendingSave()
            canvas.setEditor(nil)
            currentNoteID = selected?.id
        }
        guard let note = selected else {
            canvas.setEditor(nil)
            return
        }
        let editor: NoteTextView
        if let existing = editors[note.id] {
            editor = existing
        } else {
            editor = NoteTextView(
                text: note.body, fontSize: fontSize, wordWrapColumns: selectedWordWrap.columnCount,
                onChange: { [weak self, weak note] text in
                    guard let self, let note, note.modelContext != nil else { return }
                    note.body = text
                    self.hasUnsavedChanges = true
                    self.scheduleSave()
                },
                onCopySecret: { [weak self] in self?.flashCopiedToast() }
            )
            editors[note.id] = editor
        }
        editor.update(text: note.body, fontSize: fontSize, wordWrapColumns: selectedWordWrap.columnCount)
        canvas.setEditor(editor)
        recentEditors.removeAll { $0 == note.id }
        recentEditors.append(note.id)
        while recentEditors.count > 4 { editors.removeValue(forKey: recentEditors.removeFirst()) }
    }

    private var zoom: Double {
        if defaults === UserDefaults.standard { return CockpitUIZoomController.shared.factor }
        let value = defaults.double(forKey: "ui.zoom")
        return UIZoomLadder.normalized(value)
    }

    private var fontSize: CGFloat { 13 * zoom }

    private var selectedWordWrap: NoteWordWrap {
        guard defaults.object(forKey: "notes.wordWrap") != nil else { return .eighty }
        return NoteWordWrap(rawValue: defaults.integer(forKey: "notes.wordWrap")) ?? .eighty
    }

    private func updatePreferences() {
        guard isViewLoaded else { return }
        if canvas.wordWrapPopup.selectedTag() != selectedWordWrap.rawValue {
            canvas.wordWrapPopup.selectItem(withTag: selectedWordWrap.rawValue)
            canvas.wordWrapPopup.setAccessibilityValue(selectedWordWrap.title)
        }
        for editor in editors.values {
            editor.update(fontSize: fontSize, wordWrapColumns: selectedWordWrap.columnCount)
        }
        if lastZoom != zoom {
            lastZoom = zoom
            canvas.applyZoom(zoom)
            for tab in tabs.values { tab.applyZoom(zoom) }
        }
    }

    @objc private func addNote() {
        flushPendingSave()
        let note = store.addNote()
        selectNote(note.id)
    }

    @objc private func changeWordWrap() {
        defaults.set(canvas.wordWrapPopup.selectedTag(), forKey: "notes.wordWrap")
        updatePreferences()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPendingSave() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func flashCopiedToast() {
        guard presentationActive else { return }
        toastDismiss?.cancel()
        canvas.toast.isHidden = false
        NSAccessibility.post(element: canvas.toastLabel, notification: .announcementRequested,
                             userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let work = DispatchWorkItem { [weak self] in self?.canvas.toast.isHidden = true }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func presentPendingClose() {
        guard presentationActive, presentedCloseID == nil, let note = store.notePendingClose,
              let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Note?"
        alert.informativeText = "“\(note.displayTitle)” will be permanently deleted. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Note")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        presentedCloseID = note.id
        closeAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak note] response in
            guard let self else { return }
            self.presentedCloseID = nil
            self.closeAlert = nil
            if let note, self.store.notePendingClose?.id == note.id {
                if response == .alertFirstButtonReturn {
                    self.flushPendingSave()
                    self.store.deleteNote(note)
                }
                self.store.notePendingClose = nil
            }
            self.refresh()
        }
    }

    private func dismissPendingClose() {
        guard let alert = closeAlert else { return }
        if store.notePendingClose?.id == presentedCloseID { store.notePendingClose = nil }
        if let window = alert.window.sheetParent { window.endSheet(alert.window, returnCode: .cancel) }
        closeAlert = nil
        presentedCloseID = nil
    }
}

/// Direct TextKit host shared by Notes and native screenshot/test fixtures.
@MainActor
final class NoteTextView: NSView, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: MultiCursorTextView
    let styler: MarkdownStyler
    let maskController = EnvMaskController()
    let editingUndoManager = UndoManager()
    private let onChange: (String) -> Void
    private var appliedWrap: WrapSettings

    struct WrapSettings: Equatable {
        let columns: Int?
        let fontSize: CGFloat
    }

    init(text: String, fontSize: CGFloat, wordWrapColumns: Int?,
         onChange: @escaping (String) -> Void = { _ in }, onCopySecret: @escaping () -> Void = {}) {
        let scrollView = MultiCursorTextView.scrollableTextView()
        self.scrollView = scrollView
        // NSTextView.scrollableTextView constructs an instance of its receiver.
        self.textView = scrollView.documentView as! MultiCursorTextView
        self.styler = MarkdownStyler(baseSize: fontSize)
        self.appliedWrap = WrapSettings(columns: wordWrapColumns, fontSize: fontSize)
        self.onChange = onChange
        super.init(frame: .zero)
        addSubview(scrollView)
        textView.delegate = self
        textView.allowsUndo = true
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 28, height: 10)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.textStorage?.delegate = styler
        maskController.textView = textView
        textView.maskController = maskController
        textView.onCopySecret = onCopySecret
        textView.layoutManager?.delegate = maskController
        textView.string = text
        if let storage = textView.textStorage { styler.style(storage) }
        maskController.refresh(secretMatches: styler.secretMatches)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        textView.setAccessibilityLabel("Note text")
        textView.setAccessibilityIdentifier("notes.editor")
        applyWordWrap(forceLayout: false)
        DispatchQueue.main.async { [weak self] in self?.textView.settleAutomaticReflows() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let storage = textView.textStorage { styler.style(storage) }
        textView.needsDisplay = true
    }

    func update(text: String, fontSize: CGFloat, wordWrapColumns: Int?) {
        update(fontSize: fontSize, wordWrapColumns: wordWrapColumns)
        guard textView.string != text, !textView.hasMarkedText() else { return }
        textView.string = text
        maskController.refresh(secretMatches: styler.secretMatches)
    }

    func update(fontSize: CGFloat, wordWrapColumns: Int?) {
        if styler.baseSize != fontSize {
            styler.baseSize = fontSize
            textView.typingAttributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            if let storage = textView.textStorage { styler.style(storage) }
        }
        let wrap = WrapSettings(columns: wordWrapColumns, fontSize: fontSize)
        guard appliedWrap != wrap else { return }
        appliedWrap = wrap
        applyWordWrap(forceLayout: true)
    }

    private func applyWordWrap(forceLayout: Bool) {
        guard let container = textView.textContainer else { return }
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        if let columns = appliedWrap.columns {
            let font = NSFont.monospacedSystemFont(ofSize: appliedWrap.fontSize, weight: .regular)
            let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            container.containerSize = NSSize(
                width: ceil(characterWidth * CGFloat(columns)) + container.lineFragmentPadding * 2,
                height: .greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = false
            scrollView.hasHorizontalScroller = false
        } else {
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }
        if forceLayout { textView.layoutManager?.ensureLayout(for: container) }
        textView.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        onChange(textView.string)
        maskController.refresh(secretMatches: styler.secretMatches)
        textView.applyAutomaticReflows()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editingUndoManager }

    func textViewDidChangeSelection(_ notification: Notification) {
        maskController.refresh(secretMatches: styler.secretMatches)
    }
}

private final class NotesCanvasView: NSView {
    let tabScroll = NSScrollView()
    let tabDocument = NotesFlippedView()
    let newNoteButton = NoteDropButton(title: "+", target: nil, action: nil)
    let wordWrapLabel = NSTextField(labelWithString: "Word Wrap")
    let wordWrapPopup = NSPopUpButton()
    let disclosure = NSTextField(wrappingLabelWithString:
        "Secret masking is visual only. Notes are stored locally as plaintext—do not use Notes as a secret manager.")
    let editorContainer = NotesFlippedView()
    let emptyLabel = NSTextField(labelWithString: "No Note")
    let emptyCreateButton = NSButton(title: "New Note", target: nil, action: nil)
    let toast = NSVisualEffectView()
    let toastLabel = NSTextField(labelWithString: "✓ Copied")
    private var tabs: [NoteTabView] = []
    private weak var editor: NSView?
    private var zoom = 1.0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tabScroll.documentView = tabDocument
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.verticalScrollElasticity = .none
        newNoteButton.bezelStyle = .roundRect
        newNoteButton.toolTip = "New Note"
        newNoteButton.setAccessibilityLabel("New Note")
        newNoteButton.setAccessibilityIdentifier("notes.new")
        wordWrapPopup.setAccessibilityLabel("Word Wrap")
        wordWrapPopup.setAccessibilityIdentifier("notes.word-wrap")
        disclosure.textColor = .secondaryLabelColor
        disclosure.setAccessibilityLabel("Security notice: secret masking is visual only. Notes are stored locally as plaintext.")
        emptyLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        emptyCreateButton.bezelStyle = .rounded
        toast.material = .popover
        toast.blendingMode = .withinWindow
        toast.state = .active
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 18
        toast.isHidden = true
        toastLabel.alignment = .center
        toast.addSubview(toastLabel)
        [tabScroll, newNoteButton, wordWrapLabel, wordWrapPopup, disclosure, editorContainer, emptyLabel, emptyCreateButton, toast]
            .forEach(addSubview)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollerStyleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        applyZoom(1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func scrollerStyleChanged() { needsLayout = true }

    func setTabs(_ tabs: [NoteTabView]) {
        self.tabs = tabs
        for tab in tabs where tab.superview !== tabDocument { tabDocument.addSubview(tab) }
        needsLayout = true
    }

    func setEditor(_ editor: NSView?) {
        guard self.editor !== editor else { return }
        self.editor?.removeFromSuperview()
        self.editor = editor
        if let editor { editorContainer.addSubview(editor) }
        emptyLabel.isHidden = editor != nil
        emptyCreateButton.isHidden = editor != nil
        needsLayout = true
    }

    func applyZoom(_ zoom: Double) {
        self.zoom = zoom
        disclosure.font = .systemFont(ofSize: 11 * zoom)
        wordWrapLabel.font = .systemFont(ofSize: 12 * zoom)
        wordWrapPopup.font = .systemFont(ofSize: 12 * zoom)
        toastLabel.font = .systemFont(ofSize: 13 * zoom, weight: .semibold)
        newNoteButton.font = .systemFont(ofSize: 16 * zoom, weight: .medium)
        emptyLabel.font = .systemFont(ofSize: 20 * zoom, weight: .semibold)
        emptyCreateButton.font = .systemFont(ofSize: 13 * zoom)
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func layout() {
        super.layout()
        let tabHeight = max(32, 30 * zoom)
        let wrapWidth = min(bounds.width, 230 * zoom)
        let narrow = bounds.width < 470 * zoom
        let tabAreaWidth = max(0, bounds.width - (narrow ? 0 : wrapWidth))
        let buttonX = max(8, tabAreaWidth - tabHeight - 8)
        let scrollWidth = max(0, buttonX - 4)
        var x: CGFloat = 8
        for tab in tabs {
            tab.frame = NSRect(x: x, y: 4, width: tab.preferredWidth, height: tabHeight)
            x += tab.frame.width + 6
        }
        let contentHeight = tabHeight + 8
        let stripHeight = NSScrollView.frameSize(
            forContentSize: NSSize(width: scrollWidth, height: contentHeight),
            horizontalScrollerClass: x + 2 > scrollWidth ? NSScroller.self : nil,
            verticalScrollerClass: nil, borderType: .noBorder,
            controlSize: tabScroll.horizontalScroller?.controlSize ?? .regular,
            scrollerStyle: tabScroll.scrollerStyle).height
        tabScroll.frame = NSRect(x: 0, y: 0, width: scrollWidth, height: stripHeight)
        tabDocument.frame = NSRect(x: 0, y: 0, width: max(x + 2, scrollWidth), height: contentHeight)
        tabScroll.tile()
        newNoteButton.frame = NSRect(x: buttonX, y: 4, width: tabHeight, height: tabHeight)
        let wrapY = narrow ? stripHeight + 4 : 4.0
        let wrapX = max(8, bounds.width - wrapWidth)
        wordWrapLabel.frame = NSRect(x: wrapX, y: wrapY + 5, width: 76 * zoom, height: tabHeight)
        wordWrapPopup.frame = NSRect(x: wrapX + 78 * zoom, y: wrapY, width: max(40, wrapWidth - 86 * zoom), height: tabHeight)
        let noticeY = (narrow ? wrapY + tabHeight : stripHeight) + 4
        let noticeWidth = max(0, bounds.width - 16)
        let noticeHeight = max(22, disclosure.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: noticeWidth, height: 1_000)).height ?? 22)
        disclosure.frame = NSRect(x: 8, y: noticeY, width: noticeWidth, height: noticeHeight)
        let editorY = noticeY + noticeHeight + 6
        editorContainer.frame = NSRect(x: 0, y: editorY, width: bounds.width, height: max(0, bounds.height - editorY))
        editor?.frame = editorContainer.bounds
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(x: (bounds.width - emptyLabel.frame.width) / 2,
                                         y: editorY + editorContainer.bounds.height / 2 - 30)
        emptyCreateButton.frame = NSRect(x: bounds.midX - 55 * zoom, y: emptyLabel.frame.maxY + 12,
                                        width: 110 * zoom, height: 32 * zoom)
        toast.frame = NSRect(x: bounds.midX - 65 * zoom, y: max(editorY, bounds.height - 68 * zoom),
                             width: 130 * zoom, height: 40 * zoom)
        toastLabel.frame = NSRect(x: 8, y: 10 * zoom, width: toast.bounds.width - 16, height: 22 * zoom)
    }
}

private final class NotesFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class NoteTabView: NSView {
    private let titleButton: NoteDragButton
    private let closeButton = NSButton()
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: (() -> Void)?
    var onDrop: ((UUID) -> Void)? { didSet { titleButton.onDrop = onDrop } }
    private var selected = false
    private var zoom = 1.0

    init(noteID: UUID) {
        titleButton = NoteDragButton(noteID: noteID)
        super.init(frame: .zero)
        titleButton.target = self
        titleButton.action = #selector(selectTab)
        titleButton.bezelStyle = .roundRect
        titleButton.isBordered = false
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.font = .systemFont(ofSize: 12, weight: .medium)
        titleButton.setAccessibilityIdentifier("notes.tab.\(noteID.uuidString)")
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Note")
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close Note"
        closeButton.setAccessibilityLabel("Close Note")
        addSubview(titleButton)
        addSubview(closeButton)
        wantsLayer = true
        layer?.cornerRadius = 12
        let menu = NSMenu()
        let rename = menu.addItem(withTitle: "Rename Note…", action: #selector(renameTab), keyEquivalent: "")
        rename.target = self
        let close = menu.addItem(withTitle: "Close Note", action: #selector(closeTab), keyEquivalent: "")
        close.target = self
        titleButton.menu = menu
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var preferredWidth: CGFloat { min(300 * zoom, max(80, titleButton.intrinsicContentSize.width + 34 * zoom)) }

    @discardableResult
    func update(title: String, selected: Bool) -> Bool {
        guard titleButton.title != title || self.selected != selected else { return false }
        titleButton.title = title
        titleButton.toolTip = title
        titleButton.setAccessibilityLabel(title)
        titleButton.setAccessibilityValue(selected ? "Selected" : "")
        self.selected = selected
        updateAppearance()
        needsLayout = true
        return true
    }

    func applyZoom(_ zoom: Double) {
        guard self.zoom != zoom else { return }
        self.zoom = zoom
        titleButton.font = .systemFont(ofSize: 12 * zoom, weight: .medium)
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10 * zoom, weight: .regular)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).cgColor
        }
    }

    override func layout() {
        super.layout()
        titleButton.frame = NSRect(x: 4, y: 0, width: max(0, bounds.width - 29 * zoom), height: bounds.height)
        closeButton.frame = NSRect(x: bounds.width - 25 * zoom, y: (bounds.height - 20 * zoom) / 2,
                                   width: 20 * zoom, height: 20 * zoom)
    }

    @objc private func selectTab() { onSelect?() }
    @objc private func closeTab() { onClose?() }
    @objc private func renameTab() { onRename?() }
}

private class NoteDropButton: NSButton {
    var onDrop: ((UUID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([NoteTabTransfer.pasteboardType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([NoteTabTransfer.pasteboardType])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        NoteTabTransfer.read(from: sender.draggingPasteboard) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let transfer = NoteTabTransfer.read(from: sender.draggingPasteboard), let onDrop else { return false }
        onDrop(transfer.id)
        return true
    }
}

private final class NoteDragButton: NoteDropButton, NSDraggingSource {
    private let noteID: UUID
    private var dragStart: NSEvent?

    init(noteID: UUID) {
        self.noteID = noteID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        dragStart = event
        highlight(true)
    }

    override func mouseUp(with event: NSEvent) {
        highlight(false)
        guard dragStart != nil else { return }
        dragStart = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { performClick(nil) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart,
              hypot(event.locationInWindow.x - start.locationInWindow.x,
                    event.locationInWindow.y - start.locationInWindow.y) > 4,
              let data = try? JSONEncoder().encode(NoteTabTransfer(id: noteID)) else { return }
        dragStart = nil
        highlight(false)
        let item = NSPasteboardItem()
        item.setData(data, forType: NoteTabTransfer.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}
