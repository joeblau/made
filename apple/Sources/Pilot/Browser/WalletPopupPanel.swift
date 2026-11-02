@preconcurrency import ChromiumKit
import AppKit
import SwiftUI

/// Presents one wallet action popup at a time, anchored under its toolbar button.
///
/// Chrome renders extension popups outside the page's own surface, and that is a
/// security property rather than a style choice: a page that could paint over a
/// wallet's UI could forge a connection or signing prompt. The popup is a real
/// top-level window above the browser, so page content can never occupy or
/// obscure the same pixels.
///
/// The window is CEF's own, not an `NSPanel` of ours: the popup page only works
/// as a Chrome-style browser (CEF 150 runs extensions only through Chrome's
/// extension system), and CEF supports Chrome style only in windows it creates
/// through its Views framework. A browser parented to one of Pilot's views is
/// always Alloy style, which renders the page without extension bindings, so it
/// never gets past its loading skeleton. See
/// `ChromiumBrowserHostView(extensionPopupScreenFrame:)`.
@MainActor
final class WalletPopupController: NSObject {
    static let shared = WalletPopupController()

    /// Matches the toolbar-popup dimensions extensions are authored against;
    /// Chrome caps action popups at 800×600.
    private static let popupSize = NSSize(width: 400, height: 600)

    /// A full extension page (onboarding, approval) the extension asked to
    /// open as a Chrome tab or window. See `presentExtensionPage(_:)`.
    private static let pageSize = NSSize(width: 1000, height: 760)

    private var hostView: ChromiumBrowserHostView?
    private var presentedWalletID: String?
    private var presentedOrigin: String?
    private var pageHostView: ChromiumBrowserHostView?
    private var pageOrigin: String?

    private override init() {
        super.init()
    }

    var isPresenting: Bool { hostView != nil }

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

        let topLeft = WalletPopupPlacement.originBelow(
            anchor: anchor,
            size: Self.popupSize,
            screenFrame: NSScreen.main?.visibleFrame
        )
        let frame = NSRect(
            x: topLeft.x,
            y: topLeft.y - Self.popupSize.height,
            width: Self.popupSize.width,
            height: Self.popupSize.height
        )
        let host = ChromiumBrowserHostView(extensionPopupScreenFrame: frame)
        host.delegate = self

        hostView = host
        presentedWalletID = wallet.id
        presentedOrigin = WalletPopupNavigationPolicy.origin(of: popupURL)
        host.loadURL(popupURL)
    }

    func dismiss() {
        // Closing the browser closes its CEF-owned window; teardown is
        // asynchronous and reported (and ignored) through didClose.
        hostView?.delegate = nil
        hostView?.close()
        hostView = nil
        presentedWalletID = nil
        presentedOrigin = nil
    }

    /// Routes extension pages that a wallet asks Chrome to open in a new tab or
    /// window (Rabby's onboarding, for example) into a managed window. Chrome
    /// would otherwise open them in its own browser window, with an omnibox,
    /// outside every pane and policy; ChromiumKit closes that window either way.
    func installExtensionPageRouting() {
        ChromiumEngine.shared.extensionPageRequestHandler = { url in
            MainActor.assumeIsolated {
                WalletPopupController.shared.presentExtensionPage(url)
            }
        }
    }

    /// Shows `url` in the extension page window if it belongs to a wallet Pilot
    /// side-loaded; anything else is dropped.
    func presentExtensionPage(_ url: URL) {
        let walletIDs = Set(WalletExtensionRegistry.discover().map(\.id))
        guard let origin = WalletPopupNavigationPolicy.origin(of: url),
              walletIDs.contains(origin) else { return }
        dismiss()
        if let pageHostView, pageOrigin == origin {
            pageHostView.loadURL(url)
            pageHostView.focusBrowser()
            return
        }
        dismissExtensionPage()
        let visible = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: Self.pageSize)
        let size = NSSize(
            width: min(Self.pageSize.width, visible.width),
            height: min(Self.pageSize.height, visible.height)
        )
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let host = ChromiumBrowserHostView(extensionWindowScreenFrame: frame)
        host.delegate = self
        pageHostView = host
        pageOrigin = origin
        host.loadURL(url)
    }

    func dismissExtensionPage() {
        pageHostView?.delegate = nil
        pageHostView?.close()
        pageHostView = nil
        pageOrigin = nil
    }

    fileprivate func allowedOrigin(for browserView: ChromiumBrowserHostView) -> String? {
        if browserView === hostView { return presentedOrigin }
        if browserView === pageHostView { return pageOrigin }
        return nil
    }
}

/// What the popup's main frame may load: the wallet's own pages and nothing
/// else. A wallet that links out (docs, explorers) gets no navigation instead of
/// turning its trusted popup window into an arbitrary web page.
enum WalletPopupNavigationPolicy {
    static func origin(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "chrome-extension",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    static func allows(_ url: URL, walletOrigin: String?) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard let walletOrigin else { return false }
        return origin(of: url) == walletOrigin
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

    @objc(chromiumBrowserHostView:decideNavigationToURL:userGesture:isRedirect:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        decideNavigationTo url: URL,
        userGesture: Bool,
        isRedirect: Bool
    ) -> ChromiumNavigationDecision {
        MainActor.assumeIsolated {
            guard let origin = allowedOrigin(for: browserView),
                  WalletPopupNavigationPolicy.allows(url, walletOrigin: origin)
            else { return .cancel }
            return .allow
        }
    }

    nonisolated func chromiumBrowserHostViewDidCreate(_ browserView: ChromiumBrowserHostView) {
        MainActor.assumeIsolated {
            guard browserView === hostView || browserView === pageHostView else { return }
            // Importing a key means typing into the popup, so it takes key focus.
            browserView.focusBrowser()
        }
    }

    /// Clicking anywhere outside dismisses, the way a menu does. Escape is
    /// handled by the popup window itself.
    @objc(chromiumBrowserHostViewPopupDidResignActive:)
    nonisolated func chromiumBrowserHostViewPopupDidResignActive(
        _ browserView: ChromiumBrowserHostView
    ) {
        MainActor.assumeIsolated {
            guard browserView === hostView else { return }
            dismiss()
        }
    }

    nonisolated func chromiumBrowserHostViewDidClose(_ browserView: ChromiumBrowserHostView) {
        MainActor.assumeIsolated {
            if browserView === hostView {
                dismiss()
            } else if browserView === pageHostView {
                dismissExtensionPage()
            }
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
