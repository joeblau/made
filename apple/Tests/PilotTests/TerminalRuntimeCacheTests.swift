import Foundation
import Testing
@testable import Pilot

@Suite("Nonblocking terminal runtime snapshots")
struct TerminalRuntimeCacheTests {
    private actor Loader {
        var requests: [CheckedContinuation<Int?, Never>] = []
        var count: Int { requests.count }
        func load() async -> Int? {
            await withCheckedContinuation { requests.append($0) }
        }
        func finish(_ index: Int, value: Int?) { requests[index].resume(returning: value) }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0
        func now() -> TimeInterval { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    @Test @MainActor
    func stalledRefreshNeverBlocksMainActorAndCoalescesReads() async {
        let loader = Loader()
        let cache = TerminalRuntimeCache<Int> { _ in await loader.load() }
        let started = ContinuousClock.now
        for _ in 0..<1000 { #expect(cache.snapshot(for: "pane") == nil) }
        #expect(started.duration(to: .now) < .seconds(1))
        await wait { await loader.count == 1 }
        #expect(await loader.count == 1)
        await loader.finish(0, value: 42)
        await wait { cache.snapshot(for: "pane") == 42 }
        #expect(cache.snapshot(for: "pane") == 42)
    }

    @Test
    func staleRuntimeExpiresAndFailedRefreshClearsIt() async {
        let loader = Loader()
        let clock = Clock()
        let cache = TerminalRuntimeCache<Int>(clock: clock.now) { _ in await loader.load() }
        _ = cache.snapshot(for: "pane")
        await wait { await loader.count == 1 }
        await loader.finish(0, value: 42)
        await wait { cache.snapshot(for: "pane") == 42 }
        clock.advance(2)
        #expect(cache.snapshot(for: "pane") == 42)
        await wait { await loader.count == 2 }
        clock.advance(2)
        #expect(cache.snapshot(for: "pane") == nil, "Expired PIDs must not be reused while tmux is unresponsive")
        await loader.finish(1, value: nil)
    }

    @Test
    func invalidationRejectsLateReplyFromRemovedSession() async {
        let loader = Loader()
        let cache = TerminalRuntimeCache<Int> { _ in await loader.load() }
        _ = cache.snapshot(for: "pane")
        await wait { await loader.count == 1 }
        cache.invalidate("pane")
        _ = cache.snapshot(for: "pane")
        await wait { await loader.count == 2 }
        await loader.finish(1, value: 99)
        await wait { cache.snapshot(for: "pane") == 99 }
        await loader.finish(0, value: 42)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(cache.snapshot(for: "pane") == 99)
    }

    @Test @MainActor
    func tmuxLookupHasDeadlineAndLeavesMainActorAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("stalled-tmux")
        try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 1; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = ContinuousClock.now
        let lookup = Task { await PersistentTerminalSession.loadPaneRuntime(sessionName: "test", executable: executable) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(started.duration(to: .now) < .milliseconds(500), "Main actor must remain available during tmux lookup")
        #expect(await lookup.value == nil)
        #expect(started.duration(to: .now) < .seconds(2))
    }

    private func wait(until condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}
