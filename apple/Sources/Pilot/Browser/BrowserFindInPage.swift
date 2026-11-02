import SwiftUI

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

/// Edit ▸ Find…, Find Next, Find Previous, plus View ▸ Focus Selected Pane,
/// whose ⌘F yields to Find while a browser is selected. Both follow the key
/// scene's workspace so Main and Extendo never steal each other's shortcut.
struct PilotBrowserFindCommands: Commands {
    @FocusedValue(Workspace.self) private var focusedWorkspace
    let store: WorkspaceStore

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Find…") {
                findTarget?.showFindBar()
            }
            .keyboardShortcut(findTarget == nil ? nil : KeyboardShortcut("f", modifiers: .command))
            .disabled(findTarget == nil)

            Button("Find Next") {
                findTarget?.findAgain(forward: true)
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(findTarget?.canFindAgain != true)

            Button("Find Previous") {
                findTarget?.findAgain(forward: false)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(findTarget?.canFindAgain != true)
        }

        CommandGroup(after: .sidebar) {
            Button("Focus Selected Pane") {
                guard let workspace = store.selectedWorkspace,
                      let pane = workspace.selectedPane else { return }
                workspace.focusPane(pane)
            }
            .keyboardShortcut(
                BrowserFindCommandTarget.focusPaneOwnsCommandF(selectedPane: focusedWorkspace?.selectedPane)
                    ? KeyboardShortcut("f", modifiers: .command)
                    : nil
            )
            .disabled(store.selectedWorkspace?.selectedPane == nil)
        }
    }

    private var findTarget: BrowserState? {
        BrowserFindCommandTarget.state(for: focusedWorkspace?.selectedPane)
    }
}

/// The in-pane find bar: a glass search field, the result count, and glass
/// previous/next/done controls. It sits above the page on the pane's own
/// window background, so its glass never samples page content.
struct BrowserFindBar: View {
    let state: BrowserState

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            TextField("Find in Page", text: Bindable(state).findBarText, prompt: Text("Find in page"))
                .focused($isFieldFocused)
                .onSubmit { state.findInPage(forward: true) }
                .onKeyPress(.return, phases: .down) { press in
                    // Return is Next (onSubmit); Shift-Return is Previous.
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    state.findInPage(forward: false)
                    return .handled
                }
                .onChange(of: state.findBarText) {
                    state.findInPage(forward: true)
                }
                .accessibilityLabel("Find in Page")
                .accessibilityIdentifier("browser.find-field")
                .liquidGlassField(systemImage: "magnifyingglass", isFocused: isFieldFocused)
                .frame(minWidth: 160, maxWidth: 320)

            Text(summary)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(GlassLegibleText.secondaryColor)
                .lineLimit(1)
                .accessibilityIdentifier("browser.find-summary")
                .accessibilityHidden(summary.isEmpty)

            Spacer(minLength: 0)

            CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Button {
                        state.findInPage(forward: false)
                    } label: {
                        Label("Previous Match", systemImage: "chevron.up")
                            .labelStyle(.iconOnly)
                    }
                    .compatGlassIconButton(controlSize: .small)
                    .disabled(state.findBarText.isEmpty)
                    .help("Previous Match (⇧⌘G)")
                    .accessibilityIdentifier("browser.find-previous")

                    Button {
                        state.findInPage(forward: true)
                    } label: {
                        Label("Next Match", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .compatGlassIconButton(controlSize: .small)
                    .disabled(state.findBarText.isEmpty)
                    .help("Next Match (⌘G)")
                    .accessibilityIdentifier("browser.find-next")

                    Button("Done") {
                        state.hideFindBar()
                    }
                    .compatGlassButtonStyle()
                    .controlSize(.small)
                    .accessibilityIdentifier("browser.find-done")
                }
            }
        }
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { state.hideFindBar() }
        .onAppear {
            isFieldFocused = true
            // Reopening with a kept draft highlights its matches again.
            if state.findQuery.isEmpty { state.findInPage() }
        }
        .onChange(of: state.findFieldFocusRequestID) {
            isFieldFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in Page")
        .accessibilityIdentifier("browser.find-bar")
    }

    private var summary: String {
        BrowserFindSummary.text(
            query: state.findQuery,
            matchCount: state.findMatchCount,
            activeOrdinal: state.activeFindMatchOrdinal,
            countsMatches: state.findCountsMatches
        )
    }
}
