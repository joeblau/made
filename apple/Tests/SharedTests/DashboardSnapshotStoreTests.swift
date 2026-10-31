import Foundation
import Testing
@testable import Copilot

@Suite("Dashboard snapshot store", .serialized)
struct DashboardSnapshotStoreTests {
    @Test("Separate family files round-trip without overwriting each other")
    func roundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashboardSnapshotStore(directory: directory)
        let actions = ActionsDashboardSnapshot(updatedAt: 100, runs: [])
        let usage = UsageDashboardSnapshot(updatedAt: 200, estimatedCost: 3.5, totalTokens: 500, providers: [])
        let runners = RunnersDashboardSnapshot(
            enterpriseID: "enterprise",
            enterpriseName: "Enterprise",
            totalCount: 4,
            idleCount: 2,
            busyCount: 1,
            offlineCount: 1,
            runners: [],
            updatedAt: 300
        )

        #expect(store.read(ActionsDashboardSnapshot.self, for: .actions) == nil)
        try store.write(actions, for: .actions)
        try store.write(usage, for: .usage)
        try store.write(runners, for: .runners)

        #expect(store.read(ActionsDashboardSnapshot.self, for: .actions) == actions)
        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == usage)
        #expect(store.read(RunnersDashboardSnapshot.self, for: .runners) == runners)
        for family in DashboardFamily.allCases {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dashboard-\(family.rawValue).json").path))
        }
    }

    @Test("Missing and corrupt files read as empty")
    func corruptAndMissingReads() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DashboardSnapshotStore(directory: directory)

        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == nil)
        try Data("not valid json".utf8).write(to: directory.appendingPathComponent("dashboard-usage.json"))
        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == nil)
        #expect(store.read(ActionsDashboardSnapshot.self, for: .actions) == nil)
    }

    @Test("Oversized files are rejected before decoding")
    func oversizedRead() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DashboardSnapshotStore(directory: directory)
        let url = directory.appendingPathComponent("dashboard-usage.json")
        try Data(repeating: 0x20, count: DashboardSnapshotStore.maxSnapshotBytes + 1).write(to: url)

        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == nil)
    }

    @Test("Clear removes one family and clearAll is safe for missing files")
    func clear() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashboardSnapshotStore(directory: directory)
        let actions = ActionsDashboardSnapshot(updatedAt: 100, runs: [])
        let usage = UsageDashboardSnapshot(updatedAt: 200, estimatedCost: 0, totalTokens: 0, providers: [])
        try store.write(actions, for: .actions)
        try store.write(usage, for: .usage)

        try store.clear(.actions)
        #expect(store.read(ActionsDashboardSnapshot.self, for: .actions) == nil)
        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == usage)
        try store.clear(.actions)
        try store.clearAll()
        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == nil)
        try store.clearAll()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardSnapshotStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
