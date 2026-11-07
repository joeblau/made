import AppKit
import Testing
@testable import Pilot

@Suite("Native runner presentation", .serialized)
@MainActor
struct NativeRunnerPresentationTests {
    @Test("Isolated presentation never fetches on activation or source changes")
    func isolatedPresentationDoesNotFetch() async throws {
        let suite = "NativeRunnerPresentation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = NativeRunnerFetchProbe()
        let store = RunnersStore(defaults: defaults) { scope in await probe.fetch(scope) }
        store.add(RunnerScope(kind: .organization, name: "example"))
        let controller = RunnersViewController(store: store, defaults: defaults, isLive: false)
        controller.updatePresentation(isActive: true, isSelected: true)
        defer { controller.updatePresentation(isActive: false, isSelected: false) }
        store.add(RunnerScope(kind: .organization, name: "second"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.calls == 0)
        let buttons = buttons(in: controller.view)
        #expect(self.buttons(in: controller.pageToolbarView).first { $0.accessibilityLabel() == "Refresh" }?.isEnabled == false)
        #expect(buttons.first { $0.title == "Add Source" }?.isEnabled == false)
    }

    @Test("Constructing an offscreen runner view does not fetch GitHub")
    func offscreenViewDoesNotFetch() async throws {
        let suite = "NativeRunnerPresentation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("cards", forKey: "runners.layout")
        let probe = NativeRunnerFetchProbe()
        let store = RunnersStore(defaults: defaults) { scope in await probe.fetch(scope) }
        store.add(RunnerScope(kind: .organization, name: "example"))
        let controller = RunnersViewController(store: store, defaults: defaults)
        _ = controller.view
        await Task.yield()
        #expect(await probe.calls == 0)
    }

    @Test("Activation before view loading starts observation and hiding stops it")
    func activationOwnsObservation() async throws {
        let suite = "NativeRunnerPresentation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("cards", forKey: "runners.layout")
        let store = RunnersStore(defaults: defaults) { _ in [] }
        let controller = RunnersViewController(store: store, defaults: defaults)
        controller.updatePresentation(isActive: true, isSelected: true)
        defer { controller.updatePresentation(isActive: false, isSelected: false) }
        #expect(controller.isViewLoaded)
        store.add(RunnerScope(kind: .organization, name: "example"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(buttonTitles(in: controller.view).contains("example"))
        controller.updatePresentation(isActive: false, isSelected: false)
        store.add(RunnerScope(kind: .organization, name: "second"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!buttonTitles(in: controller.view).contains("second"))
    }

    private func buttonTitles(in view: NSView) -> [String] {
        buttons(in: view).map(\.title)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
}

private actor NativeRunnerFetchProbe {
    var calls = 0
    func fetch(_ scope: RunnerScope) -> [GitHubRunner] { calls += 1; return [] }
}

@Suite("Native remote desktop address entry")
struct RemoteDesktopAddressTests {
    @Test("Hostnames, explicit ports, and IPv6 retain their address")
    func addresses() {
        let examples: [(String, String, Int)] = [
            ("mini.local", "mini.local", 5900),
            ("mini.local:5901", "mini.local", 5901),
            ("100.64.0.12:5902", "100.64.0.12", 5902),
            ("2001:db8::1", "2001:db8::1", 5900),
            ("[2001:db8::1]:5903", "2001:db8::1", 5903),
        ]
        for (input, host, port) in examples {
            let result = RemoteDesktopAddress.parse(input)
            #expect(result.host == host)
            #expect(result.port == port)
        }
    }
}
