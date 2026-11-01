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
            VStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text("Pinned")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                // Neighboring glass buttons render in one container (shared
                // sampling, no glass on glass); spacing 0 keeps each capsule
                // distinct rather than merging across the grid gap.
                CompatGlassContainer(spacing: 0) {
                    LazyVGrid(
                        columns: [GridItem(
                            .adaptive(minimum: 150, maximum: 240),
                            spacing: LiquidGlassMetrics.Spacing.xSmall
                        )],
                        spacing: LiquidGlassMetrics.Spacing.xSmall
                    ) {
                        ForEach(pinned) { target in
                            quickJumpButton(target)
                        }
                    }
                }
                .frame(maxWidth: 520)
            }
            .padding(.top, LiquidGlassMetrics.Spacing.xSmall)
            .accessibilityIdentifier("workspace.pinned-quick-jump")
        }
    }

    private func quickJumpButton(_ target: PinnedQuickJumpTarget) -> some View {
        Button {
            onSelect(target.id)
        } label: {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Image(systemName: "pin.fill")
                    .scaledFont(size: 9)
                    .foregroundStyle(.secondary)
                Text(target.name)
                    .lineLimit(1)
                Spacer(minLength: LiquidGlassMetrics.Spacing.xxSmall)
                // The shortcut is the point of this row, so it
                // stays at secondary contrast, not tertiary.
                Text(verbatim: "⌘\(target.shortcutNumber)")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Capsule())
        }
        // Peer choices with no single primary (BTN-1): all
        // secondary glass, capsule-shaped.
        .compatGlassButtonStyle()
        .buttonBorderShape(.capsule)
        .help("Jump to \(target.name)")
    }
}
