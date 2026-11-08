import AppKit
import XCTest
@testable import Pilot

@MainActor
final class TerminalSessionTests: XCTestCase {
    func testExplicitPaneFocusTargetsTheRequestedInput() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let previous = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let target = NSTextField(frame: NSRect(x: 0, y: 120, width: 200, height: 24))
        window.contentView?.addSubview(previous)
        window.contentView?.addSubview(target)
        XCTAssertTrue(window.makeFirstResponder(previous))

        TerminalPaneInputFocus.move(to: target, in: window)

        XCTAssertTrue(window.firstResponder === target.currentEditor())
        XCTAssertFalse(window.firstResponder === previous)
    }

    func testDisconnectedDroneClearsPreviousInputWithoutConnecting() {
        let pane = Pane(kind: .terminal, terminalDestination: .drone(droneID: UUID()))
        let controller = DroneTerminalViewController(pane: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller.closePane(); window.close() }
        window.contentView?.addSubview(controller.view)
        let previous = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(previous)
        XCTAssertTrue(window.makeFirstResponder(previous))

        // Loading the native view leaves it disconnected; activation is the
        // only operation that restores a session or starts network activity.
        controller.focusPaneInput()

        XCTAssertFalse(window.firstResponder === previous)
        XCTAssertNil(window.firstResponder as? NSTextView)
    }

    func testNativePaneRecoversInitialFailureAndRetainsOutputAcrossReplacement() async throws {
        let droneID = UUID()
        let remoteID = UUID()
        let slot = NativeTerminalClientSlot()
        let provider = TerminalSessionProvider { _ in slot.client }
        let pane = Pane(kind: .terminal, terminalDestination: .drone(droneID: droneID))
        let controller = DroneTerminalViewController(pane: pane, provider: provider)
        defer { controller.closePane() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(controller.view)
        let input = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "terminal.remote-command"
        })
        let output = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        let send = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Send" })
        let retry = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Reconnect" })
        let labels = views.compactMap { $0 as? NSTextField }
        controller.updatePresentation(isActive: true, isSelected: false)
        try await waitForNativeTerminal { labels.contains { $0.stringValue.hasPrefix("Unavailable:") } }
        XCTAssertFalse(input.isEnabled)
        XCTAssertFalse(retry.isHidden)

        let first = TerminalFakeDroneClient(droneID: droneID, remoteID: remoteID)
        slot.client = first
        NotificationCenter.default.post(name: .droneTerminalClientDidChange, object: droneID)
        try await waitForNativeTerminal { input.isEnabled }
        XCTAssertTrue(retry.isHidden)
        first.emit("recovered", sequence: 0, offset: 0)
        try await waitForNativeTerminal { output.string == "recovered" }
        output.setSelectedRange(NSRange(location: 1, length: 3))

        let replacement = TerminalFakeDroneClient(droneID: droneID, remoteID: remoteID)
        slot.client = replacement
        NotificationCenter.default.post(name: .droneTerminalClientDidChange, object: droneID)
        try await waitForNativeTerminal { input.isEnabled }
        replacement.emit(" again", sequence: 1, offset: 9)
        try await waitForNativeTerminal { output.string == "recovered again" }
        XCTAssertEqual(output.selectedRange(), NSRange(location: 1, length: 3))
        XCTAssertEqual(pane.terminalDestination.remoteSessionID, remoteID)
        XCTAssertEqual(replacement.createCount, 0)
        input.stringValue = "echo fixture"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
        send.performClick(nil)
        try await waitForNativeTerminal { replacement.receivedInput == Data("echo fixture\r".utf8) }
        XCTAssertTrue(input.stringValue.isEmpty)

        controller.updatePresentation(isActive: false, isSelected: false)
        XCTAssertFalse(input.isEnabled)
        replacement.emit(" hidden", sequence: 2, offset: 15)
        await Task.yield()
        XCTAssertEqual(output.string, "recovered again")
        controller.updatePresentation(isActive: true, isSelected: false)
        try await waitForNativeTerminal { input.isEnabled && output.string == "recovered again hidden" }

        controller.closePane()
        XCTAssertFalse(input.isEnabled)
        first.emit("stale", sequence: 3, offset: 22)
        replacement.emit(" closed", sequence: 3, offset: 22)
        NotificationCenter.default.post(name: .droneTerminalClientDidChange, object: droneID)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(input.isEnabled)
        XCTAssertEqual(output.string, "recovered again hidden")
    }

    private func waitForNativeTerminal(
        timeout: Duration = .seconds(3),
        message: String = "Native terminal did not reach the expected state",
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), message)
    }

    func testLegacyPaneDefaultsToLocalDestination() {
        let pane = Pane(kind: .terminal)
        XCTAssertEqual(pane.terminalDestination, .local)
        XCTAssertTrue(pane.terminalSession is LocalTerminalSession)
        XCTAssertEqual(
            TerminalDestination.restored(kindRaw: nil, droneIDRaw: nil, remoteSessionIDRaw: nil),
            .local
        )
    }

    func testMalformedPersistedDestinationIsRecoverablyInvalid() {
        let destination = TerminalDestination.restored(
            kindRaw: "drone",
            droneIDRaw: "not-a-uuid",
            remoteSessionIDRaw: nil
        )
        XCTAssertEqual(destination.kind, .invalid)
        XCTAssertFalse(destination.isValid)
    }

    func testMalformedNonlocalDestinationNeverCreatesGhosttySurface() {
        let pane = Pane(kind: .terminal)
        pane.terminalDestinationRaw = TerminalDestinationKind.local.rawValue
        pane.terminalDroneIDRaw = UUID().uuidString
        let controller = TerminalPaneViewController(pane: pane)
        defer { controller.closePane() }

        _ = controller.view

        XCTAssertFalse(pane.terminalDestination.isValid)
        XCTAssertNil(GhosttyMetalView.view(for: pane.id))
        let labels = controller.view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue.contains("destination is invalid") })
    }

    func testLiveSessionCannotMoveToAnotherDestination() {
        let provider = TerminalSessionProvider()
        let pane = Pane(kind: .terminal)
        let original = provider.session(for: pane)
        XCTAssertTrue(original is LocalTerminalSession)

        pane.terminalDestinationRaw = TerminalDestinationKind.drone.rawValue
        pane.terminalDroneIDRaw = UUID().uuidString
        let changed = provider.session(for: pane)
        let unavailable = changed as? UnavailableTerminalSession
        XCTAssertEqual(unavailable?.failure, .destinationChanged)
        guard case .unavailable(let failure)? = unavailable?.bootstrap(workingDirectory: nil) else {
            return XCTFail("Expected an unavailable bootstrap")
        }
        XCTAssertEqual(failure, .destinationChanged)
    }

    func testRemoteRestoreAdoptsStableSessionAndReconnectGeneration() async throws {
        let droneID = UUID()
        let remoteID = UUID()
        let client = TerminalFakeDroneClient(droneID: droneID, remoteID: remoteID)
        let provider = TerminalSessionProvider { _ in client }
        let pane = Pane(
            kind: .terminal,
            terminalDestination: .drone(droneID: droneID)
        )

        let restoration = try await provider.restore(pane: pane)
        XCTAssertEqual(restoration.remoteSessionID, remoteID)
        XCTAssertEqual(pane.terminalDestination.remoteSessionID, remoteID)
        XCTAssertEqual(client.attachCount, 1)

        let first = provider.session(for: pane)
        let reconnected = provider.reconnect(pane: pane)
        XCTAssertEqual(
            reconnected.identity.generation,
            first.identity.generation + 1
        )
        XCTAssertNotEqual(first.identity.runtimeCacheKey, reconnected.identity.runtimeCacheKey)
        try await provider.restore(pane: pane)
        XCTAssertEqual(client.createCount, 1)
        XCTAssertEqual(client.attachCount, 2)
    }

    func testResizeCoordinatorSkipsSupersededDimensions() async {
        let coordinator = DroneTerminalResizeCoordinator()
        let started = TerminalResizeGate()
        let finish = TerminalResizeGate()
        var applied: [DroneResizeBody] = []
        let older = DroneResizeBody(columns: 80, rows: 24)
        let superseded = DroneResizeBody(columns: 100, rows: 30)
        let newest = DroneResizeBody(columns: 132, rows: 43)
        coordinator.resize {
            applied.append(older)
            await started.open()
            await finish.wait()
        }
        await started.wait()
        coordinator.resize { applied.append(superseded) }
        coordinator.resize { applied.append(newest) }

        await finish.open()
        await coordinator.waitForIdle()

        XCTAssertEqual(applied, [older, newest])
    }

    func testLocalCompanionInputDoesNotRequireTmux() async {
        var inputs: [TerminalSessionInput] = []
        let session = LocalTerminalSession(
            identity: TerminalSessionIdentity(
                paneID: UUID(), ownership: TerminalDestination.local.ownership, generation: 1
            ),
            persistentSessionName: "pilot-unavailable-\(UUID().uuidString)",
            companionInput: { input in
                inputs.append(input)
                return true
            }
        )

        let inserted = await session.sendCompanion(.literal("companion-ok"))
        let entered = await session.sendCompanion(.enter)

        XCTAssertTrue(inserted)
        XCTAssertTrue(entered)
        XCTAssertEqual(inputs, [.literal("companion-ok"), .enter])
    }

    func testLocalSessionRetainsTmuxBootstrapInputActivityDirectoryAndClose() async throws {
        guard let tmux = Self.tmuxExecutablePath() else { throw XCTSkip("tmux is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionName = "pilot-test-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let session = LocalTerminalSession(
            identity: TerminalSessionIdentity(
                paneID: UUID(), ownership: TerminalDestination.local.ownership, generation: 1
            ),
            persistentSessionName: sessionName
        )
        guard case .local(let bootstrap) = session.bootstrap(workingDirectory: root.path) else {
            return XCTFail("Expected a local bootstrap")
        }
        XCTAssertTrue(bootstrap?.contains(sessionName) == true)
        XCTAssertTrue(bootstrap?.contains(root.path) == true)
        XCTAssertEqual(try Self.runTmux(tmux, ["new-session", "-d", "-s", sessionName, "-c", root.path]), 0)
        var closed = false
        defer {
            if !closed { _ = try? Self.runTmux(tmux, ["kill-session", "-t", sessionName]) }
        }
        let output = root.appendingPathComponent("tmux.txt")

        let inserted = await session.send(.literal("printf tmux-ok > \(output.path)"))
        let entered = await session.send(.enter)
        XCTAssertTrue(inserted)
        XCTAssertTrue(entered)
        try await waitForNativeTerminal(timeout: .seconds(10), message: "tmux output did not arrive") {
            FileManager.default.fileExists(atPath: output.path)
        }
        let activity = await session.foregroundActivity(unavailableActivity: .running)
        XCTAssertEqual(activity, .idle)
        let listing = try await ProcessRunner.run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: tmux),
            arguments: ["list-panes", "-a", "-F", "#{session_name}\\t#{pane_pid}\\t#{cursor_flag}\\t#{window_active}\\t#{pane_active}"],
            timeout: .seconds(2)
        ))
        let parsed = PersistentTerminalSession.parsePaneRuntimes(listing.standardOutputString)
        XCTAssertNotNil(parsed[sessionName])
        let runtimes = await PersistentTerminalSession.loadAllPaneRuntimes(executable: URL(fileURLWithPath: tmux))
        XCTAssertNotNil(runtimes?[sessionName])
        try await waitForNativeTerminal(timeout: .seconds(10), message: "tmux cwd did not converge") {
            session.currentDirectorySnapshot() != nil
        }
        XCTAssertEqual(
            session.currentDirectorySnapshot().map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            },
            root.resolvingSymlinksInPath().standardizedFileURL.path
        )
        closed = await session.close()
        XCTAssertTrue(closed)
        XCTAssertNotEqual(try Self.runTmux(tmux, ["has-session", "-t", sessionName]), 0)
    }

    private static func tmuxExecutablePath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func runTmux(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testMissingDroneClientNeverUsesLocalSession() {
        let droneID = UUID()
        let provider = TerminalSessionProvider { _ in nil }
        let pane = Pane(
            kind: .terminal,
            terminalDestination: .drone(droneID: droneID)
        )
        let session = provider.session(for: pane)
        XCTAssertEqual(
            (session as? UnavailableTerminalSession)?.failure,
            .droneUnavailable(droneID)
        )
        XCTAssertFalse(session is LocalTerminalSession)
    }
}

private final class TerminalResizeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func open() async {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }

    func wait() async {
        _ = await withCheckedContinuation { continuation in
            lock.withLock {
                if opened {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }
    }
}

private final class TerminalFakeDroneClient: DroneTerminalClient, @unchecked Sendable {
    let droneID: UUID
    private let remoteID: UUID
    private(set) var createCount = 0
    private(set) var attachCount = 0
    private let outputLock = NSLock()
    private var outputHandler: (@Sendable (DroneOutputBody) -> Bool)?
    private var inputBytes = Data()
    var receivedInput: Data { outputLock.withLock { inputBytes } }

    func setOutputHandler(_ handler: @escaping @Sendable (DroneOutputBody) -> Bool,
                          for reference: DroneTerminalSessionReference) async {
        outputLock.withLock { outputHandler = handler }
    }

    func emit(_ text: String, sequence: UInt64, offset: UInt64) {
        let handler = outputLock.withLock { outputHandler }
        _ = handler?(DroneOutputBody(sequence: sequence, offset: offset, data: Data(text.utf8), isFinal: false))
    }

    init(droneID: UUID, remoteID: UUID) {
        self.droneID = droneID
        self.remoteID = remoteID
    }

    func createTerminal(
        workingDirectory: String?,
        generation: UInt64,
        requestID: UUID
    ) async throws -> UUID {
        createCount += 1
        return remoteID
    }

    func attachTerminal(_ reference: DroneTerminalSessionReference) async throws {
        attachCount += 1
    }

    func sendInput(_ data: Data, to reference: DroneTerminalSessionReference) async throws {
        outputLock.withLock { inputBytes.append(data) }
    }
    func foregroundActivity(for reference: DroneTerminalSessionReference) async throws -> TerminalProcessActivity {
        .idle
    }
    func currentDirectory(for reference: DroneTerminalSessionReference) async throws -> String? { nil }
    func interrupt(_ reference: DroneTerminalSessionReference) async throws {}
    func detach(_ reference: DroneTerminalSessionReference) async throws {}
    func close(_ reference: DroneTerminalSessionReference) async throws {}
}

private final class NativeTerminalClientSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TerminalFakeDroneClient?
    var client: TerminalFakeDroneClient? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
