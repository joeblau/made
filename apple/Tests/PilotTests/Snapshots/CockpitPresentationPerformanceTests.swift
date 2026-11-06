import AppKit
import Darwin
import XCTest
@testable import Pilot

/// Opt-in measurements of isolated production panels in the capture harness.
/// These are not whole-application launch, input latency, or GPU measurements.
final class CockpitPresentationPerformanceTests: XCTestCase {
    @MainActor
    func testInteractionWorkloads() async throws {
        guard let destination = ProcessInfo.processInfo.environment["MADE_INTERACTION_OUTPUT"] else {
            throw XCTSkip("Set MADE_INTERACTION_OUTPUT for isolated interaction measurements")
        }
        let fixtures = try SnapshotFixtures()
        defer { fixtures.close() }
        try await fixtures.prepare()
        fixtures.defaults.set("compact", forKey: "runners.layout")
        let cache = CockpitPaneControllerCache()
        defer { cache.closeAll() }
        let workspace = try XCTUnwrap(fixtures.workspace.workspaces.first)
        let shell = CockpitWindowController(
            store: fixtures.workspace, extensionController: ExtensionWorkspaceController(modelContext: fixtures.container.mainContext),
            surface: .main, defaults: fixtures.defaults, isLive: false, paneCache: cache,
            paneFactory: { _, _ in
                let controller = NSViewController()
                controller.view = NSView()
                return controller
            }, globalFactory: { mode in
                switch mode {
                case .notes: return NotesViewController(store: fixtures.workspace, defaults: fixtures.defaults)
                case .docker: return DockerViewController(store: fixtures.docker)
                case .runners: return RunnersViewController(store: fixtures.runners, defaults: fixtures.defaults, isLive: false)
                case .agenticUse:
                    let controller = NSViewController()
                    controller.view = SnapshotDashboardScrollView(dashboard: AgenticUseDashboard(
                        snapshot: fixtures.history, pricingStatus: "Fixture pricing"))
                    return controller
                default: return nil
                }
            })
        var inspector: InspectorViewController?
        shell.inspectorFactory = { workspace in
            let controller = InspectorViewController(
                workspace: workspace, usageStore: fixtures.usage, gitStore: fixtures.repository,
                tasksStore: fixtures.tasks, defaults: fixtures.defaults, isLive: false)
            inspector = controller
            return controller
        }
        let window = try XCTUnwrap(shell.window)
        shell.showWindow(nil)
        XCTAssertGreaterThan(try XCTUnwrap(window.contentView).bounds.width, 500)
        XCTAssertGreaterThan(try XCTUnwrap(window.contentView).bounds.height, 300)
        defer { window.orderOut(nil); shell.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        if let ready = ProcessInfo.processInfo.environment["MADE_INTERACTION_PROFILE_READY"] {
            try String(ProcessInfo.processInfo.processIdentifier).write(toFile: ready, atomically: true, encoding: .utf8)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !FileManager.default.fileExists(atPath: ready + ".start"), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready + ".start"), "Profiler did not attach")
        }
        let samples = InteractionSamples()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                let phase = samples.phase
                let start = ProcessInfo.processInfo.systemUptime
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
                if phase == samples.phase {
                    samples.delays[phase, default: []].append(max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000 - 8))
                }
            }
        }
        defer { heartbeat.cancel() }
        let modes: [(String, SidebarSelection)] = [
            ("notes", .notes), ("docker", .docker), ("agentic-use", .agenticUse), ("runners", .runners),
            ("workspace", .workspace(workspace.id)),
        ]
        for cycle in 0..<5 {
            samples.phase = "global-modes"
            for (name, mode) in modes {
                let start = ProcessInfo.processInfo.systemUptime
                shell.select(mode)
                window.contentView?.layoutSubtreeIfNeeded()
                if cycle > 0 { samples.actions["select-" + name, default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                try await Task.sleep(for: .milliseconds(200))
            }
            samples.phase = "inspector"
            for visible in [true, false] {
                shell.toggleInspector()
                if visible {
                    let controller = try XCTUnwrap(inspector)
                    for tab in InspectorTab.allCases {
                        let start = ProcessInfo.processInfo.systemUptime
                        controller.selectTab(tab)
                        window.contentView?.layoutSubtreeIfNeeded()
                        if cycle > 0 { samples.actions["inspector-tab", default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        try await measureStream(fixtures: fixtures, samples: samples)
        heartbeat.cancel()
        let report = InteractionReport(
            configuration: "Optimized hosted XCTest; visible production windows; in-memory stores and scripted ACP",
            exclusions: ["GPU/event-to-display latency", "real provider response time", "live terminal/browser/video", "energy"],
            actionMilliseconds: samples.actions, mainActorDelayBeyond8ms: samples.delays)
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    @MainActor
    private func measureStream(fixtures: SnapshotFixtures, samples: InteractionSamples) async throws {
        let launch = ACPConnection.LaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"""
            read -r _
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
            read -r _
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"fixture"}}'
            read -r _
            index=0
            while [ "$index" -lt 500 ]; do
                printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Review this fictional component and explain the changes."}}}}'
                printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"The component preserves its state, uses native controls, and updates only changed rows. This fixture checks a long conversation without contacting any provider."}}}}'
                index=$((index + 1))
            done
            printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
            read -r _
            index=0
            while [ "$index" -lt 120 ]; do
                printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"A streamed paragraph in a long conversation. The latest message grows while earlier rows retain their text, selection and measured layout. The user can keep reading without jumping to the bottom.\n\n"}}}}'
                index=$((index + 1))
                sleep 0.01
            done
            printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
            read -r _
            """#], environment: [:], currentDirectory: FileManager.default.temporaryDirectory)
        let pane = Pane(kind: .agentChat)
        let session = AgentChatSession(paneID: pane.id, agent: .claude, workingDirectory: NSTemporaryDirectory(),
                                       defaults: fixtures.defaults, resolveLaunch: { _, _ in .success(launch) })
        let controller = AgentChatPaneViewController(pane: pane, session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // NSWindow adopts the controller's initial view size on attachment.
        // Give the fixture real geometry before measuring visible streaming.
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 700))
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        defer { controller.closePane(); session.shutDown(); window.close() }
        controller.updatePresentation(isActive: true, isSelected: true)
        try await waitForReady(session)
        for phase in ["history-1000", "stream-120-chunks"] {
            samples.phase = phase
            let start = ProcessInfo.processInfo.systemUptime
            session.draft = "Run fixture"
            session.send()
            try await waitForReady(session)
            // Finish the coalesced display update, outside the recorded workload.
            samples.actions[phase] = [(ProcessInfo.processInfo.systemUptime - start) * 1000]
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertGreaterThanOrEqual(session.transcript.items.count, 1000)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
            XCTAssertGreaterThan(table.visibleRect.width, 600)
            XCTAssertGreaterThan(table.visibleRect.height, 400)
            if phase == "stream-120-chunks" {
                func texts(in view: NSView) -> [NSTextView] {
                    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { texts(in: $0) }
                }
                let streamed = try XCTUnwrap(texts(in: controller.view).first {
                    $0.string.contains("A streamed paragraph")
                })
                XCTAssertEqual(streamed.string.components(separatedBy: "A streamed paragraph").count - 1, 120,
                               "The visible transcript must include every delivered chunk")
            }
        }
        samples.phase = "history-hidden"
        controller.updatePresentation(isActive: false, isSelected: false)
        try await Task.sleep(for: .milliseconds(500))
    }

    @MainActor
    private func waitForReady(_ session: AgentChatSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while session.phase != .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.phase, .ready)
    }

    @MainActor
    func testPresentationWorkloads() async throws {
        guard let destination = ProcessInfo.processInfo.environment["MADE_PERFORMANCE_OUTPUT"] else {
            throw XCTSkip("Set MADE_PERFORMANCE_OUTPUT through the benchmark runner")
        }
        let fixtures = try SnapshotFixtures()
        defer { fixtures.close() }
        try await fixtures.prepare()
        let scenes: [SnapshotScene] = [.notes, .docker, .runners, .agenticUse, .tasks, .actions, .pullRequests, .usage]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 960),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        var samples: [PresentationSample] = []
        for scene in scenes {
            // One unrecorded warm-up and seven recorded mounts. Package loading,
            // fixture setup, and the intentional settling delay are excluded.
            for iteration in 0..<8 {
                let begin = ProcessInfo.processInfo.systemUptime
                let controller = SnapshotWorkbench(scene: scene, fixtures: fixtures)
                let view = controller.view
                window.contentView = view
                view.frame = NSRect(x: 0, y: 0, width: 1440, height: 960)
                view.layoutSubtreeIfNeeded()
                let mount = (ProcessInfo.processInfo.systemUptime - begin) * 1000
                try await Task.sleep(for: .milliseconds(180))
                view.layoutSubtreeIfNeeded()
                var resize: [Double] = []
                for step in 0..<20 {
                    let width = step.isMultiple(of: 2) ? 1280 : 1600
                    let start = ProcessInfo.processInfo.systemUptime
                    window.setContentSize(NSSize(width: width, height: 960))
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 960)
                    view.layoutSubtreeIfNeeded()
                    resize.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                if iteration > 0 {
                    samples.append(PresentationSample(scene: scene.rawValue, iteration: iteration,
                                                      mountLayoutMilliseconds: mount,
                                                      resizeLayoutMilliseconds: resize,
                                                      residentBytes: residentBytes()))
                }
                window.contentView = nil
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let report = PresentationReport(
            version: 1, implementation: ProcessInfo.processInfo.environment["MADE_PERFORMANCE_IMPLEMENTATION"] ?? "appkit",
            sourceRevision: ProcessInfo.processInfo.environment["MADE_PERFORMANCE_REVISION"] ?? "unknown",
            configuration: "Debug with -O wholemodule; hosted XCTest, services disabled",
            workload: "offscreen native production panels inside fictional snapshot shell; one warmup, seven mounts, twenty width changes per mount",
            exclusions: ["application launch", "interactive input", "frame rendering/GPU", "live terminal/browser/video", "large-history scaling", "energy", "cross-process Chromium memory"],
            samples: samples
        )
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        XCTAssertEqual(samples.count, scenes.count * 7)
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

@MainActor
private final class InteractionSamples {
    var phase = "warmup"
    var actions: [String: [Double]] = [:]
    var delays: [String: [Double]] = [:]
}

private struct InteractionReport: Codable {
    let configuration: String
    let exclusions: [String]
    let actionMilliseconds: [String: [Double]]
    let mainActorDelayBeyond8ms: [String: [Double]]
}

private struct PresentationSample: Codable {
    let scene: String
    let iteration: Int
    let mountLayoutMilliseconds: Double
    let resizeLayoutMilliseconds: [Double]
    let residentBytes: UInt64
}

private struct PresentationReport: Codable {
    let version: Int
    let implementation: String
    let sourceRevision: String
    let configuration: String
    let workload: String
    let exclusions: [String]
    let samples: [PresentationSample]
}
