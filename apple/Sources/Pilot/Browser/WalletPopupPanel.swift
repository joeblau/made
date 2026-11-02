@preconcurrency import ChromiumKit
import AppKit
import SwiftUI

/// The floating panel a wallet's action popup is drawn in.
///
/// Chrome renders extension popups outside the page's own surface, and that is a
/// security property rather than a style choice: a page that could paint over a
/// wallet's UI could forge a connection or signing prompt. This panel is a real
/// window above the browser view, so page content can never occupy or obscure
/// the same pixels.
final class WalletPopupWindow: NSPanel {
    // Importing a key means typing into the popup, so it has to take key focus —
    // a non-activating panel would leave the keystrokes in the browser pane.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Presents one wallet action popup at a time, anchored under its toolbar button.
@MainActor
final class WalletPopupController: NSObject {
    static let shared = WalletPopupController()

    /// Matches the toolbar-popup dimensions extensions are authored against;
    /// Chrome caps action popups at 800×600.
    private static let popupSize = NSSize(width: 400, height: 600)

    private var panel: WalletPopupWindow?
    private var hostView: ChromiumBrowserHostView?
    private var presentedWalletID: String?
    private var resignObserver: (any NSObjectProtocol)?

    private override init() {
        super.init()
    }

    var isPresenting: Bool { panel != nil }

    /// Clicking the same wallet again closes the popup, matching how a toolbar
    /// button behaves in Chrome.
    func toggle(_ wallet: WalletExtension, anchor: NSRect) {
        if presentedWalletID == wallet.id, isPresenting {
            dismiss()
            return
        }
        present(wallet, anchor: anchor)
    }

    func present(_ wallet: WalletExtension, anchor: NSRect) {
        guard let popupURL = wallet.popupURL else { return }
        dismiss()

        let host = ChromiumBrowserHostView(
            frame: NSRect(origin: .zero, size: Self.popupSize)
        )
        host.delegate = self
        host.autoresizingMask = [.width, .height]

        let panel = WalletPopupWindow(
            contentRect: NSRect(origin: .zero, size: Self.popupSize),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.setFrameTopLeftPoint(
            WalletPopupPlacement.originBelow(
                anchor: anchor,
                size: Self.popupSize,
                screenFrame: NSScreen.main?.visibleFrame
            )
        )

        self.panel = panel
        self.hostView = host
        self.presentedWalletID = wallet.id

        host.loadURL(popupURL)
        panel.makeKeyAndOrderFront(nil)
        host.focusBrowser()

        // Clicking anywhere outside dismisses, the way a menu does. Escape is
        // handled by the panel's own cancel action.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        // Close the CEF browser before tearing down the window: the host view
        // owns a native child window whose teardown is asynchronous.
        hostView?.delegate = nil
        hostView?.close()
        hostView = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        presentedWalletID = nil
    }

}

/// Where the popup sits relative to its toolbar button. Pure geometry, kept off
/// the main actor so it is directly testable without a running app.
enum WalletPopupPlacement {
    static let anchorGap: CGFloat = 6

    /// Top-left corner that puts the popup just under its button, kept on screen
    /// so a button near the right or bottom edge does not push it out of view.
    static func originBelow(
        anchor: NSRect,
        size: NSSize,
        screenFrame: NSRect?
    ) -> NSPoint {
        var x = anchor.minX
        var y = anchor.minY - anchorGap

        guard let screenFrame else { return NSPoint(x: x, y: y) }
        x = min(max(x, screenFrame.minX), screenFrame.maxX - size.width)
        // Flip above the anchor when there is not enough room beneath it.
        if y - size.height < screenFrame.minY {
            y = min(anchor.maxY + anchorGap + size.height, screenFrame.maxY)
        }
        return NSPoint(x: x, y: y)
    }
}

/// CEF delivers these on the main thread but the protocol is not actor-isolated,
/// so each entry point is `nonisolated` and hops back explicitly — the same
/// pattern `ChromiumBrowserView.Coordinator` uses.
extension WalletPopupController: ChromiumBrowserHostViewDelegate {
    /// The popup is the wallet's own UI; it may not spawn further surfaces.
    /// Extension pages requesting a new window are denied, exactly as
    /// `ChromiumNavigationPolicy` denies them for panes.
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        didRequestPopup url: URL,
        disposition: ChromiumPopupDisposition
    ) {
        // Intentionally ignored — no new window is created.
    }

    nonisolated func chromiumBrowserHostViewDidClose(_ browserView: ChromiumBrowserHostView) {
        MainActor.assumeIsolated {
            guard browserView === hostView else { return }
            dismiss()
        }
    }
}

/// Reports its own frame in screen coordinates so a SwiftUI toolbar button can
/// anchor an AppKit panel beneath itself.
struct ScreenFrameReader: NSViewRepresentable {
    let onChange: (NSRect) -> Void

    func makeNSView(context: Context) -> NSView {
        FrameReportingView(onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FrameReportingView)?.onChange = onChange
        (nsView as? FrameReportingView)?.report()
    }

    private final class FrameReportingView: NSView {
        var onChange: (NSRect) -> Void

        init(onChange: @escaping (NSRect) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let window else { return }
            let inWindow = convert(bounds, to: nil)
            onChange(window.convertToScreen(inWindow))
        }
    }
}

/// Wallet buttons, shown to the left of the back/forward arrows and only for
/// Chromium panes — WebKit cannot host the extensions at all, so nothing renders
/// there rather than rendering something disabled.
///
/// Each button opens that wallet's own action popup in a floating panel above
/// the browser, the way Chrome does. Pilot holds no keys and signs nothing: the
/// extension owns its secrets, and this is only the affordance that opens its UI.
///
/// The caller discovers `wallets`: this view is empty until some exist, and a
/// `.task` on an empty `Group` never runs, so discovery here never happened.
struct BrowserWalletToolbarControls: View {
    let state: BrowserState
    let wallets: [WalletExtension]

    @State private var anchors: [String: NSRect] = [:]

    var body: some View {
        Group {
            if state.engine == .chromium, !wallets.isEmpty {
                ForEach(wallets) { wallet in
                    Button {
                        WalletPopupController.shared.toggle(
                            wallet,
                            anchor: anchors[wallet.id] ?? .zero
                        )
                    } label: {
                        Label(wallet.name, systemImage: wallet.systemImageName)
                    }
                    .background(
                        ScreenFrameReader { frame in
                            if anchors[wallet.id] != frame { anchors[wallet.id] = frame }
                        }
                    )
                    .help("Open \(wallet.name)")
                    .accessibilityIdentifier("browser.wallet.\(wallet.id)")
                }
            }
        }
    }
}
