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

    @FocusState private var isAddressFocused: Bool

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

    var body: some View {

        TextField("URL", text: Bindable(state).urlText)
            .textFieldStyle(.plain)
            .scaledFont(size: 13, weight: .medium)
            .focused($isAddressFocused)
            .onSubmit { state.navigate() }
            .onChange(of: isAddressFocused) { _, isFocused in
                state.isAddressEditing = isFocused
            }
            .padding(.leading, 12)
            .padding(.trailing, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                browserReloadButton
                    .padding(.trailing, 10)
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
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .disabled(!state.supports(.navigation))
        .help(state.isLoading ? "Stop" : "Reload")
        .accessibilityIdentifier("browser.reload")
    }
}

/// Complete navigation/location composition used by Main. Extension installs
/// these as separate navigation and principal toolbar items.
struct BrowserNavigationToolbarControls: View {
    let state: BrowserState

    var body: some View {
        // Wallets lead, separated from the navigation ControlGroup so they read
        // as their own affordance rather than a third arrow.
        BrowserWalletToolbarControls(state: state)
        BrowserBackForwardToolbarControls(state: state)
        BrowserAddressToolbarControl(state: state)
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
            Button("Default Profile") {}
            Divider()
            Button("Manage Profiles...") {}
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
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Button {
                        state.appearanceMode = mode
                    } label: {
                        HStack {
                            Text(mode.rawValue)
                            if state.appearanceMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
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
                Label("Lasso", systemImage: "lasso")
            }
            .disabled(!state.supports(.annotation))
            .foregroundStyle(state.annotateMode ? Color.accentColor : Color.primary)
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
        VStack(alignment: .leading, spacing: 10) {
            TextField("Find", text: $findText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    state.requestFind(findText)
                }
                .accessibilityIdentifier("browser.find-field")

            HStack {
                Text(findResultSummary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    state.requestFind(findText, forward: false, findNext: true)
                } label: {
                    Label("Previous Match", systemImage: "chevron.up")
                }
                .labelStyle(.iconOnly)
                .disabled(findText.isEmpty)
                .accessibilityIdentifier("browser.find-previous")

                Button {
                    state.requestFind(findText, forward: true, findNext: true)
                } label: {
                    Label("Next Match", systemImage: "chevron.down")
                }
                .labelStyle(.iconOnly)
                .disabled(findText.isEmpty)
                .accessibilityIdentifier("browser.find-next")

                Button("Done") {
                    isShowingFind = false
                }
            }
        }
        .padding(12)
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

/// Complete browser toolbar shared by Main and Extendo.
struct BrowserToolbarControls: View {
    let state: BrowserState

    var body: some View {
        BrowserNavigationToolbarControls(state: state)
        BrowserToolsToolbarControls(state: state)
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
