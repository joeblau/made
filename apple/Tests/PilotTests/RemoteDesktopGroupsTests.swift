import Foundation
import AppKit
import SwiftData
import Testing
@testable import Pilot

@Suite("Remote desktop groups")
@MainActor
struct RemoteDesktopGroupsTests {
    @Test("Restoring groups never writes preferences during presentation")
    func restoringLayoutDoesNotSave() throws {
        try withGroups { groups, defaults in
            groups.reconcile(connectionIDs: [UUID(), UUID()])
            let selected = groups.addGroup()
            groups.renameGroup(selected, to: "Build Macs")
            let writesBeforeRestore = defaults.writeCount

            let restored = RemoteDesktopGroups(defaults: defaults)

            #expect(restored.groups == groups.groups)
            #expect(restored.selectedGroupID == selected)
            #expect(defaults.writeCount == writesBeforeRestore)
        }
    }

    @Test("Native segmented control positions its inline close button")
    func inlineCloseButtonLayout() {
        let control = PilotNativeSegmentedControl(
            labels: ["One", "Two"], trackingMode: .selectOne, target: nil, action: nil
        )
        control.addSubview(control.closeButton)
        control.showsCloseButton = true
        control.selectedSegment = 0
        control.frame = NSRect(x: 0, y: 0, width: 200, height: 24)

        control.updateCloseButton()
        #expect(control.closeButton.alphaValue == 0)
        #expect(!control.closeButton.isEnabled)

        control.isCloseHovering = true
        control.updateCloseButton()

        #expect(!control.closeButton.isHidden)
        #expect(control.closeButton.frame.midX < control.bounds.midX)
        #expect(control.closeButton.frame.minX >= 0)
    }

    @Test("Selecting the current group does not rewrite preferences")
    func unchangedSelectionDoesNotSave() throws {
        try withGroups { groups, defaults in
            groups.reconcile(connectionIDs: [UUID()])
            let first = try #require(groups.selectedGroupID)
            let second = groups.addGroup()
            let writesBeforeSelection = defaults.writeCount

            groups.selectedGroupID = second
            #expect(defaults.writeCount == writesBeforeSelection)

            groups.selectedGroupID = first
            #expect(defaults.writeCount == writesBeforeSelection + 1)
            #expect(RemoteDesktopGroups(defaults: defaults).selectedGroupID == first)
        }
    }

    @Test("Existing machines are grouped four at a time with blank remaining slots")
    func existingConnectionsArePreserved() throws {
        try withGroups { groups, _ in
            let ids = (0..<6).map { _ in UUID() }
            groups.reconcile(connectionIDs: ids)
            #expect(groups.groups.count == 2)
            #expect(groups.groups[0].connectionIDs == Array(ids.prefix(4)))
            #expect(groups.groups[1].slots == [ids[4], ids[5], nil, nil])
            #expect(groups.selectedGroup?.id == groups.groups[0].id)
        }
    }

    @Test("Renames, group selection, and fixed slots survive reopening")
    func layoutPersists() throws {
        try withGroups { groups, defaults in
            let ids = [UUID(), UUID()]
            groups.reconcile(connectionIDs: ids)
            let second = groups.addGroup()
            groups.renameGroup(second, to: "  Build Macs  ")
            #expect(groups.place(ids[0], in: second, slot: 3))

            let restored = RemoteDesktopGroups(defaults: defaults)
            restored.reconcile(connectionIDs: ids)
            #expect(restored.selectedGroupID == second)
            #expect(restored.selectedGroup?.name == "Build Macs")
            #expect(restored.selectedGroup?.slots == [nil, nil, nil, ids[0]])
            #expect(restored.groups[0].slots == [nil, ids[1], nil, nil])
            restored.renameGroup(second, to: " \n ")
            #expect(restored.selectedGroup?.name == "Build Macs")
        }
    }

    @Test("A full group rejects an extra machine without removing it from its source")
    func capacityIsEnforced() throws {
        try withGroups { groups, _ in
            let ids = (0..<5).map { _ in UUID() }
            groups.reconcile(connectionIDs: ids)
            let full = groups.groups[0].id
            #expect(!groups.place(ids[4], in: full))
            #expect(!groups.place(ids[4], in: full, slot: 0))
            #expect(groups.groups[0].connectionIDs == Array(ids.prefix(4)))
            #expect(groups.groups[1].connectionIDs == [ids[4]])
        }
    }

    @Test("Removing a machine leaves its exact grid position blank")
    func deletionDoesNotShiftScreens() throws {
        try withGroups { groups, _ in
            let ids = (0..<4).map { _ in UUID() }
            groups.reconcile(connectionIDs: ids)
            groups.reconcile(connectionIDs: [ids[0], ids[2], ids[3]])
            #expect(groups.selectedGroup?.slots == [ids[0], nil, ids[2], ids[3]])
        }
    }

    @Test("Moving into a blank slot retains all other positions and rejects invalid slots")
    func movingWithinGroup() throws {
        try withGroups { groups, _ in
            let ids = [UUID(), UUID()]
            groups.reconcile(connectionIDs: ids)
            let id = try #require(groups.selectedGroupID)
            #expect(groups.place(ids[0], in: id, slot: 3))
            #expect(groups.selectedGroup?.slots == [nil, ids[1], nil, ids[0]])
            #expect(!groups.place(ids[0], in: id, slot: 4))
            #expect(!groups.place(ids[0], in: id, slot: -1))
        }
    }

    @Test("Deleting an empty group preserves machines and a valid selected group")
    func onlyEmptyGroupsCanBeDeleted() throws {
        try withGroups { groups, _ in
            groups.reconcile(connectionIDs: [UUID()])
            let first = try #require(groups.selectedGroupID)
            let empty = groups.addGroup()
            groups.deleteEmptyGroup(first)
            #expect(groups.groups.count == 2)
            groups.deleteEmptyGroup(empty)
            #expect(groups.selectedGroupID == first)
            #expect(groups.groups.count == 1)
        }
    }

    @Test("Selecting a computer reveals its group and preserves its exact slot")
    func selectingComputerRevealsGroup() throws {
        try withGroups { groups, _ in
            let ids = (0..<6).map { _ in UUID() }
            groups.reconcile(connectionIDs: ids)
            let layoutBeforeSelection = groups.groups
            let selected = groups.selectConnection(ids[5])

            #expect(selected == ids[5])
            #expect(groups.selectedGroupID == groups.groups[1].id)
            #expect(groups.selectedGroup?.slots == [ids[4], ids[5], nil, nil])
            #expect(groups.groups == layoutBeforeSelection)
        }
    }

    @Test("An externally selected computer wins over the restored group's first computer")
    func restoredGroupDoesNotOverrideExternalSelection() throws {
        try withGroups { groups, defaults in
            let ids = (0..<6).map { _ in UUID() }
            groups.reconcile(connectionIDs: ids)
            let originalGroupID = groups.selectedGroupID
            let restored = RemoteDesktopGroups(defaults: defaults)
            #expect(restored.selectedGroupID == originalGroupID)

            restored.reconcile(connectionIDs: ids)
            let selected = restored.selectConnection(ids[5])
            #expect(selected == ids[5])
            #expect(restored.selectedGroupID == restored.groups[1].id)
        }
    }

    @Test("Local group selection preserves a member or chooses its first occupied slot")
    func selectingGroupChoosesVisibleComputer() throws {
        try withGroups { groups, _ in
            let ids = (0..<6).map { _ in UUID() }
            groups.reconcile(connectionIDs: ids)
            let first = groups.groups[0].id
            let second = groups.groups[1].id

            let preserved = groups.selectGroup(first, preserving: ids[2])
            #expect(preserved == ids[2])
            let switched = groups.selectGroup(second, preserving: ids[2])
            #expect(switched == ids[4])
            #expect(groups.selectedGroupID == second)

            let empty = groups.addGroup()
            let blankSelection = groups.selectGroup(empty, preserving: ids[4])
            #expect(blankSelection == nil)
            #expect(groups.selectedGroupID == empty)
        }
    }

    @Test("Unknown or unchanged computer selection does not rewrite group preferences")
    func missingOrUnchangedSelectionDoesNotSave() throws {
        try withGroups { groups, defaults in
            let ids = [UUID(), UUID()]
            groups.reconcile(connectionIDs: ids)
            let writesBeforeSelection = defaults.writeCount

            let selected = groups.selectConnection(ids[1])
            let missing = groups.selectConnection(UUID())
            #expect(selected == ids[1])
            #expect(missing == ids[0])
            #expect(defaults.writeCount == writesBeforeSelection)
        }
    }

    private func withGroups(_ body: (RemoteDesktopGroups, CountingGroupDefaults) throws -> Void) throws {
        let suite = "RemoteDesktopGroupsTests-\(UUID().uuidString)"
        let defaults = try #require(CountingGroupDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(RemoteDesktopGroups(defaults: defaults), defaults)
    }
}

private final class CountingGroupDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0

    var writeCount: Int { lock.withLock { writes } }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { writes += 1 }
        super.set(value, forKey: defaultName)
    }
}

@Suite("Remote desktop group layout", .serialized)
@MainActor
struct RemoteDesktopGroupLayoutTests {
    @Test("Two machines leave visible blank cards at desktop and compact window sizes",
           arguments: [CGSize(width: 1000, height: 800), CGSize(width: 640, height: 480)])
    func twoMachinesLeaveBlankSlots(size: CGSize) async throws {
        let suite = "RemoteDesktopGrid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema([
            Workspace.self, Pane.self, BrowserState.self, EditorState.self,
            Note.self, RemoteDesktopConnection.self, ExtensionWorkspaceLink.self,
        ])
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let machines = ["Mini01", "Mini02"].map { RemoteDesktopConnection(host: "\($0).local", nickname: $0) }
        for machine in machines { container.mainContext.insert(machine) }
        try container.mainContext.save()
        let groups = RemoteDesktopGroups(defaults: defaults)
        groups.reconcile(connectionIDs: machines.map(\.id))
        let sessions = RemoteDesktopSessionManager()
        defer { sessions.endAllSessions() }
        let store = WorkspaceStore(modelContext: container.mainContext)
        let controller = RemoteDesktopViewController(store: store, sessions: sessions, groups: groups, isLive: false)
        let view = controller.view
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let left = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh * 3 / 4)?.usingColorSpace(.deviceRGB))
        let right = try #require(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh * 3 / 4)?.usingColorSpace(.deviceRGB))
        #expect(left.redComponent > 0.02 && left.greenComponent > 0.02 && left.blueComponent > 0.02)
        #expect(right.redComponent > 0.02 && right.greenComponent > 0.02 && right.blueComponent > 0.02)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("remote-desktop-grid-\(Int(size.width)).png"))
        }
        controller.updatePresentation(isActive: false, isSelected: false)
        window.contentView = nil
        window.close()
        try await Task.sleep(for: .milliseconds(100))
        withExtendedLifetime(container) {}
    }
}
