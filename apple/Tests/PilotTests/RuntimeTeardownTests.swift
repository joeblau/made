import Foundation
import SwiftData
import Testing
@testable import Pilot

@Suite("Runtime resource teardown")
@MainActor
struct RuntimeTeardownTests {
    @Test("Cancel preserves a busy terminal without performing teardown")
    func cancelBusyTerminalClose() async {
        let pane = Pane(kind: .terminal, sortOrder: 0)
        var didClose = false
        var didConfirm = false
        await TerminalCloseConfirmation.perform(
            panes: [pane],
            activity: { _ in .running },
            confirm: { panes in
                #expect(panes.map(\.id) == [pane.id])
                didConfirm = true
                return false
            },
            action: { didClose = true }
        )
        #expect(didConfirm)
        #expect(!didClose)
    }

    @Test("A busy terminal closes only after explicit confirmation")
    func confirmBusyTerminalClose() async {
        let pane = Pane(kind: .terminal, sortOrder: 0)
        var events: [String] = []
        await TerminalCloseConfirmation.perform(
            panes: [pane],
            activity: { _ in events.append("check"); return .running },
            confirm: { _ in events.append("confirm"); return true },
            action: { events.append("close") }
        )
        #expect(events == ["check", "confirm", "close"])
    }

    @Test("Idle terminals and non-terminal panes close without confirmation")
    func idleCloseDoesNotPrompt() async {
        let terminal = Pane(kind: .terminal, sortOrder: 0)
        let browser = Pane(kind: .browser, sortOrder: 1)
        var checks = 0
        var didClose = false
        await TerminalCloseConfirmation.perform(
            panes: [terminal, browser],
            activity: { session in
                #expect(session == terminal.persistentSessionName)
                checks += 1
                return .idle
            },
            confirm: { _ in Issue.record("Idle close must not prompt"); return false },
            action: { didClose = true }
        )
        #expect(checks == 1)
        #expect(didClose)
    }

    @Test("Workspace close checks every terminal and suppresses duplicate close requests")
    func workspaceCloseAndDuplicateRequests() async {
        let first = Pane(kind: .terminal, sortOrder: 0)
        let second = Pane(kind: .terminal, sortOrder: 1)
        var checks = 0
        var closeCount = 0
        await TerminalCloseConfirmation.perform(
            panes: [first, second],
            activity: { _ in checks += 1; return .running },
            confirm: { panes in
                #expect(panes.count == 2)
                await TerminalCloseConfirmation.perform(
                    panes: [second],
                    activity: { _ in Issue.record("Duplicate close must not run"); return .idle },
                    confirm: { _ in false },
                    action: { closeCount += 1 }
                )
                return true
            },
            action: { closeCount += 1 }
        )
        #expect(checks == 2)
        #expect(closeCount == 1)
    }

    private enum InjectedFailure: Error {
        case unavailable
    }

    @Test("Deleting a workspace removes device and simulator sessions")
    func deletingWorkspaceTearsDownEveryRuntimePane() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = Workspace(name: "Runtime teardown")
        let device = Pane(kind: .device, sortOrder: 0)
        let simulator = Pane(kind: .simulator, sortOrder: 1)
        let android = Pane(kind: .android, sortOrder: 2)
        workspace.panes = [device, simulator, android]
        device.workspace = workspace
        simulator.workspace = workspace
        android.workspace = workspace
        container.mainContext.insert(workspace)
        try container.mainContext.save()

        let preferenceKey = DeviceCaptureSession.preferenceKey(for: device.id)
        let preferenceNameKey = DeviceCaptureSession.preferenceNameKey(for: device.id)
        UserDefaults.standard.set("deleted-device-id", forKey: preferenceKey)
        UserDefaults.standard.set("Deleted iPhone", forKey: preferenceNameKey)
        defer { DeviceCaptureRegistry.shared.remove(paneID: device.id) }
        _ = DeviceCaptureRegistry.shared.session(for: device.id)
        _ = SimulatorRegistry.shared.session(for: simulator.id)
        _ = AndroidDeviceRegistry.shared.session(for: android.id)
        #expect(DeviceCaptureRegistry.shared.existingSession(for: device.id) != nil)
        #expect(SimulatorRegistry.shared.existingSession(for: simulator.id) != nil)
        #expect(AndroidDeviceRegistry.shared.existingSession(for: android.id) != nil)

        #expect(store.deleteWorkspace(workspace))

        #expect(DeviceCaptureRegistry.shared.existingSession(for: device.id) == nil)
        #expect(SimulatorRegistry.shared.existingSession(for: simulator.id) == nil)
        #expect(AndroidDeviceRegistry.shared.existingSession(for: android.id) == nil)
        #expect(UserDefaults.standard.object(forKey: preferenceKey) == nil)
        #expect(UserDefaults.standard.object(forKey: preferenceNameKey) == nil)
    }

    @Test("Failed pane deletion preserves its device choice")
    func failedPaneDeletionPreservesDevicePreference() throws {
        let container = try makeContainer()
        let workspace = Workspace(name: "Pane rollback")
        let terminal = workspace.panes[0]
        let device = Pane(kind: .device, sortOrder: 1)
        workspace.panes = [terminal, device]
        terminal.workspace = workspace
        device.workspace = workspace
        container.mainContext.insert(workspace)
        try container.mainContext.save()

        let preferenceKey = DeviceCaptureSession.preferenceKey(for: device.id)
        let preferenceNameKey = DeviceCaptureSession.preferenceNameKey(for: device.id)
        UserDefaults.standard.set("pane-rollback-device", forKey: preferenceKey)
        UserDefaults.standard.set("Rollback iPhone", forKey: preferenceNameKey)
        defer { DeviceCaptureRegistry.shared.remove(paneID: device.id) }
        let originalSession = DeviceCaptureRegistry.shared.session(for: device.id)

        let deleted = workspace.removePane(device) { _ in
            #expect(UserDefaults.standard.string(forKey: preferenceKey) == "pane-rollback-device")
            throw InjectedFailure.unavailable
        }

        #expect(!deleted)
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == "pane-rollback-device")
        #expect(UserDefaults.standard.string(forKey: preferenceNameKey) == "Rollback iPhone")
        #expect(try container.mainContext.fetch(FetchDescriptor<Pane>()).contains { $0.id == device.id })
        let restoredSession = try #require(DeviceCaptureRegistry.shared.existingSession(for: device.id))
        #expect(restoredSession === originalSession)
        #expect(restoredSession.preferredDeviceUniqueID == "pane-rollback-device")
        #expect(restoredSession.preferredDeviceName == "Rollback iPhone")
    }

    @Test("Failed workspace deletion preserves main and Extension device choices")
    func failedWorkspaceDeletionPreservesEveryDevicePreference() throws {
        let container = try makeContainer()
        let source = Workspace(name: "Workspace rollback")
        let sourceDevice = Pane(kind: .device)
        source.panes = [sourceDevice]
        sourceDevice.workspace = source

        let extensionWorkspace = Workspace(name: "Extension rollback")
        let extensionDevice = Pane(kind: .device)
        extensionWorkspace.panes = [extensionDevice]
        extensionDevice.workspace = extensionWorkspace
        let link = ExtensionWorkspaceLink(sourceWorkspaceID: source.id, workspace: extensionWorkspace)
        container.mainContext.insert(source)
        container.mainContext.insert(extensionWorkspace)
        container.mainContext.insert(link)
        try container.mainContext.save()
        let store = WorkspaceStore(modelContext: container.mainContext)

        let deviceIDs = [sourceDevice.id, extensionDevice.id]
        defer { deviceIDs.forEach { DeviceCaptureRegistry.shared.remove(paneID: $0) } }
        for (index, paneID) in deviceIDs.enumerated() {
            UserDefaults.standard.set("workspace-rollback-\(index)", forKey: DeviceCaptureSession.preferenceKey(for: paneID))
            UserDefaults.standard.set("Rollback iPhone \(index)", forKey: DeviceCaptureSession.preferenceNameKey(for: paneID))
            _ = DeviceCaptureRegistry.shared.session(for: paneID)
        }

        let deleted = store.deleteWorkspace(source) { _ in
            for (index, paneID) in deviceIDs.enumerated() {
                #expect(
                    UserDefaults.standard.string(forKey: DeviceCaptureSession.preferenceKey(for: paneID))
                        == "workspace-rollback-\(index)"
                )
            }
            throw InjectedFailure.unavailable
        }

        #expect(!deleted)
        for (index, paneID) in deviceIDs.enumerated() {
            #expect(
                UserDefaults.standard.string(forKey: DeviceCaptureSession.preferenceKey(for: paneID))
                    == "workspace-rollback-\(index)"
            )
            #expect(
                UserDefaults.standard.string(forKey: DeviceCaptureSession.preferenceNameKey(for: paneID))
                    == "Rollback iPhone \(index)"
            )
        }
        let workspaceIDs = try container.mainContext.fetch(FetchDescriptor<Workspace>()).map(\.id)
        #expect(workspaceIDs.contains(source.id))
        #expect(workspaceIDs.contains(extensionWorkspace.id))
        #expect(try container.mainContext.fetch(FetchDescriptor<ExtensionWorkspaceLink>()).contains { $0 === link })
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
            ExtensionWorkspaceLink.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }
}
