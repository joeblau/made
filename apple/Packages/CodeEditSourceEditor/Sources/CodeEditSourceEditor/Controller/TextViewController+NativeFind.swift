import AppKit

public extension TextViewController {
    /// Native app entrypoints use the same search model as editor key bindings.
    func showNativeFindPanel(replacing: Bool = false) {
        _ = view
        findViewController?.showFindPanel(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if replacing { findViewController?.viewModel.mode = .replace }
    }

    func hideNativeFindPanel() {
        findViewController?.hideFindPanel(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func findNextNativeMatch() { findViewController?.viewModel.moveToNextMatch() }
    func findPreviousNativeMatch() { findViewController?.viewModel.moveToPreviousMatch() }

    func useSelectionForNativeFind() {
        guard let range = cursorPositions.first?.range, range.length > 0,
              NSMaxRange(range) <= (text as NSString).length else { return }
        findViewController?.viewModel.findText = (text as NSString).substring(with: range)
        findViewController?.viewModel.find()
    }
}

