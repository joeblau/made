import Foundation

enum CopilotDeepLink: Equatable {
    case build
    case dashboard(DashboardFamily)

    init?(url: URL) {
        guard url.scheme?.lowercased() == "walkie",
              let host = url.host?.lowercased() else { return nil }
        if host == "build" {
            self = .build
            return
        }
        guard let family = DashboardFamily(rawValue: host) else { return nil }
        self = .dashboard(family)
    }
}
