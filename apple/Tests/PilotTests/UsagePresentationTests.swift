import AppKit
import Testing
@testable import Pilot

@Suite("Usage subscriptions presentation", .serialized)
@MainActor
struct UsagePresentationTests {
    @Test("Usage card review", .enabled(if: ProcessInfo.processInfo.environment["MADE_USAGE_REVIEW_OUTPUT"] != nil))
    func reviewCards() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MADE_USAGE_REVIEW_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "UsagePresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        UsageAccount.allCases.forEach { defaults.set(true, forKey: $0.consentKey) }
        let weekly = UsageWindow(id: "weekly", name: "Weekly", utilization: 0.81, resetsAt: Date().addingTimeInterval(86_400))
        let budget = CreditInfo(balance: 9.11, unit: .currency("USD"), used: 12.5, limit: 50)
        let store = UsageStore(defaults: defaults, fetchers: .init(
            claude: { .success(ProviderUsage(planLabel: "Max", windows: [weekly], credits: budget)) },
            codex: { .success(ProviderUsage(planLabel: "Pro", windows: [weekly], credits: CreditInfo(balance: 37_703.18))) },
            cursor: { .success(ProviderUsage(planLabel: "Ultra", windows: [weekly], credits: budget)) },
            grok: { .success(ProviderUsage(planLabel: "SuperGrok", windows: [weekly], credits: budget)) },
            kimi: { .success(ProviderUsage(planLabel: "Vivace", windows: [weekly], credits: budget)) }
        ))
        store.reload()
        await store.waitForCurrentLoad()
        let controller = UsageViewController(store: store, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 1_350), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 400, height: 1_350))
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 1_350)
        defer { window.orderOut(nil); window.close() }
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            window.makeKeyAndOrderFront(nil)
            let frame = try #require(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            frame.displayIfNeeded()
            #expect(controller.view.bounds.height > 1_000)
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.effectiveAppearance.performAsCurrentDrawingAppearance {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
            }
            let suffix = appearance == .darkAqua ? "dark" : "light"
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("usage-\(suffix).png"))
        }
    }

    @Test("Settings switches hide subscriptions and the inspector links back to their controls")
    func subscriptionVisibility() async throws {
        let suite = "UsagePresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UsageConsent.kimiKey)
        let usage = ProviderUsage(planLabel: "Vivace", windows: [
            UsageWindow(id: "weekly", name: "Weekly", utilization: 0.35, resetsAt: nil),
        ], credits: CreditInfo(balance: 9.11, unit: .currency("USD"), used: 12.5, limit: 50))
        let store = UsageStore(defaults: defaults, fetchers: .init(
            claude: { .notSignedIn }, codex: { .notSignedIn }, cursor: { .notSignedIn },
            grok: { .notSignedIn }, kimi: { .success(usage) }
        ))
        store.start()
        defer { store.stop() }
        await store.waitForCurrentLoad()
        let controller = UsageViewController(store: store, defaults: defaults)
        let kimi = try #require(view("usage.card.kimi", in: controller.view))
        let cursor = try #require(view("usage.card.cursor", in: controller.view))
        #expect(!kimi.isHidden && cursor.isHidden)
        let bars = descendants(kimi).compactMap { $0 as? UsageProgressBar }
        #expect(bars.count == 2, "Subscription and extra spending have independent bars")
        let credits = try #require(view("usage.credits.kimi", in: kimi))
        #expect(credits.accessibilityValue() as? String == "25% used")

        var opened = false
        controller.onOpenSettings = { opened = true }
        let manage = try #require(view("usage.manage-subscriptions", in: controller.view) as? NSButton)
        manage.performClick(nil)
        #expect(opened && defaults.string(forKey: SettingsTab.storageKey) == SettingsTab.usage)

        let settings = UsageSettingsViewController(defaults: defaults, detector: { _ in .available })
        let toggle = try #require(view("usage.consent.kimi", in: settings.view) as? NSSwitch)
        toggle.performClick(nil)
        controller.refresh()
        #expect(kimi.isHidden)
        for _ in 0..<20 { await Task.yield() }
        #expect(store.moonshot == .disabled, "Revoking consent clears usage immediately, without waiting for polling")
    }

    @Test("Cursor connection failures show specific recovery instructions")
    func actionableSetup() async throws {
        let suite = "UsagePresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UsageConsent.cursorKey)
        let message = UsageSessions.CursorSession.LoadError.keychainUnavailable.message
        let settings = UsageSettingsViewController(defaults: defaults, detector: { _ in .needsSetup(message) })
        settings.setPresentationActive(true)
        defer { settings.setPresentationActive(false) }
        let field = try #require(view("usage.status.cursor", in: settings.view) as? NSTextField)
        for _ in 0..<100 where field.stringValue != message { await Task.yield() }
        #expect(field.stringValue == message)
        #expect(field.maximumNumberOfLines == 0, "Recovery steps must not truncate")
        #expect(view("usage.check-again", in: settings.view) != nil)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func view(_ identifier: String, in root: NSView) -> NSView? {
        descendants(root).first { $0.identifier?.rawValue == identifier }
    }
}
