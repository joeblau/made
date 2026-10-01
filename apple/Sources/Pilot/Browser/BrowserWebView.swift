import AppKit
@preconcurrency import WebKit

enum BrowserWebShortcutPolicy {
    static func handlesReload(
        isPaneSelected: Bool,
        hasCommand: Bool,
        hasControl: Bool,
        hasOption: Bool,
        characters: String
    ) -> Bool {
        isPaneSelected
            && hasCommand
            && !hasControl
            && !hasOption
            && characters == "r"
    }

    /// Browser editing shortcuts that should stay inside WKWebView. Shifted ⌘A
    /// is deliberately excluded because Pilot owns it for Lasso.
    static func keepsNativeEditingShortcut(characters: String, hasShift: Bool) -> Bool {
        (!hasShift && ["c", "v", "x", "a"].contains(characters))
            || characters == "z" // both ⌘Z and ⇧⌘Z (Redo)
    }
}

final class BrowserWebView: WKWebView {
    var onReload: (() -> Void)?
    var onSelect: (() -> Void)?
    var isPaneSelected = false
    private var reloadKeyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeReloadKeyMonitor()
        } else {
            installReloadKeyMonitor()
        }
    }

    isolated deinit {
        removeReloadKeyMonitor()
    }

    override func mouseDown(with event: NSEvent) {
        // The WebView swallows clicks before SwiftUI's pane-level
        // `.onTapGesture` sees them, so the pane never becomes selected.
        // Notify out before the WebView consumes the event.
        onSelect?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let plainCommand = !event.modifierFlags.contains(.control)
            && !event.modifierFlags.contains(.option)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if BrowserWebShortcutPolicy.handlesReload(
            isPaneSelected: isPaneSelected,
            hasCommand: true,
            hasControl: event.modifierFlags.contains(.control),
            hasOption: event.modifierFlags.contains(.option),
            characters: chars
        ) {
            onReload?()
            return true
        }

        // Keep standard editing shortcuts native, but only plain ⌘A is Select
        // All. ⇧⌘A belongs to Pilot's Lasso command and must reach the menu.
        let hasShift = event.modifierFlags.contains(.shift)
        if plainCommand,
           BrowserWebShortcutPolicy.keepsNativeEditingShortcut(
               characters: chars,
               hasShift: hasShift
           ) {
            return super.performKeyEquivalent(with: event)
        }

        // Otherwise give the app's main menu first crack — a focused WKWebView
        // otherwise swallows global shortcuts (⌘T, ⌘B, ⌘L, ⌘0, ⌘±, …) before
        // they ever reach the menu.
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    /// WebKit's internal content view can consume ⌘R before AppKit asks the
    /// outer `WKWebView` for key equivalents. A local monitor runs before that
    /// responder-chain handoff and targets only the selected browser in the
    /// event's window.
    private func installReloadKeyMonitor() {
        guard reloadKeyMonitor == nil else { return }
        reloadKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  BrowserWebShortcutPolicy.handlesReload(
                      isPaneSelected: self.isPaneSelected,
                      hasCommand: event.modifierFlags.contains(.command),
                      hasControl: event.modifierFlags.contains(.control),
                      hasOption: event.modifierFlags.contains(.option),
                      characters: event.charactersIgnoringModifiers?.lowercased() ?? ""
                  ) else {
                return event
            }
            self.onReload?()
            return nil
        }
    }

    private func removeReloadKeyMonitor() {
        if let reloadKeyMonitor {
            NSEvent.removeMonitor(reloadKeyMonitor)
        }
        reloadKeyMonitor = nil
    }
}
