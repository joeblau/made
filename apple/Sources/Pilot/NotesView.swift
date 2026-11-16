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
    /// Titles shown by the tab control, keyed by note.
    private var tabTitles: [UUID: String] = [:]
    /// The same Liquid Glass tab control as the Remote Desktop groups:
    /// right-click a tab to rename, reorder, or close its note.
    private lazy var tabControl = PilotSegmentedControl<UUID>(
        "Notes", selection: UUID(), options: [],
        title: { [weak self] id in self?.tabTitles[id] ?? "" },
        controlSize: .large, liftsOnPress: false
    ) { [weak self] id in self?.selectNote(id) }
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
        tabControl.setAccessibilityIdentifier("notes.tabs")
        tabControl.onClose = { [weak self] id in self?.closeNote(id) }
        tabControl.menuItems = { [weak self] id in self?.tabMenuItems(id) ?? [] }
        canvas.setTabControl(tabControl)
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
        for id in Array(editors.keys) where !ids.contains(id) {
            editors.removeValue(forKey: id)
            recentEditors.removeAll { $0 == id }
        }
        let titles = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.displayTitle) })
        let titlesChanged = titles != tabTitles
        tabTitles = titles
        if tabControl.options != ids {
            tabControl.options = ids
        } else if titlesChanged {
            tabControl.refresh()
        }
        if let selected = store.selectedNoteID, tabControl.selection != selected {
            tabControl.selection = selected
        }
        canvas.setTabTitles(ids.compactMap { titles[$0] })
    }

    private func closeNote(_ id: UUID) {
        guard let note = store.notes.first(where: { $0.id == id }) else { return }
        commitPendingEdits()
        store.requestCloseNote(note)
        refresh()
    }

    private func tabMenuItems(_ id: UUID) -> [PilotSegmentedMenuItem] {
        let ids = tabControl.options
        guard let index = ids.firstIndex(of: id) else { return [] }
        return [
            PilotSegmentedMenuItem("Rename Note…") { [weak self] in self?.editTitle(id) },
            PilotSegmentedMenuItem("Move Left", isEnabled: index > 0) { [weak self] in
                self?.store.moveNote(id, before: ids[index - 1])
                self?.refresh()
            },
            PilotSegmentedMenuItem("Move Right", isEnabled: index < ids.count - 1) { [weak self] in
                self?.store.moveNote(ids[index + 1], before: id)
                self?.refresh()
            },
            PilotSegmentedMenuItem("Close Note", isDestructive: true) { [weak self] in self?.closeNote(id) },
        ]
    }

    private func selectNote(_ id: UUID) {
        commitPendingEdits()
        flushPendingSave()
        store.selectedNoteID = id
        refresh()
        if let editor = editors[id] { view.window?.makeFirstResponder(editor.textView) }
        canvas.layoutSubtreeIfNeeded()
        canvas.scrollTabToVisible(tabControl.options.firstIndex(of: id))
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
        CockpitMotion.present(canvas.toast)
        NSAccessibility.post(element: canvas.toastLabel, notification: .announcementRequested,
                             userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            CockpitMotion.dismiss(self.canvas.toast)
        }
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
    let newNoteButton = NSButton(title: "+", target: nil, action: nil)
    let wordWrapLabel = NSTextField(labelWithString: "Word Wrap")
    let wordWrapPopup = NSPopUpButton()
    let disclosure = NSTextField(wrappingLabelWithString:
        "Secret masking is visual only. Notes are stored locally as plaintext—do not use Notes as a secret manager.")
    let editorContainer = NotesFlippedView()
    let emptyLabel = NSTextField(labelWithString: "No Note")
    let emptyCreateButton = NSButton(title: "New Note", target: nil, action: nil)
    let toast = NSVisualEffectView()
    let toastLabel = NSTextField(labelWithString: "✓ Copied")
    private weak var tabControl: NSView?
    private var tabTitles: [String] = []
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
        newNoteButton.applyCockpitGlassStyle()
        newNoteButton.borderShape = .circle
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

    func setTabControl(_ control: NSView) {
        tabControl?.removeFromSuperview()
        tabControl = control
        tabDocument.addSubview(control)
        needsLayout = true
    }

    /// Equal-width segments sized for the longest title, so a long strip
    /// scrolls instead of truncating every tab.
    func setTabTitles(_ titles: [String]) {
        guard titles != tabTitles else { return }
        tabTitles = titles
        needsLayout = true
    }

    func scrollTabToVisible(_ index: Int?) {
        guard let index, let tabControl, !tabTitles.isEmpty else { return }
        let width = tabControl.frame.width / CGFloat(tabTitles.count)
        tabDocument.scrollToVisible(NSRect(x: tabControl.frame.minX + width * CGFloat(index), y: tabControl.frame.minY,
                                           width: width, height: tabControl.frame.height))
    }

    private var segmentWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large) * zoom)
        let widest = tabTitles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(220 * zoom, max(96 * zoom, widest + 48 * zoom))
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
        if let tabControl {
            let width = segmentWidth * CGFloat(tabTitles.count)
            tabControl.isHidden = tabTitles.isEmpty
            tabControl.frame = NSRect(x: x, y: 4, width: width, height: tabHeight)
            x += width
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
