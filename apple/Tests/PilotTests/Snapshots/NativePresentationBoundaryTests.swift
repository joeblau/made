import AppKit
import XCTest
@testable import Pilot

final class NativePresentationBoundaryTests: XCTestCase {
    @MainActor
    func testEverySnapshotSceneUsesNativeViews() async throws {
        let fixtures = try SnapshotFixtures()
        defer { fixtures.close() }
        try await fixtures.prepare()
        for scene in SnapshotScene.allCases {
            let controller = SnapshotWorkbench(scene: scene, fixtures: fixtures)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 960),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: 1440, height: 960)
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            controller.view.layoutSubtreeIfNeeded()
            let tables = Self.views(in: controller.view).compactMap { $0 as? NSTableView }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
            for table in tables {
                XCTAssertGreaterThan(table.numberOfRows, 0, "\(scene.rawValue) lost its fixture rows")
                XCTAssertGreaterThan(table.frame.width, 80, "\(scene.rawValue) table has no usable document width")
                // Analytics legitimately places its model table below the
                // initial scroll viewport; inspector/container rows start onscreen.
                if scene != .agenticUse {
                    XCTAssertGreaterThan(table.visibleRect.width, 80, "\(scene.rawValue) table is clipped out of its viewport")
                    XCTAssertGreaterThan(table.visibleRect.height, 20, "\(scene.rawValue) table has no visible rows")
                }
            }
            let names = Self.viewClassNames(in: controller.view)
            XCTAssertTrue(names.count > 8, "\(scene.rawValue) unexpectedly has no presentation content")
            XCTAssertTrue(names.filter(Self.isForbiddenHost).isEmpty,
                          "\(scene.rawValue) contains a SwiftUI host: \(names.filter(Self.isForbiddenHost))")
            switch scene {
            case .docker:
                XCTAssertTrue(controller.children.contains { $0 is DockerViewController })
            case .runners:
                XCTAssertTrue(controller.children.contains { $0 is RunnersViewController })
            case .notes:
                XCTAssertTrue(names.contains { $0.hasSuffix(".NoteTextView") })
            case .agenticUse:
                XCTAssertTrue(names.contains { $0.hasSuffix(".AgenticUseDashboard") })
            default:
                break
            }
            if scene.inspector != nil {
                XCTAssertTrue(controller.children.contains { $0 is InspectorViewController },
                              "Inspector scenes must use the production native inspector")
            }
            for child in controller.children {
                let frame = controller.view.convert(child.view.bounds, from: child.view)
                XCTAssertEqual(frame.maxX, controller.view.bounds.maxX, accuracy: 1,
                               "\(scene.rawValue) must fill the capture width instead of using an intrinsic column width")
            }
            window.contentView = nil
            window.close()
        }
    }

    func testBoundaryDistinguishesSystemAppKitControlsFromSwiftUIHosts() {
        XCTAssertTrue(Self.isForbiddenHost("SwiftUI.NSHostingView<Content>"))
        XCTAssertTrue(Self.isForbiddenHost("SwiftUI.NSHostingController<Content>"))
        XCTAssertTrue(Self.isForbiddenHost("CodeEditSourceEditor.FindPanelHostingView"))
        XCTAssertFalse(Self.isForbiddenHost("_TtGC6AppKit18_NSCoreHostingViewVS_12AppKitButton_"))
        XCTAssertFalse(Self.isForbiddenHost("AppKit.NSButton"))
    }

    @MainActor
    private static func viewClassNames(in root: NSView) -> [String] {
        views(in: root).map { NSStringFromClass(type(of: $0)) }
    }

    @MainActor
    private static func views(in root: NSView) -> [NSView] {
        var pending = [root]
        var result: [NSView] = []
        while let view = pending.popLast() {
            result.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    private static func isForbiddenHost(_ name: String) -> Bool {
        // AppKit itself implements some native controls with _NSCoreHostingView.
        // Those are system controls, not application-owned SwiftUI presentation.
        name.contains("NSHostingView") || name.contains("NSHostingController")
            || name.hasSuffix(".FindPanelHostingView")
    }
}
