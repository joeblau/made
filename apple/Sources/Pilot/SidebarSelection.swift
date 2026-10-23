import Foundation

/// Single-typed selection model for the sidebar `List`, which mixes the
/// permanent Notes row with the per-workspace rows.
enum SidebarSelection: Hashable {
    case notes
    case remoteDesktop
    case docker
    case agenticUse
    case runners
    case workspace(UUID)
}
