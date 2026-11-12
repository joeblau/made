import AppKit
import Observation

/// GitHub's own health for its Actions service, as reported by the public
/// githubstatus.com Statuspage feed. Plain-language levels: the badge says
/// whether GitHub Actions is working, slow, partly down, or down.
enum GitHubActionsHealth: Equatable, Sendable {
    case operational
    case maintenance
    case degraded
    case partialOutage
    case majorOutage

    /// Maps a Statuspage component status. Unknown values return nil so a
    /// new upstream state hides the badge instead of guessing a level.
    init?(statuspage status: String) {
        switch status {
        case "operational": self = .operational
        case "under_maintenance": self = .maintenance
        case "degraded_performance": self = .degraded
        case "partial_outage": self = .partialOutage
        case "major_outage": self = .majorOutage
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .operational: "Operational"
        case .maintenance: "Maintenance"
        case .degraded: "Degraded"
        case .partialOutage: "Partial outage"
        case .majorOutage: "Major outage"
        }
    }

    var color: NSColor {
        switch self {
        case .operational: .systemGreen
        case .maintenance: .systemBlue
        case .degraded: .systemYellow
        case .partialOutage: .systemOrange
        case .majorOutage: .systemRed
        }
    }

    var symbol: String {
        switch self {
        case .operational: "checkmark.circle.fill"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .partialOutage, .majorOutage: "exclamationmark.triangle.fill"
        }
    }

    /// Anything other than operational is worth a badge.
    var isIncident: Bool { self != .operational }
}

/// The Actions component's state plus the newest unresolved incident that names it.
struct GitHubActionsStatus: Equatable, Sendable {
    let health: GitHubActionsHealth
    let incident: String?
    let link: URL

    static let componentName = "Actions"
    static let summaryURL = URL(string: "https://www.githubstatus.com/api/v2/summary.json")!
    static let pageURL = URL(string: "https://www.githubstatus.com")!
    /// The live summary is about 10 KB; anything far larger isn't the feed.
    static let maximumBytes = 256 * 1_024
    static let maximumIncidentLength = 200

    init(health: GitHubActionsHealth, incident: String? = nil, link: URL = GitHubActionsStatus.pageURL) {
        self.health = health
        self.incident = incident
        self.link = link
    }

    /// Parses a Statuspage `summary.json`. The feed is untrusted network
    /// input: it is size-capped, an incident name is trimmed to a short
    /// single line, and the only links produced are on githubstatus.com.
    static func parse(_ data: Data) -> GitHubActionsStatus? {
        guard data.count <= maximumBytes,
              let summary = try? JSONDecoder().decode(Summary.self, from: data),
              let component = summary.components.first(where: { $0.name == componentName }),
              let health = GitHubActionsHealth(statuspage: component.status)
        else { return nil }
        let incident = summary.incidents?.first { incident in
            incident.components?.contains { $0.name == componentName } == true
        }
        return GitHubActionsStatus(health: health,
                                   incident: incident.flatMap { sanitized($0.name) },
                                   link: incident?.id.flatMap(incidentPage) ?? pageURL)
    }

    /// Bounds the name in Unicode scalars before building anything (a
    /// grapheme count lets stacked combining marks through), and folds
    /// control, format and line/paragraph separators into spaces so the
    /// name can't add a line to the tooltip.
    private static func sanitized(_ name: String) -> String? {
        let scalars = name.unicodeScalars
        var line = String.UnicodeScalarView()
        for scalar in scalars.prefix(maximumIncidentLength) {
            let breaks = CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
            line.append(breaks ? " " : scalar)
        }
        let text = String(line).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return scalars.count > maximumIncidentLength ? text + "…" : text
    }

    /// Links only to GitHub's own status site. Statuspage shortlinks
    /// (stspg.io) are shared by every Statuspage tenant, so the incident
    /// page is rebuilt from its id instead of trusting the feed's URL.
    private static func incidentPage(_ id: String) -> URL? {
        guard (1...64).contains(id.utf8.count),
              id.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return URL(string: "https://www.githubstatus.com/incidents/\(id)")
    }

    private struct Summary: Decodable {
        struct Component: Decodable {
            let name: String
            let status: String
        }
        struct IncidentComponent: Decodable {
            let name: String
        }
        struct Incident: Decodable {
            let id: String?
            let name: String
            let components: [IncidentComponent]?
        }
        let components: [Component]
        let incidents: [Incident]?
    }
}

/// Polls GitHub's public status feed while any inspector shows the Actions
/// tab. Status is global rather than per repository, so the app shares one
/// store: one fetch serves every window and workspace, and switching
/// workspaces keeps the last answer on screen.
@Observable
@MainActor
final class GitHubStatusStore {
    /// Nil until a fetch succeeds, and again after one fails: an unknown
    /// state hides the badge rather than leaving a stale incident up.
    private(set) var status: GitHubActionsStatus?
    @ObservationIgnored private let fetch: @Sendable () async throws -> Data
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollers: Set<ObjectIdentifier> = []
    @ObservationIgnored private var fetchGeneration = 0

    init(status: GitHubActionsStatus? = nil, pollInterval: Duration = .seconds(300),
         fetch: @escaping @Sendable () async throws -> Data = { try await GitHubStatusStore.liveFetch() }) {
        self.status = status
        self.pollInterval = pollInterval
        self.fetch = fetch
    }
    isolated deinit { pollTask?.cancel() }

    var isPolling: Bool { pollTask != nil }

    /// Each inspector registers while its Actions tab is visible; polling
    /// runs while at least one does.
    func setPolling(_ polling: Bool, for owner: AnyObject) {
        if polling { pollers.insert(ObjectIdentifier(owner)) } else { pollers.remove(ObjectIdentifier(owner)) }
        let shouldPoll = !pollers.isEmpty
        guard shouldPoll != isPolling else { return }
        guard shouldPoll else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            // `self?` holds the store only for the fetch, never across the
            // sleep, so dropping the inspector releases it promptly.
            while !Task.isCancelled, self != nil {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Fetches now. A newer refresh supersedes an older one still in flight,
    /// so a slow response can't overwrite a fresher answer.
    func refresh() async {
        fetchGeneration += 1
        let generation = fetchGeneration
        let data = try? await fetch()
        guard generation == fetchGeneration, !Task.isCancelled else { return }
        status = data.flatMap(GitHubActionsStatus.parse)
    }

    nonisolated static func liveFetch() async throws -> Data {
        var request = URLRequest(url: GitHubActionsStatus.summaryURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The request timeout only bounds idle gaps; the resource timeout
        // bounds the whole transfer so a drip-fed response can't stall a poll.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let limit = GitHubActionsStatus.maximumBytes
        if response.expectedContentLength > Int64(limit) { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        data.reserveCapacity(max(0, min(Int(response.expectedContentLength), limit)))
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}

/// A small tinted capsule in the Actions header naming GitHub's incident
/// level. Clicking it opens the incident (or githubstatus.com).
final class GitHubStatusBadge: NSButton {
    private(set) var status: GitHubActionsStatus?
    var onOpen: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = .init("inspector.github-status")
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        wantsLayer = true
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(openStatus)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    /// Shows the badge only for an incident; operational or unknown hides it.
    func update(_ status: GitHubActionsStatus?, defaults: UserDefaults = .standard) {
        guard let status, status.health.isIncident else {
            self.status = nil
            isHidden = true
            return
        }
        let wasHidden = isHidden
        self.status = status
        let health = status.health
        let font = InspectorNativeUI.font(11, weight: .semibold, defaults: defaults)
        attributedTitle = NSAttributedString(string: "GitHub · \(health.label)", attributes: [
            .font: font,
            .foregroundColor: health.color,
        ])
        image = NSImage(systemSymbolName: health.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .semibold))
        contentTintColor = health.color
        layer?.backgroundColor = health.color.withAlphaComponent(0.16).cgColor
        let detail = status.incident.map { " — \($0)" } ?? ""
        toolTip = "GitHub Actions: \(health.label)\(detail)\nClick to open githubstatus.com"
        setAccessibilityLabel("GitHub Actions status: \(health.label)\(detail)")
        setAccessibilityHelp("Opens GitHub's status page")
        isHidden = false
        if wasHidden { CockpitMotion.present(self) }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 14, height: max(size.height, 14) + 6)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    @objc private func openStatus() {
        guard let link = status?.link else { return }
        if let onOpen { onOpen(link) } else { NSWorkspace.shared.open(link) }
    }
}
