import Foundation
import Testing
@testable import Pilot

@Suite("Git dirty-state cache")
struct GitStatusCacheTests {

    @Test("A fresh entry serves repeat callers without a second probe")
    func cacheHitWithinTTL() async {
        let probe = DirtyProbe(value: true)
        let clock = TestDateClock()
        let cache = GitDirtyStateCache(timeToLive: 4, now: { clock.now }, probe: {
            await probe.execute($0)
        })

        #expect(await cache.isDirty(directory: "/tmp/repo") == true)
        clock.advance(by: 3)
        #expect(await cache.isDirty(directory: "/tmp/repo") == true)
        #expect(await probe.callCount == 1)
    }

    @Test("An expired entry re-probes")
    func ttlExpiry() async {
        let probe = DirtyProbe(value: false)
        let clock = TestDateClock()
        let cache = GitDirtyStateCache(timeToLive: 4, now: { clock.now }, probe: {
            await probe.execute($0)
        })

        #expect(await cache.isDirty(directory: "/tmp/repo") == false)
        clock.advance(by: 5)
        #expect(await cache.isDirty(directory: "/tmp/repo") == false)
        #expect(await probe.callCount == 2)
    }

    @Test("Directory spellings standardize onto one entry")
    func keyStandardization() async {
        let probe = DirtyProbe(value: true)
        let cache = GitDirtyStateCache(timeToLive: 60, probe: { await probe.execute($0) })

        _ = await cache.isDirty(directory: "/tmp/repo")
        _ = await cache.isDirty(directory: "/tmp/repo/")
        _ = await cache.isDirty(directory: "/tmp/sub/../repo")
        #expect(await probe.callCount == 1)
    }

    @Test("A nil result (not a repo) is cached too")
    func nilResultsAreCached() async {
        let probe = DirtyProbe(value: nil)
        let cache = GitDirtyStateCache(timeToLive: 60, probe: { await probe.execute($0) })

        #expect(await cache.isDirty(directory: "/tmp/not-a-repo") == nil)
        #expect(await cache.isDirty(directory: "/tmp/not-a-repo") == nil)
        #expect(await probe.callCount == 1)
    }

    @Test("Blank directories never reach the probe")
    func blankDirectory() async {
        let probe = DirtyProbe(value: true)
        let cache = GitDirtyStateCache(timeToLive: 60, probe: { await probe.execute($0) })

        #expect(await cache.isDirty(directory: "   ") == nil)
        #expect(await probe.callCount == 0)
    }

    @Test("Overlapping callers for one directory share a single probe")
    func inFlightCoalescing() async {
        let probe = DirtyProbe(value: true)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let cache = GitDirtyStateCache(timeToLive: 60, probe: { directory in
            startedContinuation.yield()
            var gate = release.makeAsyncIterator()
            _ = await gate.next()
            return await probe.execute(directory)
        })

        let first = Task { await cache.isDirty(directory: "/tmp/repo") }
        var startedGate = started.makeAsyncIterator()
        _ = await startedGate.next()
        // The probe is now suspended, so this call must join it, not fork.
        let second = Task { await cache.isDirty(directory: "/tmp/repo") }
        releaseContinuation.yield()
        // A regressed cache would fork a second probe; finishing the gates
        // makes that fail the call-count check instead of hanging the test.
        releaseContinuation.finish()
        startedContinuation.finish()

        #expect(await first.value == true)
        #expect(await second.value == true)
        #expect(await probe.callCount == 1)
    }
}

@Suite("Work-tree root discovery")
struct WorkTreeRootTests {

    @Test("Finds the nearest ancestor holding a .git directory")
    func gitDirectoryMarksRoot() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("repo", isDirectory: true)
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let expected = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
        #expect(GitStatus.findWorkTreeRoot(from: nested.path) == expected)
        #expect(GitStatus.findWorkTreeRoot(from: root.path) == expected)
    }

    @Test("A .git pointer file counts: linked worktrees and submodules")
    func gitFileMarksRoot() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let worktree = base.appendingPathComponent("worktree", isDirectory: true)
        let nested = worktree.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("gitdir: /tmp/elsewhere/.git/worktrees/worktree\n".utf8)
            .write(to: worktree.appendingPathComponent(".git"))

        let expected = URL(fileURLWithPath: worktree.path, isDirectory: true).standardizedFileURL.path
        #expect(GitStatus.findWorkTreeRoot(from: nested.path) == expected)
    }

    @Test("Directories outside any repository resolve to nil")
    func nonRepoResolvesToNil() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(GitStatus.findWorkTreeRoot(from: base.path) == nil)
        #expect(GitStatus.findWorkTreeRoot(from: "") == nil)
        #expect(GitStatus.findWorkTreeRoot(from: "   ") == nil)
    }

    @Test("Local-volume paths read as local without touching the disk")
    func localVolumeDetection() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(GitStatus.isOnLocalVolume(path: base.path))
        // The check consults the mount table, not the path, so it must hold
        // for paths that don't exist — a stat there is exactly the blocking
        // call the check exists to avoid on dead network mounts.
        let missing = base.appendingPathComponent("missing/child", isDirectory: true)
        #expect(GitStatus.isOnLocalVolume(path: missing.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-worktree-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor DirtyProbe {
    private let value: Bool?
    private(set) var callCount = 0

    init(value: Bool?) {
        self.value = value
    }

    func execute(_ directory: String) -> Bool? {
        _ = directory
        callCount += 1
        return value
    }
}

private final class TestDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value.addTimeInterval(interval)
        lock.unlock()
    }
}
