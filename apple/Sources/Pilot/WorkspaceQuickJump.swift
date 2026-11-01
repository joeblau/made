import SwiftUI

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

/// Quick-jump buttons for pinned workspaces, shown under the empty detail area.
///
/// An empty detail area is exactly when someone has not learned the ⌘-number
/// shortcuts yet, so each button states its own. Renders nothing when nothing is
/// pinned, leaving the plain "select from the sidebar" state untouched.
struct PinnedQuickJumpRow: View {
    let workspaces: [Workspace]
    let onSelect: (UUID) -> Void

    var body: some View {
        let pinned = PinnedQuickJumpTarget.targets(in: workspaces)
        if !pinned.isEmpty {
            VStack(spacing: 8) {
                Text("Pinned")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(pinned) { target in
                        Button {
                            onSelect(target.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "pin.fill")
                                    .scaledFont(size: 9)
                                    .foregroundStyle(.secondary)
                                Text(target.name)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                // The shortcut is the point of this row, so it
                                // stays at secondary contrast, not tertiary.
                                Text(verbatim: "⌘\(target.shortcutNumber)")
                                    .scaledFont(size: 10)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .compatGlassButtonStyle()
                        .help("Jump to \(target.name)")
                    }
                }
                .frame(maxWidth: 520)
            }
            .padding(.top, 8)
            .accessibilityIdentifier("workspace.pinned-quick-jump")
        }
    }
}
