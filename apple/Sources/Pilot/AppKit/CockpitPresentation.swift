import AppKit

/// Explicit keyboard navigation focuses the feature's editing surface rather
/// than an arbitrary scroll view or hidden control in its hierarchy.
@MainActor
protocol CockpitPaneInputFocusing: AnyObject {
    func focusPaneInput()
}

/// Native presentation is independent of the lifetime of its session/model.
@MainActor
protocol CockpitPanePresenting: AnyObject {
    func updatePresentation(isActive: Bool, isSelected: Bool)
}

/// Called only when the user closes a pane, never when its view is detached.
@MainActor
protocol CockpitPaneClosing: AnyObject {
    func closePane()
}

/// Save/conflict resolution must complete before the model or session is removed.
@MainActor
protocol CockpitPaneCloseValidating: AnyObject {
    /// Recheck after other asynchronous saves or engine shutdown finishes.
    var isReadyToClose: Bool { get }
    func prepareToClose(_ completion: @escaping @MainActor (Bool) -> Void)
}

extension CockpitPaneCloseValidating {
    var isReadyToClose: Bool { true }
}

/// A retained pane must follow workspace root changes without recreating its session.
@MainActor
protocol CockpitPaneContextUpdating: AnyObject {
    func updateContext(rootPath: String?)
}
