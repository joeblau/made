import AppKit
import Testing
@testable import Pilot

@MainActor
private final class FakeNewTabSource: NewTabContentSource {
    var activated: [NewTabPage] = []
    var activatedRoots: [String?] = []
    var contents: [NewTabPage: NewTabContent] = [:]
    func activate(_ page: NewTabPage, rootPath: String?) {
        activated.append(page)
        activatedRoots.append(rootPath)
    }
    func deactivate() {}
    func content(for page: NewTabPage) -> NewTabContent { contents[page] ?? NewTabContent(rows: []) }
}

@MainActor
@Suite("New-tab placeholder")
struct NewTabPlaceholderTests {
    private let context = NewTabContext(hasRoot: true, chromiumEnabled: true, chromiumUnavailableReason: nil)

    @Test("Fixed pages follow the published hierarchy with unique one-key shortcuts")
    func hierarchy() {
        let expected: [NewTabPage: [String]] = [
            .root: ["t", "b", "s", "d", "f", "e"],
            .terminal: ["a", "r"],
            .browser: ["s", "c"],
            .simulator: ["a", "g"],
            .device: ["a", "g"],
        ]
        for (page, keys) in expected {
            let rows = NewTabMenu.rows(for: page, context: context)
            #expect(rows.compactMap(\.shortcut) == keys, "\(page)")
            #expect(Set(keys).count == keys.count)
        }
        let root = NewTabMenu.rows(for: .root, context: context)
        #expect(root.first { $0.id == "files" }?.action == .revealInFinder)
        #expect(root.first { $0.id == "simulator" }?.action == .push(.simulator))
        #expect(NewTabMenu.rows(for: .simulator, context: context).map(\.action) == [.push(.simulators(.apple)), .push(.simulators(.google))])
        #expect(NewTabMenu.rows(for: .device, context: context).map(\.action) == [.push(.devices(.apple)), .push(.devices(.google))])
        #expect(NewTabMenu.rows(for: .browser, context: context).map(\.action) == [.push(.browserServers(.webKit)), .push(.browserServers(.chromium))])
    }

    @Test("Root-dependent and unavailable choices are shown disabled with a reason")
    func disabledChoices() {
        let limited = NewTabContext(hasRoot: false, chromiumEnabled: false, chromiumUnavailableReason: "Chromium is not installed")
        let root = NewTabMenu.rows(for: .root, context: limited)
        #expect(root.filter { !$0.isEnabled }.map(\.id) == ["files", "editor"])
        let chrome = NewTabMenu.rows(for: .browser, context: limited).first { $0.id == "chrome" }
        #expect(chrome?.isEnabled == false && chrome?.detail == "Chromium is not installed")
    }

    @Test("List items receive 1–9 in order, skipping headings and lettered actions")
    func numbering() {
        var rows = [NewTabRow(id: "h", title: "iOS 26", action: .header)]
        rows += (0..<11).map { NewTabRow(id: "\($0)", title: "Item \($0)", action: .open(.terminal)) }
        rows.append(NewTabRow(id: "refresh", title: "Refresh", shortcut: "r", action: .refresh))
        let numbered = NewTabMenu.numbered(rows)
        #expect(numbered[0].shortcut == nil)
        #expect(numbered[1...9].map(\.shortcut) == (1...9).map { String($0) })
        #expect(numbered[10].shortcut == nil && numbered[11].shortcut == nil)
        #expect(numbered.last?.shortcut == "r")
    }

    @Test("Typed paths push pages, Escape pops, and a live list opens by number")
    func keyboardPath() throws {
        let pane = Pane(kind: .terminal)
        pane.isChoosingMode = true
        defer { pane.isChoosingMode = false; NewTabProbes.release(paneID: pane.id, keeping: nil) }
        let source = FakeNewTabSource()
        let device = SimDevice(udid: "UDID", name: "iPhone 17", state: "Shutdown", deviceTypeIdentifier: nil,
                               runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0")
        source.contents[.simulators(.apple)] = NewTabContent(rows: NewTabMenu.numbered([
            NewTabRow(id: "group", title: "iOS 26.0", action: .header),
            NewTabRow(id: device.id, title: device.name, action: .open(.pane(.simulator, nil))),
        ]))
        let view = CockpitNewTabView(pane: pane, source: source)
        var changes = 0
        view.onChange = { changes += 1 }

        #expect(view.press("S"))
        #expect(view.currentPage == .simulator)
        #expect(view.press("a"))
        #expect(view.currentPage == .simulators(.apple))
        #expect(pane.openingPath == [.root, .simulator, .simulators(.apple)])
        #expect(source.activated.last == .simulators(.apple))
        #expect(!view.press("2"), "Only listed numbers respond")
        #expect(view.pop() && view.pop())
        #expect(!view.pop(), "Root is the bottom of the stack")
        #expect(view.currentPage == .root)

        for key in ["s", "a", "1"] { #expect(view.press(key)) }
        #expect(changes == 1)
        #expect(pane.kind == .simulator && !pane.isChoosingMode)
        #expect(!view.press("t"))
    }

    @Test("The tab title follows the chosen rows: New Tab, Terminal, Terminal / Agent")
    func tabTitleBreadcrumb() throws {
        let pane = Pane(kind: .terminal)
        pane.isChoosingMode = true
        defer { pane.isChoosingMode = false; NewTabProbes.release(paneID: pane.id, keeping: nil) }
        let view = CockpitNewTabView(pane: pane, source: FakeNewTabSource())
        var notified = 0
        let observer = NotificationCenter.default.addObserver(forName: .paneOpeningPathDidChange, object: nil, queue: nil) { note in
            if (note.object as? UUID) == pane.id { notified += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(pane.tabTitle == "New Tab")
        #expect(view.press("t"))
        #expect(pane.tabTitle == "Terminal")
        #expect(notified == 1, "Each step tells the tab to refresh")
        #expect(view.press("a"))
        #expect(pane.kind == .agentChat && !pane.isChoosingMode)
        #expect(pane.tabTitle == "Terminal / Agent")
    }

    @Test("Breadcrumbs use the titles of the rows that were chosen")
    func breadcrumbs() {
        #expect(NewTabPage.breadcrumb([.root]) == "New Tab")
        #expect(NewTabPage.breadcrumb([.root, .terminal]) == "Terminal")
        #expect(NewTabPage.breadcrumb([.root, .browser, .browserServers(.webKit)]) == "Browser / Safari")
        #expect(NewTabPage.breadcrumb([.root, .simulator, .simulators(.apple)]) == "Simulator / Apple")
        #expect(NewTabPage.breadcrumb([.root, .device, .devices(.google)]) == "Device / Google")
        let raw = Pane(kind: .terminal)
        #expect(raw.tabTitle == "Terminal", "A raw terminal keeps its own title")
    }

    @Test("Opening paths survive only while a pane is pending")
    func openingPathStorage() {
        let pane = Pane(kind: .terminal)
        pane.openingPath = [.terminal]
        #expect(PaneOpeningChoices.path(for: pane.id) == nil)
        pane.isChoosingMode = true
        #expect(pane.openingPath == [.root])
        pane.openingPath = [.terminal]
        #expect(pane.openingPath == [.root, .terminal], "Root stays at the bottom")
        pane.isChoosingMode = false
        #expect(PaneOpeningChoices.path(for: pane.id) == nil)
        #expect(!pane.applyOpeningChoice(.terminal), "Only a pending placeholder accepts a choice")
    }

    @Test("Choosing Safari keeps the placeholder open until a workspace site is selected")
    func browserSiteSelection() {
        let workspace = Workspace(name: "Current workspace")
        workspace.rootPath = "/projects/current-workspace"
        let pane = Pane(kind: .terminal)
        pane.workspace = workspace
        pane.isChoosingMode = true
        defer { pane.isChoosingMode = false }
        let source = FakeNewTabSource()
        let server = LocalServer(port: 3003, name: "pro")
        source.contents[.browserServers(.webKit)] = NewTabContent(rows: [
            NewTabRow(id: server.id, title: server.name, detail: server.displayURL, shortcut: "1",
                      serverIsLive: true, action: .open(.browser(.webKit, server.url))),
        ])
        let view = CockpitNewTabView(pane: pane, source: source)
        #expect(view.press("b") && view.press("s"))
        #expect(view.currentPage == .browserServers(.webKit))
        #expect(source.activatedRoots.last == workspace.effectiveRootPath)
        #expect(pane.isChoosingMode && pane.kind == .terminal && pane.browserState == nil)
        #expect(view.press("1"))
        #expect(pane.kind == .browser && !pane.isChoosingMode)
        #expect(pane.browserState?.engine == .webKit)
        #expect(pane.browserState?.urlText == "http://localhost:3003")
    }

    @Test("Both browser choices list only the current workspace, with stable 1–9 shortcuts and live ports")
    func workspaceSites() async throws {
        let source = NewTabLiveSource(paneID: UUID(), serverScanner: { root in
            root == "/first" ? (0..<12).map { LocalServer(port: 3000 + $0, name: "site-\($0)") }
                : [LocalServer(port: 8787, name: "second-workspace")]
        }, serverProbe: { $0 == 3000 })
        defer { source.deactivate() }
        source.activate(.browserServers(.webKit), rootPath: "/first")
        try await waitUntil { source.content(for: .browserServers(.webKit)).rows.first?.serverIsLive == true }
        for engine in BrowserEngine.allCases {
            let content = source.content(for: .browserServers(engine))
            let sites = content.rows.filter { $0.serverIsLive != nil }
            #expect(sites.count == 12)
            #expect(sites.prefix(9).compactMap(\.shortcut) == (1...9).map(String.init))
            #expect(sites.suffix(3).allSatisfy { $0.shortcut == nil })
            #expect(sites.first?.action == .open(.browser(engine, URL(string: "http://localhost:3000"))))
            #expect(sites[1].serverIsLive == false)
            #expect(content.rows.last?.shortcut == "0")
        }
        source.activate(.browserServers(.chromium), rootPath: "/second")
        #expect(source.content(for: .browserServers(.chromium)).rows.allSatisfy { $0.serverIsLive == nil })
        try await waitUntil { source.content(for: .browserServers(.chromium)).rows.first?.title == "second-workspace" }
        source.activate(.browserServers(.chromium), rootPath: nil)
        #expect(source.content(for: .browserServers(.chromium)).rows.allSatisfy { $0.serverIsLive == nil })
        #expect(source.content(for: .browserServers(.chromium)).message?.title.contains("workspace folder") == true)
    }

    @Test("A known workspace's sites appear at once from the shared catalog, without rescanning")
    func cachedWorkspaceSites() async throws {
        let counter = ScanCounter()
        let catalog = LocalServerCatalog(scanner: { root in
            await counter.increment()
            return [LocalServer(port: 3000, name: "app-\(root)")]
        })
        let first = NewTabLiveSource(paneID: UUID(), serverCatalog: catalog, serverProbe: { _ in false })
        first.activate(.browserServers(.webKit), rootPath: "/repo")
        #expect(first.content(for: .browserServers(.webKit)).message?.title == "Looking for dev servers…")
        try await waitUntil { first.content(for: .browserServers(.webKit)).rows.first?.title == "app-/repo" }
        first.deactivate()

        let second = NewTabLiveSource(paneID: UUID(), serverCatalog: catalog, serverProbe: { _ in false })
        defer { second.deactivate() }
        second.activate(.browserServers(.webKit), rootPath: "/repo")
        let content = second.content(for: .browserServers(.webKit))
        #expect(content.message?.isLoading != true, "No loading row for a workspace that was already scanned")
        #expect(content.rows.first?.title == "app-/repo")
        for _ in 0..<10 { await Task.yield() }
        #expect(await counter.count == 1, "A fresh cache is not rescanned")
    }

    @Test("The catalog refreshes stale entries and shares concurrent scans")
    func catalogFreshness() async throws {
        let counter = ScanCounter()
        var clock = ContinuousClock.now
        let catalog = LocalServerCatalog(scanner: { _ in
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return [LocalServer(port: 5173, name: "vite")]
        }, now: { clock })
        #expect(catalog.cached(rootPath: "/a") == nil && catalog.needsRefresh(rootPath: "/a"))
        async let one = catalog.refresh(rootPath: "/a")
        async let two = catalog.refresh(rootPath: "/a")
        _ = await (one, two)
        #expect(await counter.count == 1, "Concurrent requests share one scan")
        #expect(!catalog.needsRefresh(rootPath: "/a"))
        _ = await catalog.servers(rootPath: "/a")
        #expect(await counter.count == 1)
        clock = clock.advanced(by: LocalServerCatalog.refreshInterval)
        #expect(catalog.needsRefresh(rootPath: "/a"))
        _ = await catalog.servers(rootPath: "/a")
        #expect(await counter.count == 2, "A stale entry is rescanned")
    }

    @Test("Only an overflowing list gets a scroller, and rows stay clear of it")
    func scrollerOnlyWhenOverflowing() async throws {
        let pane = Pane(kind: .terminal)
        pane.isChoosingMode = true
        defer { pane.isChoosingMode = false; NewTabProbes.release(paneID: pane.id, keeping: nil) }
        let source = FakeNewTabSource()
        source.contents[.browserServers(.webKit)] = NewTabContent(rows: NewTabMenu.numbered((0..<30).map {
            NewTabRow(id: "server-\($0)", title: "server \($0)", action: .open(.terminal))
        }))
        let view = CockpitNewTabView(pane: pane, source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        func scrollViews() -> [NSScrollView] {
            func all(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(all) }
            return all(view).compactMap { $0 as? NSScrollView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        }
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
        #expect(scrollViews().allSatisfy { !$0.hasVerticalScroller }, "The short root list has no scroller")

        #expect(view.press("b") && view.press("s"))
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
        let list = try #require(scrollViews().first { $0.hasVerticalScroller }, "The long list scrolls")
        let scroller = try #require(list.verticalScroller)
        let scrollerLeft = list.convert(scroller.frame, from: scroller.superview).minX
        for row in list.documentView?.subviews ?? [] where row.frame.height > 0 {
            let right = list.convert(row.frame, from: row.superview).maxX
            #expect(right <= scrollerLeft + 0.5, "A row reaches \(right) under the scroller at \(scrollerLeft)")
            let left = list.convert(row.frame, from: row.superview).minX
            #expect(abs(left - (list.bounds.width - right)) < 0.5, "Rows sit centered with equal gutters")
        }
    }

    @Test("A late scan from the previous workspace cannot replace the current site's list")
    func staleWorkspaceScan() async throws {
        let scanner = ControlledNewTabScanner()
        let source = NewTabLiveSource(paneID: UUID(), serverScanner: { await scanner.scan($0) }, serverProbe: { _ in false })
        defer { source.deactivate() }
        source.activate(.browserServers(.webKit), rootPath: "/old")
        try await waitUntil { await scanner.hasRequest("/old") }
        source.activate(.browserServers(.webKit), rootPath: "/current")
        try await waitUntil { await scanner.hasRequest("/current") }
        await scanner.complete("/current", with: [LocalServer(port: 3001, name: "current")])
        try await waitUntil { source.content(for: .browserServers(.webKit)).rows.first?.title == "current" }
        await scanner.complete("/old", with: [LocalServer(port: 3000, name: "old")])
        for _ in 0..<10 { await Task.yield() }
        #expect(source.content(for: .browserServers(.webKit)).rows.first?.title == "current")
    }

    @Test("Long site lists scroll and keep each name, port badge, and shortcut on one line inside its card")
    func siteCardLayout() throws {
        let pane = Pane(kind: .terminal)
        pane.isChoosingMode = true
        pane.openingPath = [.root, .browser, .browserServers(.webKit)]
        defer { pane.isChoosingMode = false }
        let source = FakeNewTabSource()
        let names = ["app", "pro", "blog", "docs", "analytics", "deck", "www", "alert", "pitch", "leaderboard", "stats", "rpc-1337"]
        source.contents[.browserServers(.webKit)] = NewTabContent(rows: NewTabMenu.numbered(names.enumerated().map { index, name in
            NewTabRow(id: name, title: name, detail: "localhost:\(3000 + index)", serverIsLive: index < 2, port: 3000 + index,
                      action: .open(.browser(.webKit, URL(string: "http://localhost:\(3000 + index)"))))
        }), message: NewTabMessage(title: "Choose a server, or use its 1–9 shortcut."))
        let view = CockpitNewTabView(pane: pane, source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        for (appearance, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            let scroll = try #require(descendants(view).compactMap { $0 as? NSScrollView }.first)
            #expect((scroll.documentView?.frame.height ?? 0) > scroll.contentSize.height)
            let card = try #require(descendants(view).first { $0.accessibilityIdentifier() == "pane.opening-choice.app" })
            let labels = card.subviews.compactMap { $0 as? NSTextField }
            let title = try #require(labels.first { $0.stringValue == "app" })
            let port = try #require(card.subviews.compactMap { $0 as? ServerPortBadge }.first { !$0.isHidden })
            #expect(port.port == 3000)
            #expect(port.frame.minX >= title.frame.maxX, "The port badge follows the name")
            #expect(abs(port.frame.midY - title.frame.midY) < 1, "Name and port share one line")
            #expect(card.bounds.contains(title.frame) && card.bounds.contains(port.frame))
            #expect(labels.first { $0.stringValue == "localhost:3000" }?.isHidden ?? true, "No second address line")
            try capture(view, name: "sites-\(name)")
        }
        #expect(view.pop() && view.pop())
        for (appearance, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            try capture(view, name: "shortcuts-\(name)")
        }
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MADE_NEW_TAB_REVIEW_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let ready = await condition()
        #expect(ready, "Timed out waiting for the site list to update")
        if !ready { throw NewTabTestError.timeout }
    }
}

private enum NewTabTestError: Error { case timeout }

private actor ControlledNewTabScanner {
    private var requests: [String: CheckedContinuation<[LocalServer], Never>] = [:]
    func scan(_ root: String) async -> [LocalServer] {
        await withCheckedContinuation { requests[root] = $0 }
    }
    func hasRequest(_ root: String) -> Bool { requests[root] != nil }
    func complete(_ root: String, with servers: [LocalServer]) { requests.removeValue(forKey: root)?.resume(returning: servers) }
}

private actor ScanCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
