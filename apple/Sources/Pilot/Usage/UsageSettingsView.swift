import AppKit

/// Consent is stored before credentials are inspected, just as in the former
/// settings form. Detection owns a generation so late reads cannot update a
/// dismissed page or a provider whose consent has since been revoked.
@MainActor
final class UsageSettingsViewController: NSViewController {
    typealias SessionDetector = @Sendable (UsageAccount) async -> Bool
    let defaults: UserDefaults
    let showsPageHeader: Bool
    private let detector: SessionDetector
    private let stack = InspectorNativeUI.vertical(spacing: 20)
    private var toggles: [UsageAccount: NSButton] = [:]
    private var statuses: [UsageAccount: NSTextField] = [:]
    private var enabled: [UsageAccount: Bool] = [:]
    private var signedIn: [UsageAccount: Bool] = [:]
    private var sharingToggle: NSButton?
    private var isActive = false
    private var detectionGeneration = 0
    private var detectionTask: Task<Void, Never>?
    private var preferencesObserver: NSObjectProtocol?
    private var zoomObserver: NSObjectProtocol?
    private var renderedZoom: Double

    init(defaults: UserDefaults = .standard, showsPageHeader: Bool = true,
         detector: @escaping SessionDetector = UsageSettingsViewController.detectSession) {
        self.defaults = defaults
        self.showsPageHeader = showsPageHeader
        self.detector = detector
        self.renderedZoom = InspectorNativeUI.zoom(defaults: defaults)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let scroll = NSScrollView()
        view = scroll
        stack.fillsWidth = true
        if showsPageHeader {
            stack.addArrangedSubview(InspectorNativeUI.label("Usage", size: 24, weight: .bold, defaults: defaults))
            stack.addArrangedSubview(InspectorNativeUI.label(
                "Connect local coding-agent sessions and review their usage in Cockpit.",
                color: .secondaryLabelColor, defaults: defaults
            ))
        }
        for account in UsageAccount.allCases {
            let title = InspectorNativeUI.label(account.title, size: 14, weight: .semibold, defaults: defaults)
            let checkbox = NSButton(checkboxWithTitle: "Allow Cockpit to read \(account.displayName) credentials and usage",
                                    target: self, action: #selector(consentChanged(_:)))
            checkbox.tag = account.rawValue
            checkbox.font = InspectorNativeUI.font(defaults: defaults)
            checkbox.cell?.wraps = true
            checkbox.identifier = .init("usage.consent.\(account.title.lowercased())")
            let status = InspectorNativeUI.label("Disabled", color: .secondaryLabelColor, defaults: defaults)
            status.setAccessibilityLabel("\(account.title) sign-in status")
            status.identifier = .init("usage.status.\(account.title.lowercased())")
            let docs = InspectorActionButton("Install & sign in to \(account.displayName)", symbol: "arrow.up.forward.app") {
                NSWorkspace.shared.open(account.documentationURL)
            }
            let description = InspectorNativeUI.label(account.disclosure, size: 11,
                                                       color: .secondaryLabelColor, defaults: defaults)
            let section = InspectorNativeUI.vertical([title, checkbox, status, docs, description])
            section.fillsWidth = true
            stack.addArrangedSubview(section)
            toggles[account] = checkbox
            statuses[account] = status
        }
        let sharing = NSButton(checkboxWithTitle: "Share AI Usage on Lock Screen and Companions",
                               target: self, action: #selector(sharingChanged(_:)))
        sharing.font = InspectorNativeUI.font(defaults: defaults)
        sharing.cell?.wraps = true
        sharing.identifier = .init("usage.dashboard-sharing")
        sharingToggle = sharing
        let sharingDescription = InspectorNativeUI.label(
            "Shares only aggregate estimated cost, token totals, and plan utilization with widgets and paired companions. Raw usage records, logs, and session identifiers are never included. Turning this off removes published usage snapshots.",
            size: 11, color: .secondaryLabelColor, defaults: defaults
        )
        let sharingSection = InspectorNativeUI.vertical([sharing, sharingDescription])
        sharingSection.fillsWidth = true
        stack.addArrangedSubview(sharingSection)
        stack.addArrangedSubview(InspectorNativeUI.label(
            "All providers are disabled by default. Cockpit does not read auth files, query Keychain, or make usage requests until you enable that provider. Cockpit keeps no token store of its own; the only credentials it ever writes are Grok's and Kimi's rotated tokens, back into each CLI's own credential file.",
            size: 11, color: .secondaryLabelColor, defaults: defaults
        ))
        InspectorNativeUI.scrollDocument(stack, in: scroll, inset: 20)
        synchronizePreferences()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        setPresentationActive(true)
    }
    override func viewWillDisappear() {
        setPresentationActive(false)
        super.viewWillDisappear()
    }

    isolated deinit { setPresentationActive(false) }

    func setPresentationActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        detectionGeneration += 1
        if active {
            _ = view
            preferencesObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    let old = self.enabled
                    self.synchronizePreferences()
                    if old != self.enabled { self.detect() }
                }
            }
            zoomObserver = NotificationCenter.default.addObserver(
                forName: .cockpitUIZoomDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.synchronizePreferences()
                }
            }
            synchronizePreferences()
            detect()
        } else {
            detectionTask?.cancel()
            detectionTask = nil
            if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
            preferencesObserver = nil
            if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
            zoomObserver = nil
        }
    }

    @objc private func consentChanged(_ sender: NSButton) {
        guard let account = UsageAccount(rawValue: sender.tag) else { return }
        defaults.set(sender.state == .on, forKey: account.consentKey)
        synchronizePreferences()
        NotificationCenter.default.post(name: UsageConsent.changedNotification, object: nil)
        detect()
    }

    @objc private func sharingChanged(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: UsageDashboardSharing.preferenceKey)
        NotificationCenter.default.post(name: UsageDashboardSharing.changedNotification, object: nil)
    }

    private func synchronizePreferences() {
        let zoom = InspectorNativeUI.zoom(defaults: defaults)
        if zoom != renderedZoom {
            resizeFonts(in: stack, ratio: zoom / renderedZoom)
            renderedZoom = zoom
        }
        for account in UsageAccount.allCases {
            let value = defaults.bool(forKey: account.consentKey)
            enabled[account] = value
            toggles[account]?.state = value ? .on : .off
            toggles[account]?.font = InspectorNativeUI.font(defaults: defaults)
            renderStatus(account)
        }
        sharingToggle?.state = UsageDashboardSharing.isEnabled(defaults: defaults) ? .on : .off
    }

    private func resizeFonts(in view: NSView, ratio: Double) {
        if let control = view as? NSControl, let font = control.font {
            control.font = NSFontManager.shared.convert(font, toSize: font.pointSize * ratio)
        }
        view.subviews.forEach { resizeFonts(in: $0, ratio: ratio) }
    }

    private func renderStatus(_ account: UsageAccount) {
        let status = statuses[account]
        status?.font = InspectorNativeUI.font(defaults: defaults)
        if enabled[account] != true {
            status?.stringValue = "Disabled"
            status?.textColor = .secondaryLabelColor
        } else if let value = signedIn[account] {
            status?.stringValue = value ? "Signed in" : "Not signed in"
            status?.textColor = value ? .systemGreen : .secondaryLabelColor
        } else {
            status?.stringValue = "Checking sign-in…"
            status?.textColor = .secondaryLabelColor
        }
    }

    private func detect() {
        guard isActive else { return }
        detectionGeneration += 1
        let generation = detectionGeneration
        detectionTask?.cancel()
        signedIn.removeAll()
        UsageAccount.allCases.forEach(renderStatus)
        let enabledAccounts = UsageAccount.allCases.filter { enabled[$0] == true }
        let detector = self.detector
        detectionTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: (UsageAccount, Bool).self) { group in
                for account in enabledAccounts {
                    group.addTask {
                        guard !Task.isCancelled else { return (account, false) }
                        return (account, await detector(account))
                    }
                }
                for await (account, result) in group {
                    guard !Task.isCancelled, let self, self.isActive,
                          generation == self.detectionGeneration,
                          self.defaults.bool(forKey: account.consentKey) else { continue }
                    self.signedIn[account] = result
                    self.renderStatus(account)
                }
            }
        }
    }

    nonisolated static func detectSession(_ account: UsageAccount) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await Task.detached {
            guard !Task.isCancelled else { return false }
            switch account {
            case .claude: return UsageSessions.ClaudeSession.load() != nil
            case .codex: return UsageSessions.CodexSession.load() != nil
            case .grok: return UsageSessions.GrokSession.load() != nil
            case .cursor:
                guard let session = UsageSessions.CursorSession.load() else { return false }
                return !session.isExpired
            case .kimi:
                guard let session = UsageSessions.KimiSession.load() else { return false }
                return !session.isExpired
            }
        }.value
    }
}
