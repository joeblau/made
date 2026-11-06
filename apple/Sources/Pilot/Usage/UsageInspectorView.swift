import AppKit
import Observation

enum SettingsTab {
    static let storageKey = "settings.selectedTab"
    static let general = "general"
    static let usage = "usage"
    static let drones = "drones"
}

enum UsageResetCountdown {
    static func text(until date: Date, now: Date) -> String {
        let remaining = Int(date.timeIntervalSince(now))
        guard remaining > 0 else { return "resetting…" }
        let days = remaining / 86400
        let hours = (remaining % 86400) / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return String(format: "resets in %dm %02ds", minutes, seconds)
    }
}
enum UsageRetryCountdown {
    static func text(until date: Date, now: Date) -> String {
        let remaining = Int(ceil(date.timeIntervalSince(now)))
        guard remaining > 0 else { return "Retrying usage update…" }
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        if hours > 0 { return "Retrying in \(hours)h \(minutes)m." }
        return String(format: "Retrying in %dm %02ds.", minutes, seconds)
    }
}

/// Shared UI metadata, never credential contents.
enum UsageAccount: Int, CaseIterable, Sendable {
    case claude, codex, kimi, grok, cursor
    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .kimi: "Kimi"
        case .grok: "Grok"
        case .cursor: "Cursor"
        }
    }
    var displayName: String { self == .claude || self == .kimi ? title + " Code" : title }
    var consentKey: String {
        switch self {
        case .claude: UsageConsent.claudeKey
        case .codex: UsageConsent.codexKey
        case .kimi: UsageConsent.kimiKey
        case .grok: UsageConsent.grokKey
        case .cursor: UsageConsent.cursorKey
        }
    }
    var symbol: String {
        switch self {
        case .claude: "BrandAnthropic"
        case .codex: "BrandOpenAI"
        case .kimi: "BrandMoonshot"
        case .grok: "BrandGrok"
        case .cursor: "BrandCursor"
        }
    }
    var tint: NSColor {
        switch self {
        case .claude: .systemOrange
        case .codex: .systemGreen
        case .kimi: .systemPurple
        case .grok: .systemRed
        case .cursor: .systemBlue
        }
    }
    var signInMessage: String {
        switch self {
        case .cursor: "Not signed in. Sign in to the Cursor app, then refresh."
        case .kimi: "Not signed in. Run kimi login in a terminal to log in, then refresh."
        default: "Not signed in. Run \(title.lowercased()) in a terminal to log in, then refresh."
        }
    }
    var documentationURL: URL {
        let string: String
        switch self {
        case .claude: string = "https://code.claude.com/docs/en/overview"
        case .codex: string = "https://developers.openai.com/codex/cli"
        case .kimi: string = "https://www.kimi.ai/help/kimi-code/cli-getting-started"
        case .grok: string = "https://docs.x.ai/build/overview"
        case .cursor: string = "https://cursor.com/docs"
        }
        return URL(string: string)!
    }
    var disclosure: String {
        switch self {
        case .claude:
            "When enabled, Cockpit reads Claude Code's credential file or Keychain item and sends its bearer token only to Anthropic's usage endpoint. Keychain access may prompt once."
        case .codex:
            "When enabled, Cockpit reads ~/.codex/auth.json and sends its bearer token only to ChatGPT's Codex usage endpoint."
        case .kimi:
            "When enabled, Cockpit reads Kimi Code's credential file under $KIMI_CODE_HOME (or ~/.kimi-code), with legacy ~/.kimi fallback, and sends its bearer token only to Kimi's usage and sign-in endpoints. Kimi's fifteen-minute tokens rotate on refresh, so when the stored token has expired Cockpit refreshes it and saves the rotated token back to Kimi Code's own credential file — keeping both Cockpit and the kimi CLI signed in."
        case .grok:
            "When enabled, Cockpit reads $GROK_HOME/auth.json (or ~/.grok/auth.json) and sends its bearer token only to xAI's usage and sign-in endpoints. Grok's six-hour tokens rotate on refresh, so when the stored token has expired Cockpit refreshes it and saves the rotated token back to auth.json — keeping both Cockpit and the grok CLI signed in."
        case .cursor:
            "When enabled, Cockpit reads the Cursor app's local state database (~/Library/Application Support/Cursor) and sends its session token only to cursor.com's usage endpoints."
        }
    }
    @MainActor func state(in store: UsageStore) -> ProviderState {
        switch self {
        case .claude: store.anthropic
        case .codex: store.openAI
        case .kimi: store.moonshot
        case .grok: store.xAI
        case .cursor: store.anysphere
        }
    }
}

@MainActor
final class UsageViewController: NSViewController {
    let store: UsageStore
    let defaults: UserDefaults
    var onOpenSettings: (() -> Void)?
    private let header = InspectorSectionHeader()
    private let stack = InspectorNativeUI.vertical()
    private var cards: [UsageAccount: NativeProviderUsageCard] = [:]
    private var isActive = false
    private var generation = 0
    private var timer: Timer?
    private var preferencesObserver: NSObjectProtocol?
    private var zoomObserver: NSObjectProtocol?
    init(store: UsageStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        stack.fillsWidth = true
        for account in UsageAccount.allCases {
            let card = NativeProviderUsageCard(account: account, defaults: defaults)
            card.enable = { [weak self] in
                guard let self else { return }
                self.defaults.set(true, forKey: account.consentKey)
                NotificationCenter.default.post(name: UsageConsent.changedNotification, object: nil)
            }
            card.openSettings = { [weak self] in
                guard let self else { return }
                self.defaults.set(SettingsTab.usage, forKey: SettingsTab.storageKey)
                self.onOpenSettings?()
            }
            cards[account] = card
            stack.addArrangedSubview(card)
        }
        InspectorNativeUI.scrollDocument(stack, in: scroll, inset: 8)
        let layout = InspectorNativeUI.vertical([header, scroll], spacing: 0)
        layout.fillsWidth = true
        InspectorNativeUI.pin(layout, in: view)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        header.refresh = { [weak self] in self?.store.reload() }
        render()
    }
    override func viewDidAppear() { super.viewDidAppear(); setPresentationActive(true) }
    override func viewWillDisappear() { setPresentationActive(false); super.viewWillDisappear() }
    isolated deinit { setPresentationActive(false) }

    func setPresentationActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        generation += 1
        if active {
            _ = view
            preferencesObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.render(force: true) }
            }
            zoomObserver = NotificationCenter.default.addObserver(
                forName: .cockpitUIZoomDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.render(force: true)
                }
            }
            observe(generation: generation)
        } else {
            timer?.invalidate()
            timer = nil
            if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
            preferencesObserver = nil
            if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
            zoomObserver = nil
        }
    }
    func refresh() { if isViewLoaded { render() } }
    private func observe(generation: Int) {
        guard isActive, generation == self.generation else { return }
        withObservationTracking { render() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, generation == self.generation else { return }
                self.observe(generation: generation)
            }
        }
    }
    private func render(force: Bool = false) {
        guard isViewLoaded else { return }
        header.update(title: "Plan Usage", symbol: "chart.bar.xaxis", loading: store.isLoading,
                      refreshHelp: "Refresh usage", defaults: defaults)
        for account in UsageAccount.allCases { cards[account]?.update(state: account.state(in: store), force: force) }
        let needsTimer = isActive && cards.values.contains { $0.hasCountdown }
        if needsTimer, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.cards.values.forEach { $0.updateCountdowns(now: Date()) }
                }
            }
        } else if !needsTimer { timer?.invalidate(); timer = nil }
    }
}

@MainActor
private final class NativeProviderUsageCard: NSView {
    let account: UsageAccount
    let defaults: UserDefaults
    var enable: (() -> Void)?
    var openSettings: (() -> Void)?
    private let stack = InspectorNativeUI.vertical()
    private var state: ProviderState?
    private var countdowns: [(field: NSTextField, deadline: Date, retry: Bool)] = []
    var hasCountdown: Bool { !countdowns.isEmpty }
    init(account: UsageAccount, defaults: UserDefaults) {
        self.account = account
        self.defaults = defaults
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CockpitCardStyle.cornerRadius
        stack.fillsWidth = true
        InspectorNativeUI.pin(stack, in: self, inset: 10)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = CockpitCardStyle.fillColor.cgColor
    }
    func update(state newState: ProviderState, force: Bool) {
        guard force || state != newState else { return }
        state = newState
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        countdowns.removeAll()
        let icon = NSImageView(image: NSImage(named: account.symbol) ?? NSImage())
        icon.contentTintColor = account.tint
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let heading = InspectorNativeUI.horizontal([icon, label(account.title, weight: .semibold)])
        if let plan = newState.displayedUsage?.planLabel {
            heading.addArrangedSubview(label(plan, size: 10, color: .secondaryLabelColor))
        }
        stack.addArrangedSubview(heading)
        switch newState {
        case .disabled:
            stack.addArrangedSubview(label("Allow Cockpit to read this CLI's credentials and request plan usage.", color: .secondaryLabelColor))
            stack.addArrangedSubview(InspectorActionButton("Enable Usage", symbol: "checkmark.circle") { [weak self] in self?.enable?() })
        case .loading:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            spinner.setAccessibilityLabel("Loading usage")
            stack.addArrangedSubview(InspectorNativeUI.horizontal([spinner, label("Loading usage…", color: .secondaryLabelColor)]))
        case .notSignedIn: setup(account.signInMessage)
        case .error(let message): setup(message)
        case .usage(let usage): appendUsage(usage)
        case .rateLimited(let deadline, let usage):
            if let usage { appendUsage(usage) }
            stack.addArrangedSubview(label(usage == nil ? "Usage updates temporarily rate limited." :
                "Usage updates temporarily rate limited. Showing last available usage.", color: .secondaryLabelColor))
            appendCountdown(deadline, retry: true)
        }
        updateCountdowns(now: Date())
        layer?.backgroundColor = CockpitCardStyle.fillColor.cgColor
    }
    func updateCountdowns(now: Date) {
        for item in countdowns {
            item.field.stringValue = item.retry ? UsageRetryCountdown.text(until: item.deadline, now: now)
                : UsageResetCountdown.text(until: item.deadline, now: now)
        }
    }
    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        InspectorNativeUI.label(text, size: size, weight: weight, color: color, defaults: defaults)
    }
    private func setup(_ message: String) {
        stack.addArrangedSubview(label(message, color: .secondaryLabelColor))
        stack.addArrangedSubview(InspectorActionButton("Set Up", symbol: "arrow.up.forward") { [weak self] in self?.openSettings?() })
    }
    private func appendUsage(_ usage: ProviderUsage) {
        if usage.windows.isEmpty && usage.credits == nil {
            stack.addArrangedSubview(label("No usage reported for this window.", color: .secondaryLabelColor))
        }
        for window in usage.windowsInDisplayOrder {
            let value = label("\(Int((window.utilization * 100).rounded()))%", weight: .semibold,
                              color: window.utilization >= 0.9 ? .systemRed : .labelColor)
            value.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(InspectorNativeUI.horizontal([label(window.name, weight: .medium), NSView(), value]))
            let level = UsageProgressBar(fraction: window.utilization,
                                         tint: window.utilization >= 0.9 ? .systemRed : account.tint)
            level.setAccessibilityLabel(window.name)
            level.setAccessibilityValue(value.stringValue)
            stack.addArrangedSubview(level)
            if let reset = window.resetsAt { appendCountdown(reset, retry: false) }
        }
        if let credits = usage.credits, !credits.isEmpty { appendCredits(credits) }
    }
    private func appendCountdown(_ deadline: Date, retry: Bool) {
        let field = label("", color: .secondaryLabelColor)
        field.font = .monospacedDigitSystemFont(ofSize: InspectorNativeUI.font(defaults: defaults).pointSize, weight: .regular)
        countdowns.append((field, deadline, retry))
        stack.addArrangedSubview(field)
    }
    private func appendCredits(_ credits: CreditInfo) {
        let hasMonthly = credits.unlimited || credits.used != nil || credits.limit != nil || credits.utilization != nil
        if let balance = credits.balance { creditLine(hasMonthly ? "Balance" : "Credits", amount(balance, unit: credits.unit)) }
        if credits.unlimited {
            if let used = credits.used { creditLine("Used this month", amount(used, unit: credits.unit)) }
            creditLine(credits.balance == nil && credits.used == nil ? "Credits" : "Monthly limit", "Unlimited")
        } else if let used = credits.used, let limit = credits.limit {
            creditLine(credits.balance == nil ? "Credits" : "Monthly", "\(amount(used, unit: credits.unit)) / \(amount(limit, unit: credits.unit)) used")
        } else if let utilization = credits.utilization {
            creditLine(credits.balance == nil ? "Credits" : "Monthly", "\(Int((utilization * 100).rounded()))% used")
        } else if let used = credits.used {
            creditLine(credits.balance == nil ? "Credits" : "Monthly", "\(amount(used, unit: credits.unit)) used")
        } else if let limit = credits.limit {
            creditLine(credits.balance == nil ? "Credits" : "Monthly", "\(amount(limit, unit: credits.unit)) limit")
        }
    }
    private func creditLine(_ title: String, _ value: String) {
        stack.addArrangedSubview(InspectorNativeUI.horizontal([label(title, weight: .medium, color: .secondaryLabelColor), NSView(), label(value)]))
    }
    private func amount(_ value: Double, unit: CreditUnit) -> String {
        switch unit {
        case .credits: "\(value.formatted(.number.grouping(.automatic).precision(.fractionLength(0...2)))) credits"
        case .currency(let code): value.formatted(.currency(code: code).precision(.fractionLength(2)))
        }
    }
}

/// A slim capsule progress bar: a rounded track with a rounded fill.
@MainActor
final class UsageProgressBar: NSView {
    static let height: CGFloat = 6
    private let fraction: Double
    private let tint: NSColor

    init(fraction: Double, tint: NSColor) {
        self.fraction = min(max(fraction, 0), 1)
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        // Keep a visible dot for tiny values rather than a sliver.
        let width = max(bounds.height, bounds.width * fraction)
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}
