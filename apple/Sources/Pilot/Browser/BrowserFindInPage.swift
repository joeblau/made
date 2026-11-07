import AppKit

// Find in Page for both browser engines: the pane-local request state, the
// in-pane Liquid Glass find bar, and the Edit menu commands that drive it.
//
// The find UI lives in the pane rather than in a toolbar popover: a popover
// anchored to a button inside a toolbar `ControlGroup` never presented on
// macOS 27, so Find was unreachable.

extension BrowserState {
    var findQuery: String { get { runtime.findQuery } set { runtime.findQuery = newValue } }
    var findForward: Bool { get { runtime.findForward } set { runtime.findForward = newValue } }
    var findMatchCase: Bool { get { runtime.findMatchCase } set { runtime.findMatchCase = newValue } }
    var findRequestID: Int { get { runtime.findRequestID } set { runtime.findRequestID = newValue } }
    var stopFindingRequestID: Int { get { runtime.stopFindingRequestID } set { runtime.stopFindingRequestID = newValue } }
    var findMatchCount: Int { get { runtime.findMatchCount } set { runtime.findMatchCount = newValue } }
    var activeFindMatchOrdinal: Int { get { runtime.activeFindMatchOrdinal } set { runtime.activeFindMatchOrdinal = newValue } }
    var isFindBarVisible: Bool { get { runtime.isFindBarVisible } set { runtime.isFindBarVisible = newValue } }
    var findBarText: String { get { runtime.findBarText } set { runtime.findBarText = newValue } }
    var findFieldFocusRequestID: Int { get { runtime.findFieldFocusRequestID } set { runtime.findFieldFocusRequestID = newValue } }

    /// Chromium reports "n of m"; WebKit's public find API only reports
    /// whether a match exists.
    var findCountsMatches: Bool { engine == .chromium }

    /// Queues one search. Neither engine needs a "new session" flag: both
    /// restart from the top when the query or case changes and step to the
    /// next or previous match when it repeats.
    func requestFind(
        _ query: String,
        forward: Bool = true,
        matchCase: Bool = false
    ) {
        guard supports(.findInPage), !query.isEmpty else { return }
        findQuery = query
        findForward = forward
        findMatchCase = matchCase
        findRequestID += 1
    }

    func stopFinding() {
        guard supports(.findInPage) else { return }
        findQuery = ""
        findMatchCount = 0
        activeFindMatchOrdinal = 0
        stopFindingRequestID += 1
    }

    /// Edit ▸ Find… and the toolbar magnifier: show the bar and focus its
    /// field, even when it is already showing.
    func showFindBar() {
        guard supports(.findInPage) else { return }
        isFindBarVisible = true
        findFieldFocusRequestID += 1
    }

    /// Done or Escape: hide the bar and clear the page's highlights. The
    /// draft stays so ⌘G can repeat it.
    func hideFindBar() {
        isFindBarVisible = false
        if !findQuery.isEmpty { stopFinding() }
    }

    /// Searches for the bar's text, as Safari and Chrome do: typing selects
    /// the first match of the changed query, and Return (the same query)
    /// moves to the next or previous match.
    func findInPage(forward: Bool = true) {
        guard supports(.findInPage) else { return }
        let query = findBarText
        guard !query.isEmpty else {
            if !findQuery.isEmpty { stopFinding() }
            return
        }
        requestFind(query, forward: forward)
    }

    /// Whether Find Next / Find Previous (⌘G / ⇧⌘G) have a query to repeat.
    var canFindAgain: Bool {
        supports(.findInPage) && !findBarText.isEmpty
    }

    /// ⌘G / ⇧⌘G: repeat the last query, showing the bar (without moving
    /// focus) so the result count is visible.
    func findAgain(forward: Bool) {
        guard canFindAgain else { return }
        isFindBarVisible = true
        findInPage(forward: forward)
    }
}

enum BrowserFindSummary {
    /// The result text beside the find field. Empty until a search runs.
    static func text(
        query: String,
        matchCount: Int,
        activeOrdinal: Int,
        countsMatches: Bool
    ) -> String {
        guard !query.isEmpty else { return "" }
        guard matchCount > 0 else { return "No matches" }
        guard countsMatches else { return "Match found" }
        return "\(max(activeOrdinal, 1)) of \(matchCount)"
    }
}

/// Which pane the Edit menu's find commands address, and therefore who owns
/// ⌘F. Find takes ⌘F only while the key scene's selected pane is a visible
/// browser; everywhere else ⌘F stays Focus Selected Pane, so the existing
/// shortcut moves only where it collided. Terminals keep ⌘F as pane focus
/// through Ghostty's own key handling either way.
@MainActor
enum BrowserFindCommandTarget {
    static func state(for selectedPane: Pane?) -> BrowserState? {
        guard let state = BrowserToolbarSelection.state(for: selectedPane),
              state.supports(.findInPage) else { return nil }
        return state
    }

    static func focusPaneOwnsCommandF(selectedPane: Pane?) -> Bool {
        state(for: selectedPane) == nil
    }
}

@MainActor
final class BrowserFindBar: NSView, NSSearchFieldDelegate {
    let state: BrowserState
    private let field = NSSearchField()
    private let summary = NSTextField(labelWithString: "")
    private var focusRequest = -1
    private var previous: BrowserNativeButton!
    private var next: BrowserNativeButton!

    init(state: BrowserState) {
        self.state = state
        super.init(frame: .zero)
        field.placeholderString = "Find in page"
        field.setAccessibilityLabel("Find in Page")
        field.setAccessibilityIdentifier("browser.find-field")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        previous = BrowserNativeButton("Previous Match", symbol: "chevron.up") { [weak state] in state?.findInPage(forward: false) }
        next = BrowserNativeButton("Next Match", symbol: "chevron.down") { [weak state] in state?.findInPage(forward: true) }
        let done = BrowserNativeButton("Done") { [weak state] in state?.hideFindBar() }
        previous.setAccessibilityIdentifier("browser.find-previous")
        next.setAccessibilityIdentifier("browser.find-next")
        done.setAccessibilityIdentifier("browser.find-done")
        summary.textColor = .secondaryLabelColor
        summary.setAccessibilityIdentifier("browser.find-summary")
        let stack = NSStackView(views: [field, summary, previous, next, done])
        stack.spacing = 6
        BrowserNativeUI.pin(stack, to: self, inset: 6)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        setAccessibilityIdentifier("browser.find-bar")
        setAccessibilityLabel("Find in Page")
        synchronize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronize()
    }

    func synchronize() {
        field.font = CockpitTypography.font(size: 13)
        summary.font = CockpitTypography.font(size: 12)
        if field.currentEditor() == nil { field.stringValue = state.findBarText }
        summary.stringValue = BrowserFindSummary.text(query: state.findQuery, matchCount: state.findMatchCount,
            activeOrdinal: state.activeFindMatchOrdinal, countsMatches: state.findCountsMatches)
        previous.isEnabled = !state.findBarText.isEmpty
        next.isEnabled = !state.findBarText.isEmpty
        if focusRequest != state.findFieldFocusRequestID, let window {
            focusRequest = state.findFieldFocusRequestID
            window.makeFirstResponder(field)
            field.selectText(nil)
            if state.findQuery.isEmpty { state.findInPage() }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        state.findBarText = field.stringValue
        state.findInPage()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            state.hideFindBar()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            state.findInPage(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
            return true
        }
        return false
    }

}
