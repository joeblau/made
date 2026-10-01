import AppKit
import SwiftUI

/// Where a menu-level ⌘C / ⌘V lands. The menu owns these key equivalents, so
/// pane host views never see the keystroke; this policy decides which surface
/// handles it from the first responder and the main window's selected pane.
enum PilotPasteboardRoute: Equatable {
    /// Forward the standard `NSText` action down the responder chain.
    case standardEditAction
    /// ⌘C in a device pane copies a device screenshot to the clipboard.
    case deviceScreenshot(paneID: UUID)
    /// ⌘C in an Android pane copies an Android screenshot to the clipboard.
    case androidScreenshot(paneID: UUID)
    /// ⌘V in an Android pane types the clipboard on the device.
    case androidPaste(paneID: UUID)
    /// ⌘V in a terminal pane pastes into its live Ghostty surface, falling
    /// back to the standard action when no surface is mounted.
    case terminalPaste(paneID: UUID)

    static func copy(
        firstResponderIsText: Bool,
        selectedPaneID: UUID?,
        selectedPaneKind: PaneKind?
    ) -> Self {
        // If a text editor (sheet field, address bar, etc.) is the
        // first responder, let it handle the standard copy.
        if firstResponderIsText { return .standardEditAction }
        guard let selectedPaneID else { return .standardEditAction }
        switch selectedPaneKind {
        case .device: return .deviceScreenshot(paneID: selectedPaneID)
        case .android: return .androidScreenshot(paneID: selectedPaneID)
        default: return .standardEditAction
        }
    }

    static func paste(
        firstResponderIsText: Bool,
        selectedPaneID: UUID?,
        selectedPaneKind: PaneKind?
    ) -> Self {
        // If a text editor (sheet field, alert, address bar, etc.) is the
        // first responder, let it handle paste normally — otherwise the
        // terminal beneath the sheet would steal the keystroke.
        if firstResponderIsText { return .standardEditAction }
        guard let selectedPaneID else { return .standardEditAction }
        switch selectedPaneKind {
        case .android: return .androidPaste(paneID: selectedPaneID)
        case .terminal: return .terminalPaste(paneID: selectedPaneID)
        default: return .standardEditAction
        }
    }
}

/// Cut / Copy / Paste / Select All. Replacing `.pasteboard` lets ⌘C capture
/// device screenshots and ⌘V reach Android devices and Ghostty terminals,
/// whose AppKit hosts would otherwise never see the key equivalent. Routing
/// follows the main window's selected pane, as it always has.
struct PilotPasteboardCommands: Commands {
    let store: WorkspaceStore

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                sendStandardEditAction(#selector(NSText.cut(_:)))
            }
            .keyboardShortcut("x", modifiers: .command)

            Button("Copy") {
                copyOrCaptureScreenshot()
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Paste") {
                pasteIntoSelectedPane()
            }
            .keyboardShortcut("v", modifiers: .command)

            // Replacing `.pasteboard` drops the stock Select All too;
            // re-add it so ⌘A works in the notes editor and other fields.
            Button("Select All") {
                sendStandardEditAction(#selector(NSText.selectAll(_:)))
            }
            .keyboardShortcut("a", modifiers: .command)
        }
    }

    private var firstResponderIsText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    private func copyOrCaptureScreenshot() {
        let pane = store.selectedWorkspace?.selectedPane
        switch PilotPasteboardRoute.copy(
            firstResponderIsText: firstResponderIsText,
            selectedPaneID: pane?.id,
            selectedPaneKind: pane?.kind
        ) {
        case .deviceScreenshot(let paneID):
            // The session's `clipboardCopyCount` increment drives the toast.
            DeviceCaptureRegistry.shared.session(for: paneID)
                .copyScreenshotToClipboard()
        case .androidScreenshot(let paneID):
            AndroidDeviceRegistry.shared.session(for: paneID)
                .copyScreenshotToClipboard()
        case .standardEditAction, .androidPaste, .terminalPaste:
            sendStandardEditAction(#selector(NSText.copy(_:)))
        }
    }

    private func pasteIntoSelectedPane() {
        let pane = store.selectedWorkspace?.selectedPane
        switch PilotPasteboardRoute.paste(
            firstResponderIsText: firstResponderIsText,
            selectedPaneID: pane?.id,
            selectedPaneKind: pane?.kind
        ) {
        case .androidPaste(let paneID):
            AndroidDeviceRegistry.shared.session(for: paneID)
                .pasteFromClipboard()
        case .terminalPaste(let paneID):
            if let terminal = GhosttyMetalView.view(for: paneID) {
                terminal.paste(nil)
            } else {
                sendStandardEditAction(#selector(NSText.paste(_:)))
            }
        case .standardEditAction, .deviceScreenshot, .androidScreenshot:
            sendStandardEditAction(#selector(NSText.paste(_:)))
        }
    }

    private func sendStandardEditAction(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
