import AppKit
import SwiftUI

/// Resolves the browser toolbar from the pane that owns it. Main and Extension
/// both use this gate so a collapsed/non-browser pane cannot leave stale
/// controls behind, and Extension always binds to its own persisted
/// `BrowserState` rather than the similarly selected pane in Main.
enum BrowserToolbarSelection {
    static func state(for pane: Pane?) -> BrowserState? {
        guard let pane,
              !pane.isCollapsed,
              pane.kind == .browser else { return nil }
        return pane.browserState
    }
}

/// Scene-local browser selection used by menu commands. Revealing a browser
/// preserves focused-pane mode by moving that focus to the browser instead of
/// leaving `focusedPaneID` attached to a hidden pane.
@MainActor
enum BrowserCommandSelection {
    static func selectedState(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> BrowserState? {
        guard let state = BrowserToolbarSelection.state(for: workspace?.selectedPane) else {
            return nil
        }
        if let capability, !state.supports(capability) {
            return nil
        }
        return state
    }

    static func hasBrowser(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> Bool {
        workspace?.panes.contains { pane in
            guard pane.kind == .browser,
                  let state = pane.browserState else { return false }
            return capability.map(state.supports) ?? true
        } ?? false
    }

    @discardableResult
    static func revealBrowser(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> BrowserState? {
        guard let workspace else { return nil }

        func isEligible(_ pane: Pane) -> Bool {
            guard pane.kind == .browser,
                  let state = pane.browserState else { return false }
            return capability.map(state.supports) ?? true
        }

        let browser: Pane
        if let selectedPane = workspace.selectedPane,
           isEligible(selectedPane) {
            browser = selectedPane
        } else if let firstBrowser = workspace.sortedPanes.first(where: isEligible) {
            browser = firstBrowser
        } else {
            return nil
        }

        if let focusedPaneID = workspace.focusedPaneID,
           focusedPaneID != browser.id {
            workspace.focusPane(browser)
        } else {
            workspace.expandPane(browser)
            workspace.selectedPaneID = browser.id
        }
        return BrowserToolbarSelection.state(for: browser)
    }
}

struct BrowserBackForwardToolbarControls: View {
    let state: BrowserState

    var body: some View {
        ControlGroup {
            Button { state.perform(.back) } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!state.supports(.navigation) || !state.canGoBack)
            .accessibilityIdentifier("browser.back")

            Button { state.perform(.forward) } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!state.supports(.navigation) || !state.canGoForward)
            .accessibilityIdentifier("browser.forward")
        }
        .controlGroupStyle(.navigation)
    }
}

/// The principal browser location field. A state-backed focus request lets ⌘L
/// reveal a collapsed browser first and focus this field when it actually
/// appears, instead of racing SwiftUI's toolbar installation.
struct BrowserAddressToolbarControl: View {
    let state: BrowserState
    let addressMinWidth: CGFloat
    let addressIdealWidth: CGFloat
    let addressMaxWidth: CGFloat

    /// Drives ⌘L's programmatic focus request only: `@FocusState` never
    /// reports focus for a field hosted in a toolbar item.
    @FocusState private var isAddressFocused: Bool
    /// Whether the field is being edited, read from AppKit's first responder.
    @State private var isAddressEditing = false

    init(
        state: BrowserState,
        addressMinWidth: CGFloat = 240,
        addressIdealWidth: CGFloat = 420,
        addressMaxWidth: CGFloat = 560
    ) {
        self.state = state
        self.addressMinWidth = addressMinWidth
        self.addressIdealWidth = addressIdealWidth
        self.addressMaxWidth = addressMaxWidth
    }

    /// The reload button: a 16pt glyph with a 4pt pad on each side.
    private static let reloadDiameter: CGFloat = 16 + 2 * LiquidGlassMetrics.Spacing.xxSmall
    /// The reload button's inset from the capsule's trailing edge. The 24pt
    /// circle sits in a field of the toolbar's control height, so the
    /// trailing inset matches the vertical one (6pt) and the circle nests
    /// concentrically in the capsule: 18pt = 12pt + 6pt (LAY-4).
    private static let reloadInset = (LiquidGlassMetrics.toolbarControlHeight - reloadDiameter) / 2

    var body: some View {

        // The field is its own Liquid Glass capsule. It lives in its own
        // toolbar item whose shared capsule is hidden (`PaneToolbarContent`),
        // so there is exactly one glass layer.
        // The globe is a fixed glyph rather than a lock: `urlText` is the
        // editable text, not a verified connection state, so it must not
        // claim security. The placeholder must stay "URL":
        // `BrowserAddressFocus` finds the AppKit field by it for ⌘L.
        TextField("URL", text: Bindable(state).urlText)
            .scaledFont(size: 13, weight: .medium)
            .glassLegibleForeground(.primary)
            .focused($isAddressFocused)
            .onSubmit { state.navigate() }
            .toolbarFieldEditing($isAddressEditing)
            .onChange(of: isAddressEditing) { _, isEditing in
                state.isAddressEditing = isEditing
            }
            .onDisappear { state.isAddressEditing = false }
            .accessibilityLabel("Address")
            // Together with the field's own 16pt trailing padding, this
            // clears the reload button overlaid at the capsule's edge.
            .padding(.trailing, LiquidGlassMetrics.Spacing.medium)
            .liquidGlassField(
                systemImage: "globe",
                isFocused: isAddressEditing,
                minHeight: LiquidGlassMetrics.toolbarControlHeight
            )
            .overlay(alignment: .trailing) {
                browserReloadButton
                    .padding(.trailing, Self.reloadInset)
            }
            .frame(
                minWidth: addressMinWidth,
                idealWidth: addressIdealWidth,
                maxWidth: addressMaxWidth
            )
            .layoutPriority(1)
            .accessibilityIdentifier("browser.address")
            .onAppear(perform: fulfillFocusRequestIfNeeded)
            .onChange(of: state.needsAddressFocus) {
                fulfillFocusRequestIfNeeded()
            }
    }

    private func fulfillFocusRequestIfNeeded() {
        guard state.needsAddressFocus else { return }
        state.needsAddressFocus = false
        isAddressFocused = true
        BrowserAddressFocus.selectAddressFieldInKeyWindow()
    }

    private var browserReloadButton: some View {
        Button {
            if state.isLoading {
                state.perform(.stop)
            } else {
                state.perform(.reload)
            }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(size: 12, weight: .medium)
                    .opacity(state.isLoading ? 0 : 1)

                if state.isLoading {
                    if state.engine == .chromium,
                       state.estimatedProgress > 0 {
                        ProgressView(value: state.estimatedProgress)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .frame(width: 16, height: 16)
            // The custom style below does not dim itself when disabled, so
            // the icon carries the enabled state.
            .foregroundStyle(state.supports(.navigation)
                             ? AnyShapeStyle(.secondary)
                             : AnyShapeStyle(.tertiary))
            .animation(LiquidGlassMetrics.stateChange, value: state.isLoading)
            // A 24pt circular hit area with a hover wash and press feedback
            // (BTN-5). It sits inside the address field's glass capsule, so
            // it stays plain-looking rather than adding a second glass layer.
            .padding(LiquidGlassMetrics.Spacing.xxSmall)
        }
        .buttonStyle(.liquidGlassPressable(cornerRadius: 12))
        .disabled(!state.supports(.navigation))
        .help(state.isLoading ? "Stop" : "Reload")
        .accessibilityIdentifier("browser.reload")
    }
}

/// The leading browser navigation controls. Main and Extendo both install
/// them through `PaneToolbarContent`, ahead of the address field's own
/// toolbar item and the tools group.
struct BrowserNavigationToolbarControls: View {
    let state: BrowserState

    var body: some View {
        // Wallets lead, separated from the navigation ControlGroup so they read
        // as their own affordance rather than a third arrow.
        BrowserWalletToolbarControls(state: state)
        BrowserBackForwardToolbarControls(state: state)
    }
}

/// Lower-priority browser actions are split from navigation so AppKit can move
/// them into toolbar overflow without also removing the address field.
struct BrowserToolsToolbarControls: View {
    let state: BrowserState

    @State private var isConfirmingWebsiteDataReset = false
    @State private var isClearingWebsiteData = false
    @State private var isShowingFind = false
    @State private var findText = ""

    var body: some View {

        Menu {
            // One profile exists, so it reads as the checked current one.
            // The earlier "Default Profile" and "Manage Profiles…" items were
            // buttons with empty actions: clicking either did nothing.
            Toggle("Default Profile", isOn: .constant(true))
            Divider()
            Button("Clear All Browser Data…", role: .destructive) {
                isConfirmingWebsiteDataReset = true
            }
            .disabled(isClearingWebsiteData)
            .accessibilityIdentifier("browser.clear-data")
        } label: {
            Label("Profile", systemImage: "person.circle")
        }
        .disabled(!state.supports(.websiteDataReset))
        .accessibilityIdentifier("browser.profile")
        .alert("Clear All Browser Data?", isPresented: $isConfirmingWebsiteDataReset) {
            Button("Cancel", role: .cancel) {}
            Button("Clear and Reload", role: .destructive) {
                clearWebsiteData()
            }
        } message: {
            Text(
                "This clears caches, cookies, local and session storage, IndexedDB, "
                    + "service workers, and other website data for every browser pane. "
                    + "The current page will reload in a clean browser."
            )
        }

        if state.engine == .chromium {
            ControlGroup {
                Button {
                    findText = state.findQuery
                    isShowingFind = true
                } label: {
                    Label("Find in Page", systemImage: "magnifyingglass")
                }
                .disabled(!hasLoadedPage)
                .help("Find in Page")
                .accessibilityIdentifier("browser.find")
                .popover(isPresented: $isShowingFind, arrowEdge: .bottom) {
                    chromiumFindPopover
                }

                Button {
                    state.requestPrint()
                } label: {
                    Label("Print", systemImage: "printer")
                }
                .disabled(!hasLoadedPage)
                .help("Print Page")
                .accessibilityIdentifier("browser.print")

                Button {
                    state.requestSavePage()
                } label: {
                    Label("Save Page", systemImage: "square.and.arrow.down")
                }
                .disabled(!hasLoadedPage)
                .help("Save Page")
                .accessibilityIdentifier("browser.save-page")
            }
            .controlGroupStyle(.navigation)

            if let progress = state.downloadProgress {
                ProgressView(value: progress)
                    .frame(width: 44)
                    .help(state.downloadStatusText)
                    .accessibilityIdentifier("browser.download-progress")
            }
        }

        ControlGroup {
            Menu {
                // An inline picker gives the menu its native checkmark. An
                // image in a menu button's label never rendered, so the menu
                // did not show which mode was active.
                Picker("Appearance", selection: Bindable(state).appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Appearance", systemImage: appearanceIcon)
            }
            .disabled(!state.supports(.appearanceOverride))
            .help("Browser appearance: System, Light, or Dark")
            .accessibilityIdentifier("browser.appearance")

            // A plain Button, not a Toggle: toggles inside a `.navigation`
            // ControlGroup vanish from the toolbar while in the on state.
            Button {
                state.perform(.toggleAnnotation)
            } label: {
                // The toolbar draws its glyphs monochrome on macOS 27, so the
                // accent color alone never showed that Lasso is on (BTN-5).
                // The glyph itself changes as well.
                Label("Lasso", systemImage: state.annotateMode ? "lasso.badge.sparkles" : "lasso")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!state.supports(.annotation))
            .foregroundStyle(state.annotateMode ? Color.accentColor : Color.primary)
            .accessibilityValue(state.annotateMode ? "On" : "Off")
            .help(state.annotateMode
                  ? "Turn off Lasso (⇧⌘A)"
                  : "Select a web element and tell an agent what to fix (⇧⌘A)")
            .accessibilityIdentifier("browser.lasso")

            Button {
                state.perform(.toggleDeveloperTools)
            } label: {
                Label("Developer Tools", systemImage: "hammer")
            }
            .disabled(!state.supports(.developerTools))
            .help(state.showDevTools ? "Close Developer Tools" : "Open Developer Tools")
            .accessibilityIdentifier("browser.developer-tools")
        }
        .controlGroupStyle(.navigation)
        .accessibilityIdentifier("browser.tools")
    }

    private var chromiumFindPopover: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
            // Persistent label above the field; the placeholder is only a
            // hint (FORM-1). Label → field sits tight, field → actions wider
            // (FORM-5).
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text("Find in Page")
                    .font(.headline)

                TextField("Find", text: $findText)
                    .onSubmit {
                        state.requestFind(findText)
                    }
                    .accessibilityLabel("Find in Page")
                    .accessibilityIdentifier("browser.find-field")
                    .liquidGlassField(systemImage: "magnifyingglass")
            }

            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text(findResultSummary)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                        Button {
                            state.requestFind(findText, forward: false, findNext: true)
                        } label: {
                            Label("Previous Match", systemImage: "chevron.up")
                        }
                        .compatGlassIconButton(controlSize: .small)
                        .disabled(findText.isEmpty)
                        .help("Previous Match")
                        .accessibilityIdentifier("browser.find-previous")

                        Button {
                            state.requestFind(findText, forward: true, findNext: true)
                        } label: {
                            Label("Next Match", systemImage: "chevron.down")
                        }
                        .compatGlassIconButton(controlSize: .small)
                        .disabled(findText.isEmpty)
                        .help("Next Match")
                        .accessibilityIdentifier("browser.find-next")

                        Button("Done") {
                            isShowingFind = false
                        }
                        .compatGlassButtonStyle()
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(LiquidGlassMetrics.Spacing.medium)
        .frame(width: 320)
        .onDisappear {
            state.stopFinding()
        }
    }

    private var findResultSummary: String {
        guard state.findMatchCount > 0 else { return "No matches" }
        return "\(state.activeFindMatchOrdinal) of \(state.findMatchCount)"
    }

    private var hasLoadedPage: Bool {
        !state.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var appearanceIcon: String {
        switch state.appearanceMode {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private func clearWebsiteData() {
        guard state.supports(.websiteDataReset) else { return }
        isClearingWebsiteData = true
        Task { @MainActor in
            await BrowserWebsiteData.clearAll()
            state.requestWebsiteDataReset()
            isClearingWebsiteData = false
        }
    }
}

/// AppKit bridge for Safari-style ⌘L behavior. Restricting the lookup to the
/// key window is what lets Main and Extension expose simultaneous address
/// fields without one window stealing focus from the other.
@MainActor
enum BrowserAddressFocus {
    static func selectAddressFieldInKeyWindow() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let field = findAddressTextField(in: window.contentView)
                    ?? findAddressTextField(in: window.contentView?.superview) else { return }
            field.selectText(nil)
        }
    }

    private static func findAddressTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.placeholderString == "URL" {
            return field
        }
        for subview in view.subviews {
            if let found = findAddressTextField(in: subview) {
                return found
            }
        }
        return nil
    }
}
