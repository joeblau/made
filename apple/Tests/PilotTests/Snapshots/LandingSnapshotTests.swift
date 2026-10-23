import AppKit
import SwiftUI
import XCTest
@testable import Pilot

final class LandingSnapshotTests: XCTestCase {
    func testCatalogOptions() throws {
        let defaults = try SnapshotOptions(environment: [:])
        XCTAssertEqual(defaults.scenes.count, 14)
        XCTAssertEqual(defaults.appearances, ["light", "dark"])
        XCTAssertEqual(defaults.scale, 2)
        let filtered = try SnapshotOptions(environment: ["MADE_SNAPSHOT_SCENES": "notes,actions", "MADE_SNAPSHOT_APPEARANCE": "dark"])
        XCTAssertEqual(filtered.scenes, [.notes, .actions])
        XCTAssertEqual(filtered.appearances, ["dark"])
        for options in [["MADE_SNAPSHOT_SCENES": "notes,typo"], ["MADE_SNAPSHOT_SCENES": "notes,notes"],
                        ["MADE_SNAPSHOT_SCENES": ""], ["MADE_SNAPSHOT_APPEARANCE": "sepia"],
                        ["MADE_SNAPSHOT_WIDTH": "0"], ["MADE_SNAPSHOT_SCALE": "3"]] {
            XCTAssertThrowsError(try SnapshotOptions(environment: options))
        }
    }

    @MainActor
    func testFixturesArePopulatedAndIsolated() async throws {
        let original = UserDefaults.standard.object(forKey: "selectedNoteID") as? String
        let fixtures = try SnapshotFixtures()
        defer { fixtures.close() }
        try await fixtures.prepare()
        XCTAssertEqual(fixtures.workspace.workspaces.count, 7)
        XCTAssertEqual(fixtures.workspace.notes.count, 4)
        XCTAssertEqual(fixtures.docker.containers.count, 8)
        XCTAssertEqual(fixtures.runners.snapshot.runners.count, 8)
        XCTAssertEqual(Set(fixtures.runners.snapshot.runners.map(\.state)), [.idle, .busy, .offline])
        XCTAssertFalse(fixtures.tasks.tasks.isEmpty)
        XCTAssertFalse(fixtures.repository.actions.isEmpty)
        XCTAssertFalse(fixtures.repository.pullRequests.isEmpty)
        XCTAssertFalse(fixtures.repository.filesystem.isEmpty)
        XCTAssertFalse(fixtures.history.isEmpty)
        XCTAssertEqual(fixtures.history.dayTotals.count, 30)
        XCTAssertEqual(fixtures.history.totalCostUSD, fixtures.history.modelTotals.reduce(0) { $0 + $1.cost }, accuracy: 0.001)
        guard case .usage = fixtures.usage.openAI else { return XCTFail("Missing plan fixture") }
        XCTAssertEqual(UserDefaults.standard.object(forKey: "selectedNoteID") as? String, original)
    }

    @MainActor
    func testCaptureCatalog() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["MADE_SNAPSHOT_OUTPUT"] else {
            throw XCTSkip("Run apple/bin/capture-pilot-scenes.py to export landing-page scenes")
        }
        let options = try SnapshotOptions(environment: environment)
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = try SnapshotFixtures()
        defer { fixtures.close() }
        try await fixtures.prepare()
        var assets: [SnapshotAsset] = []
        for scene in options.scenes {
            for appearance in options.appearances {
                let name = "cockpit-\(scene.rawValue)-\(appearance).png"
                let data = try await render(scene, appearance: appearance, fixtures: fixtures, options: options)
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                assets.append(SnapshotAsset(scene: scene.rawValue, appearance: appearance, file: name,
                                            width: options.width * options.scale, height: options.height * options.scale,
                                            scale: options.scale, alt: "Cockpit — \(scene.caption.lowercased()) (\(appearance) mode)"))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifest = SnapshotManifest(version: 1, fixtureDate: "2026-10-23", assets: assets)
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertEqual(assets.count, options.scenes.count * options.appearances.count)
    }

    @MainActor
    private func render(
        _ scene: SnapshotScene, appearance: String, fixtures: SnapshotFixtures, options: SnapshotOptions
    ) async throws -> Data {
        let size = NSSize(width: options.width, height: options.height)
        let root = SnapshotWorkbench(scene: scene, fixtures: fixtures)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, appearance == "light" ? .light : .dark)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        let priorAppearance = NSApp.appearance
        NSApp.appearance = window.appearance
        defer {
            window.close()
            NSApp.appearance = priorAppearance
        }
        host.layoutSubtreeIfNeeded()
        // Let representables and native scroll views finish their first layout.
        // Data readiness was checked separately; this is not a network timeout.
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: options.width * options.scale,
            pixelsHigh: options.height * options.scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw SnapshotError.renderFailed("Could not allocate \(scene.rawValue)") }
        bitmap.size = size
        window.appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 10_000 else {
            throw SnapshotError.renderFailed("Empty capture: \(scene.rawValue)")
        }
        XCTAssertEqual(bitmap.pixelsWide, options.width * options.scale)
        XCTAssertEqual(bitmap.pixelsHigh, options.height * options.scale)
        return png
    }
}

private struct SnapshotManifest: Encodable {
    let version: Int
    let fixtureDate: String
    let assets: [SnapshotAsset]
}

private struct SnapshotAsset: Encodable {
    let scene: String
    let appearance: String
    let file: String
    let width: Int
    let height: Int
    let scale: Int
    let alt: String
}
