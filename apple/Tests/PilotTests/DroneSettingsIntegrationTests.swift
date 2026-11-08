import AppKit
import XCTest
@testable import Pilot

@MainActor
final class DroneSettingsIntegrationTests: XCTestCase {
    func testRestoredRegistryLaysOutAndManagesFifteenDronesAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("drone-settings-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = DroneRegistryPersistence(url: directory.appendingPathComponent("drones.json"))
        let records = (0..<15).map { index in
            var record = DroneRecord(
                id: UUID(),
                name: String(format: "Worker %02d", index),
                endpoints: [.hostPort(host: "192.168.50.\(index + 10)", port: 7_400 + UInt16(index))]
            )
            record.hardware = DroneHardwarePresentation(model: "Mac mini", processor: "Apple M\(index % 4 + 1)")
            return record
        }
        try persistence.save(records)

        let transport = DroneSettingsFakeTransport()
        let store = Self.makeStore(persistence: persistence, transport: transport)
        XCTAssertEqual(store.records.count, 15)
        let (controller, window) = Self.present(store: store)
        var reopenedWindow: NSWindow?
        defer {
            for host in [window, reopenedWindow].compactMap({ $0 }) {
                if let sheet = host.attachedSheet { host.endSheet(sheet) }
                host.close()
            }
        }
        try verifySavedRows(in: controller, match: store.records)

        let selected = try XCTUnwrap(store.records.first)
        let actionItems = try menuItems(for: selected.name, in: controller)
        XCTAssertEqual(actionItems.map(\.title), ["Retry", "Diagnostics", "Rename…", "Forget and Revoke…"])

        try perform("Retry", for: selected.name, in: controller)
        var completed = await waitUntil { transport.connectedIDs == [selected.id] }
        XCTAssertTrue(completed, "The row Retry action must use the fake transport")
        XCTAssertEqual(store.diagnostics[selected.id]?.connectAttempts, 1)

        try perform("Diagnostics", for: selected.name, in: controller)
        var sheet = try await presentedSheet(in: window)
        var labels = descendants(of: try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == "\(selected.name) Diagnostics" })
        let diagnostics = try XCTUnwrap(descendants(of: try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NativeSettingsTextView }.first)
        XCTAssertTrue(diagnostics.string.contains("Drone ID: \(selected.id.uuidString)"))
        XCTAssertTrue(diagnostics.string.contains("Connect attempts: 1"))
        XCTAssertTrue(diagnostics.string.contains("Endpoint: \(selected.endpoints[0].displayText)"))
        try click("Done", in: sheet)
        completed = await waitUntil { window.attachedSheet == nil }
        XCTAssertTrue(completed)

        try perform("Rename…", for: selected.name, in: controller)
        sheet = try await presentedSheet(in: window)
        let form = try XCTUnwrap(sheet.contentViewController as? NativeSettingsFormController)
        let input = try XCTUnwrap(descendants(of: form.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        input.stringValue = "Worker 00 Renamed"
        try click("Save", in: sheet)
        XCTAssertEqual(store.records.first { $0.id == selected.id }?.name, "Worker 00 Renamed")
        completed = await waitUntil { window.attachedSheet == nil }
        XCTAssertTrue(completed)
        controller.refresh()
        try verifySavedRows(in: controller, match: store.records)
        XCTAssertEqual(try persistence.load().first { $0.id == selected.id }?.name, "Worker 00 Renamed")

        try perform("Forget and Revoke…", for: "Worker 00 Renamed", in: controller)
        sheet = try await presentedSheet(in: window)
        labels = descendants(of: try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue.contains("removes its saved metadata") })
        try click("Forget and Revoke", in: sheet)
        completed = await waitUntil { !store.records.contains(where: { $0.id == selected.id }) }
        XCTAssertTrue(completed, "The confirmation must complete the fake revocation and remove metadata")
        XCTAssertEqual(transport.revokedIDs, [selected.id])
        XCTAssertEqual(try persistence.load().count, 14)
        controller.refresh()
        try verifySavedRows(in: controller, match: store.records)

        window.close()
        let reopenedTransport = DroneSettingsFakeTransport()
        let reopenedStore = Self.makeStore(persistence: persistence, transport: reopenedTransport)
        let reopened = Self.present(store: reopenedStore)
        reopenedWindow = reopened.window
        XCTAssertEqual(reopenedStore.records.count, 14)
        XCTAssertFalse(reopenedStore.records.contains { $0.id == selected.id })
        XCTAssertEqual(reopenedStore.records.first?.name, "Worker 01")
        try verifySavedRows(in: reopened.controller, match: reopenedStore.records)
        XCTAssertTrue(reopenedTransport.connectedIDs.isEmpty)
        XCTAssertTrue(reopenedTransport.revokedIDs.isEmpty)
    }

    private static func makeStore(
        persistence: DroneRegistryPersistence,
        transport: DroneSettingsFakeTransport
    ) -> DroneStore {
        DroneStore(
            persistence: persistence,
            transport: transport,
            discovery: DroneDiscovery(allowsNetwork: false),
            timing: DroneSupervisorTiming(sleep: { _ in throw CancellationError() })
        )
    }

    private static func present(store: DroneStore) -> (controller: DroneSettingsViewController, window: NSWindow) {
        let controller = DroneSettingsViewController(store: store, runsDiscovery: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1_200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private func verifySavedRows(
        in controller: DroneSettingsViewController,
        match records: [DroneRecord],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        controller.view.layoutSubtreeIfNeeded()
        let saved = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? NativeSettingsGroupView }.first,
            file: file,
            line: line
        )
        let buttons = descendants(of: saved).compactMap { $0 as? NSButton }.filter {
            $0.accessibilityLabel() == "Drone Actions"
        }
        XCTAssertEqual(buttons.count, records.count, file: file, line: line)
        let rows = try buttons.map { try XCTUnwrap($0.target as? NSView, file: file, line: line) }
        for (record, row) in zip(records, rows) {
            let fields = descendants(of: row).compactMap { $0 as? NSTextField }
            XCTAssertEqual(fields.first?.stringValue, record.name, file: file, line: line)
            let summary = ([record.hardware.displayText] + record.endpoints.map(\.displayText))
                .filter { !$0.isEmpty }.joined(separator: " · ")
            XCTAssertTrue(fields.contains { $0.stringValue == summary }, file: file, line: line)
            XCTAssertFalse(row.isHidden, file: file, line: line)
            XCTAssertGreaterThan(row.frame.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(row.frame.height, NativeSettingsGroupView.minimumRowHeight, file: file, line: line)
        }
    }

    private func menuItems(for name: String, in controller: DroneSettingsViewController) throws -> [NSMenuItem] {
        let button = try actionButton(for: name, in: controller)
        let row = try XCTUnwrap(button.target as? NSView)
        return try XCTUnwrap(Mirror(reflecting: row).children.first { $0.label == "menuItems" }?.value as? [NSMenuItem])
    }

    private func perform(_ title: String, for name: String, in controller: DroneSettingsViewController) throws {
        let item = try XCTUnwrap(menuItems(for: name, in: controller).first { $0.title == title })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    private func actionButton(for name: String, in controller: DroneSettingsViewController) throws -> NSButton {
        try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSButton }.first { button in
            guard button.accessibilityLabel() == "Drone Actions", let row = button.target as? NSView else { return false }
            return descendants(of: row).compactMap { $0 as? NSTextField }.first?.stringValue == name
        })
    }

    private func presentedSheet(in window: NSWindow) async throws -> NSWindow {
        let presented = await waitUntil { window.attachedSheet != nil }
        XCTAssertTrue(presented, "Expected an AppKit sheet")
        return try XCTUnwrap(window.attachedSheet)
    }

    private func click(_ title: String, in window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        let button = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSButton }.first { $0.title == title })
        button.performClick(nil)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
private final class DroneSettingsFakeTransport: DroneTransportFactory {
    private(set) var connectedIDs: [UUID] = []
    private(set) var revokedIDs: [UUID] = []

    func connect(_ request: DroneTransportRequest) async throws -> any DroneConnection {
        connectedIDs.append(request.droneID)
        throw DroneTransportError.connectionFailed
    }

    func revoke(droneID: UUID) async throws {
        revokedIDs.append(droneID)
    }
}
