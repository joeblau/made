import AppKit
import Testing
@testable import Pilot

private actor NativeDockerTestEngine: DockerEngineAPI {
    private(set) var actions: [DockerContainerAction] = []
    nonisolated static let items = [
        DockerContainerSummary(id: "alpha", name: "alpha", image: "node:22", command: "node app", createdAt: .distantPast,
                               state: .running, status: "Up", ports: [], labels: ["com.docker.compose.project": "demo"]),
        DockerContainerSummary(id: "beta", name: "beta", image: "redis:7", command: "redis", createdAt: .distantPast,
                               state: .exited, status: "Exited", ports: [], labels: [:])
    ]
    func version() async throws -> DockerEngineVersion { .init(version: "29", apiVersion: "1.43", os: "linux") }
    func containers() async throws -> [DockerContainerSummary] { Self.items }
    func perform(_ action: DockerContainerAction, containerID: String) async throws { actions.append(action) }
    nonisolated func containerEvents() -> AsyncThrowingStream<DockerEngineEvent, any Error> { AsyncThrowingStream { $0.finish() } }
}

@MainActor
@Suite("Native Docker presentation", .serialized)
struct DockerNativePresentationTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("Isolated presentation never discovers or starts a container engine")
    func isolatedPresentationHasNoLiveEffects() async throws {
        _ = NSApplication.shared
        let suite = "native-docker-isolated-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var lookups = 0
        let store = DockerStore(defaults: defaults, resolveSocketPath: { lookups += 1; return nil })
        let controller = DockerViewController(store: store, isLive: false)
        controller.loadView()
        controller.updatePresentation(isActive: true, isSelected: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(lookups == 0)
        let refresh = try #require(descendants(controller.pageToolbarView).compactMap { $0 as? NSButton }.first { $0.toolTip == "Refresh containers" })
        #expect(!refresh.isEnabled)
        // The refresh circle owns its spinner slot and sits directly in the
        // toolbar rather than inside another glass capsule.
        let slot = try #require(refresh.superview as? CockpitRefreshButton)
        #expect(slot.superview === controller.pageToolbarView)
        #expect(slot.isRefreshing == (store.isRefreshing || store.engine == .checking))
        #expect(!descendants(controller.view).contains { $0 is NSProgressIndicator && $0.superview === controller.view })
        controller.updatePresentation(isActive: false, isSelected: false)
        #expect(lookups == 0)
    }

    @Test("View construction is inert; native filtering and selection follow the injected store")
    func nativeFiltersAndLifecycle() async throws {
        _ = NSApplication.shared
        let suite = "native-docker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = NativeDockerTestEngine()
        var lookups = 0
        let store = DockerStore(defaults: defaults, resolveSocketPath: { lookups += 1; return "/fixture/docker.sock" }, makeClient: { _ in engine })
        let controller = DockerViewController(store: store)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.viewDidLayout()
        #expect(lookups == 0)
        controller.updatePresentation(isActive: true, isSelected: true)
        defer { controller.updatePresentation(isActive: false, isSelected: false) }
        #expect(await eventually { store.containers.count == 2 })
        let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        #expect(await eventually { table.numberOfRows == 4 })
        let search = try #require(descendants(controller.pageToolbarView).compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "alpha"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(await eventually { table.numberOfRows == 2 })
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(store.selectedContainerID == "alpha")
        search.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        let stopped = try #require(descendants(controller.pageToolbarView).compactMap { $0 as? NSSwitch }.first { $0.accessibilityLabel() == "Show stopped" })
        stopped.performClick(nil)
        #expect(await eventually { table.numberOfRows == 2 && !store.showsStopped })
        #expect(lookups == 1)
    }

    @Test("Native lifecycle buttons dispatch once and removal stays pending until confirmed")
    func nativeActionsAndRemoval() async throws {
        _ = NSApplication.shared
        let suite = "native-docker-actions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = NativeDockerTestEngine()
        let store = DockerStore(defaults: defaults, resolveSocketPath: { "/fixture/docker.sock" }, makeClient: { _ in engine })
        let controller = DockerViewController(store: store)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.viewDidLayout()
        controller.updatePresentation(isActive: true, isSelected: true)
        defer { controller.updatePresentation(isActive: false, isSelected: false) }
        #expect(await eventually { store.containers.count == 2 })
        controller.refreshPresentation()
        let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        let row = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let restart = try #require(descendants(row).compactMap { $0 as? NSButton }.first { $0.title == DockerContainerAction.restart.label })
        restart.performClick(nil)
        #expect(await eventually { store.busyContainerIDs.isEmpty })
        #expect(await engine.actions == [.restart])
        let remove = try #require(descendants(row).compactMap { $0 as? NSButton }.first { $0.title == DockerContainerAction.remove.label })
        remove.performClick(nil)
        #expect(store.containerPendingRemoval?.id == "alpha")
        #expect(await engine.actions == [.restart])
        controller.updatePresentation(isActive: false, isSelected: false)
        #expect(store.containerPendingRemoval == nil)
    }
}
