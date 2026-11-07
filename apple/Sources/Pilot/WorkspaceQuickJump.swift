import AppKit

/// One pinned workspace on the empty-detail quick-jump row.
///
/// The workspace-to-⌘-number mapping is the part worth pinning down: the store
/// sorts pinned workspaces to the front of `workspaces`, and
/// `WorkspaceNumberShortcuts` binds ⌘1…⌘9 to the first nine of that same list.
/// A pinned workspace's number is therefore just its index.
///
/// The cap below is what keeps that true. Pinned entries occupy indices
/// 0..<pinnedCount, and showing at most eight means the highest index reached is
/// 7 — always inside the ⌘1…⌘9 window, so every button can state its shortcut
/// without the hint ever going stale or wrong.
struct PinnedQuickJumpTarget: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// The ⌘-number that selects this workspace.
    let shortcutNumber: Int

    /// Kept short so the row reads as a glance, not a second sidebar — and,
    /// as above, so every entry stays inside the shortcut window.
    static let maximumCount = 8
    /// Matches `workspaces.prefix(9)` in the shortcut binding.
    static let highestShortcutNumber = 9

    static func targets(in workspaces: [Workspace]) -> [PinnedQuickJumpTarget] {
        workspaces.enumerated()
            .filter { $0.element.isPinned }
            .prefix(maximumCount)
            .map { index, workspace in
                let trimmed = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return PinnedQuickJumpTarget(
                    id: workspace.id,
                    name: trimmed.isEmpty ? "Untitled Workspace" : trimmed,
                    shortcutNumber: index + 1
                )
            }
    }
}
