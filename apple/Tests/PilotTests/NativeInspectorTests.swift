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

    @Test("GitHub status parses the Actions component and its incident from the Statuspage summary")
    func githubStatusParsing() throws {
        let outage = try #require(GitHubActionsStatus.parse(Self.statusSummary(actions: "major_outage", incident: """
            {"id":"abc123","name":"Incident with Webhooks\\nand\\u2028Actions","shortlink":"https://stspg.io/abc",
             "components":[{"name":"Webhooks"},{"name":"Actions"}]}
            """)))
        #expect(outage.health == .majorOutage)
        #expect(outage.incident == "Incident with Webhooks and Actions")
        #expect(outage.link.absoluteString == "https://www.githubstatus.com/incidents/abc123",
                "links are rebuilt on githubstatus.com, never the feed's shared-tenant shortlink")

        let degraded = try #require(GitHubActionsStatus.parse(Self.statusSummary(actions: "degraded_performance", incident: """
            {"name":"Pages only","shortlink":"https://stspg.io/pages","components":[{"name":"Pages"}]}
            """)))
        #expect(degraded.health == .degraded)
        #expect(degraded.incident == nil)
        #expect(degraded.link == GitHubActionsStatus.pageURL)

        let untrusted = try #require(GitHubActionsStatus.parse(Self.statusSummary(actions: "partial_outage", incident: """
            {"id":"../../phish","name":"Spoofed","shortlink":"https://stspg.io/other-tenant","components":[{"name":"Actions"}]}
            """)))
        #expect(untrusted.health == .partialOutage)
        #expect(untrusted.link == GitHubActionsStatus.pageURL)

        let stacked = String(repeating: "a" + String(repeating: "\u{0301}", count: 50), count: 40)
        let marks = try #require(GitHubActionsStatus.parse(Self.statusSummary(actions: "major_outage", incident: """
            {"id":"m1","name":"\(stacked)","components":[{"name":"Actions"}]}
            """)))
        let name = try #require(marks.incident)
        #expect(name.unicodeScalars.count <= GitHubActionsStatus.maximumIncidentLength + 1,
                "the cap counts scalars, so combining marks can't inflate the tooltip")

        #expect(GitHubActionsStatus.parse(Self.statusSummary(actions: "operational"))?.health == .operational)
        #expect(GitHubActionsStatus.parse(Self.statusSummary(actions: "under_maintenance"))?.health == .maintenance)
        #expect(GitHubActionsStatus.parse(Self.statusSummary(actions: "on_fire")) == nil)
        #expect(GitHubActionsStatus.parse(Data(#"{"components":[{"name":"Pages","status":"major_outage"}]}"#.utf8)) == nil)
        #expect(GitHubActionsStatus.parse(Data("not json".utf8)) == nil)
        let padding = String(repeating: " ", count: GitHubActionsStatus.maximumBytes)
        #expect(GitHubActionsStatus.parse(Self.statusSummary(actions: "major_outage") + Data(padding.utf8)) == nil)
    }

    @Test("The Actions header shows GitHub's incident level only during an incident and only on the Actions tab")
    func githubStatusBadge() async throws {
        let suite = "NativeInspectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let feed = InspectorStatusFeed(Self.statusSummary(actions: "major_outage", incident: """
            {"id":"xyz","name":"Incident with Actions","components":[{"name":"Actions"}]}
            """))
        let statusStore = GitHubStatusStore(fetch: { try await feed.next() })
        let repository = RepositoryStore()
        repository.repoPath = "/fixture/repository"
        let workspace = Workspace(name: "Fixture")
        let controller = InspectorViewController(workspace: workspace, usageStore: UsageStore(defaults: defaults),
                                                 gitStore: repository, statusStore: statusStore,
                                                 defaults: defaults, isLive: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 380, height: 700)
        controller.setPresentationActive(true)
        defer { controller.setPresentationActive(false) }
        controller.selectTab(.actions)
        #expect(!statusStore.isPolling, "fixture inspectors never reach the network")
        let badge = try #require(view("inspector.github-status", in: controller.view) as? GitHubStatusBadge)
        #expect(badge.isHidden, "no badge before GitHub has answered")

        await statusStore.refresh()
        #expect(await eventually { !badge.isHidden })
        #expect(badge.attributedTitle.string == "GitHub · Major outage")
        #expect(badge.toolTip?.contains("Incident with Actions") == true)
        var opened: URL?
        badge.onOpen = { opened = $0 }
        badge.performClick(nil)
        #expect(opened?.absoluteString == "https://www.githubstatus.com/incidents/xyz")
        controller.view.layoutSubtreeIfNeeded()
        let refresh = try #require(descendants(controller.view).first { $0 is CockpitRefreshButton && !$0.isHiddenOrHasHiddenAncestor })
        #expect(badge.convert(badge.bounds, to: nil).maxX <= refresh.convert(refresh.bounds, to: nil).minX,
                "the badge sits before the refresh button")

        controller.selectTab(.pullRequests)
        #expect(badge.isHidden, "GitHub status belongs to the Actions tab")
        controller.selectTab(.actions)
        #expect(!badge.isHidden)

        await feed.set(Self.statusSummary(actions: "operational"))
        await statusStore.refresh()
        #expect(await eventually { badge.isHidden }, "operational hides the badge")

        await feed.set(Self.statusSummary(actions: "partial_outage"))
        await statusStore.refresh()
        #expect(await eventually { !badge.isHidden })
        await feed.fail()
        await statusStore.refresh()
        #expect(statusStore.status == nil)
        #expect(await eventually { badge.isHidden }, "a failed fetch hides a possibly stale incident")

        // One app-wide store serves every window: polling runs while any inspector shows Actions.
        let first = NSObject(), second = NSObject()
        statusStore.setPolling(true, for: first)
        statusStore.setPolling(true, for: second)
        statusStore.setPolling(false, for: first)
        #expect(statusStore.isPolling, "another window still shows the Actions tab")
        statusStore.setPolling(false, for: second)
        #expect(!statusStore.isPolling)
    }

    private static func statusSummary(actions: String, incident: String? = nil) -> Data {
        Data("""
            {"status":{"indicator":"major"},
             "components":[{"name":"Webhooks","status":"degraded_performance"},{"name":"Actions","status":"\(actions)"}],
             "incidents":[\(incident ?? "")]}
            """.utf8)
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

private actor InspectorStatusFeed {
    private var payload: Data?
    init(_ payload: Data) { self.payload = payload }
    func set(_ payload: Data) { self.payload = payload }
    func fail() { payload = nil }
    func next() throws -> Data {
        guard let payload else { throw URLError(.notConnectedToInternet) }
        return payload
    }
}
