import AppKit
import Testing
@testable import Pilot

@Suite("Native inspector", .serialized)
@MainActor
struct NativeInspectorTests {
    @Test("Fixture tab switching preserves data and sends issue implementation to the active terminal")
    func fixtureTabsAndIssueAction() throws {
        let suite = "NativeInspectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let issue = try JSONDecoder().decode(GitHubTask.self, from: Data("""
            {"number":365,"title":"Migrate the inspector","url":"https://github.com/example/issues/365","state":"OPEN"}
            """.utf8))
        let tasks = GitHubTasksStore(tasks: [issue])
        let repository = RepositoryStore()
        repository.repoPath = "/fixture/repository"
        repository.pullRequests = [.init(id: 1, title: "Native inspector", url: "https://github.com/example/pull/1",
                                        state: "OPEN", isDraft: false, author: "developer", headBranch: "appkit", elapsed: "1m")]
        let workspace = Workspace(name: "Fixture")
        let controller = InspectorViewController(workspace: workspace, usageStore: UsageStore(defaults: defaults),
                                                 gitStore: repository, tasksStore: tasks, defaults: defaults, isLive: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 380, height: 700)
        controller.setPresentationActive(true)
        defer { controller.setPresentationActive(false) }
        for tab in InspectorTab.allCases {
            controller.selectTab(tab)
            #expect(workspace.inspectorTab == tab)
            controller.view.layoutSubtreeIfNeeded()
        }
        controller.selectTab(.tasks)
        let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == 1)
        let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let parent = try #require(table.superview)
        controller.selectTab(.usage)
        #expect(table.isHiddenOrHasHiddenAncestor)
        #expect(table.superview === parent)
        controller.selectTab(.tasks)
        #expect(!table.isHiddenOrHasHiddenAncestor)
        #expect(table.superview === parent)
        #expect(table.view(atColumn: 0, row: 0, makeIfNecessary: true) === row)
        let implement = try #require(descendants(row).compactMap { $0 as? NSButton }.first { $0.title == "#365" })
        var prompt: String?
        controller.onSendIssuePrompt = { prompt = $0 }
        implement.performClick(nil)
        #expect(prompt?.contains("gh issue view 365") == true)
        #expect(prompt?.contains("fixes #365") == true)
        controller.setPresentationActive(false)
        #expect(tasks.tasks == [issue])
        #expect(repository.pullRequests.count == 1)
        #expect(repository.repoPath == "/fixture/repository")
    }

    @Test("Settings only inspect opted-in accounts and ignore a result after consent is revoked")
    func consentAndStaleDetection() async throws {
        let suite = "NativeInspectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UsageConsent.claudeKey)
        let detector = InspectorSessionProbe()
        let controller = UsageSettingsViewController(defaults: defaults, detector: { await detector.detect($0) })
        let checkbox = try #require(view("usage.consent.claude", in: controller.view) as? NSSwitch)
        let status = try #require(view("usage.status.claude", in: controller.view) as? NSTextField)
        controller.setPresentationActive(true)
        defer { controller.setPresentationActive(false) }
        #expect(await eventually { await detector.requested == [.claude] })
        #expect(status.stringValue == "Checking sign-in…")
        checkbox.performClick(nil)
        #expect(!defaults.bool(forKey: UsageConsent.claudeKey))
        #expect(status.stringValue == "Disabled")
        await detector.finish()
        await drainMainActor()
        #expect(status.stringValue == "Disabled")
        #expect(await detector.requested == [.claude])
    }

    @Test("Dismissed settings discard pending detection and release the controller")
    func dismissalCancelsPresentation() async throws {
        let suite = "NativeInspectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UsageConsent.codexKey)
        let detector = InspectorSessionProbe()
        var controller: UsageSettingsViewController? = UsageSettingsViewController(
            defaults: defaults, detector: { await detector.detect($0) })
        weak var releasedController = controller
        let status = try #require(view("usage.status.codex", in: controller!.view) as? NSTextField)
        controller?.setPresentationActive(true)
        #expect(await eventually { await detector.requested == [.codex] })
        controller?.setPresentationActive(false)
        controller = nil
        await detector.finish()
        await drainMainActor()
        #expect(releasedController == nil)
        #expect(status.stringValue == "Checking sign-in…")
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
    private func view(_ identifier: String, in root: NSView) -> NSView? {
        descendants(root).first { $0.identifier?.rawValue == identifier }
    }
    private func eventually(_ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    private func drainMainActor() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private actor InspectorSessionProbe {
    private(set) var requested: [UsageAccount] = []
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private var finished = false
    func detect(_ account: UsageAccount) async -> Bool {
        requested.append(account)
        if finished { return true }
        return await withCheckedContinuation { continuations.append($0) }
    }
    func finish() {
        finished = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: true) }
    }
}
