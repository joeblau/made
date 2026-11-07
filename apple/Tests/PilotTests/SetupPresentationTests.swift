import AppKit
import Sparkle
import XCTest
@testable import Pilot

/// Render the native setup hierarchy with live checks disabled. The fixture
/// uses isolated preferences and cannot probe tools or request permissions.
final class SetupPresentationTests: XCTestCase {
    @MainActor
    func testSetupPagesRenderInBothAppearances() async throws {
        let suite = "SetupPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = SetupProgress(defaults: defaults)
        let updater = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let size = SetupViewController.windowSize
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for step in SetupStep.allCases {
                progress.step = step
                let controller = SetupViewController(
                    progress: progress, updater: updater.updater,
                    runsChecks: false, defaults: defaults, onFinish: { _ in XCTFail("Rendering must not finish setup") }
                )
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearanceName)
                window.contentViewController = controller
                let content = controller.view
                content.frame = window.contentLayoutRect
                content.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                content.displayIfNeeded()
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let image = NSImage(size: content.bounds.size)
                image.addRepresentation(bitmap)
                XCTAssertEqual(content.bounds.size, size)
                XCTAssertFalse(containsHostingView(content), "Setup must not embed a SwiftUI hosting hierarchy")
                XCTAssertFalse(containsHostingController(controller), "Setup must not embed a SwiftUI hosting controller")
                let attachment = XCTAttachment(image: image)
                attachment.name = "Setup-\(step)-\(appearanceName.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.close()
            }
        }
        XCTAssertTrue(progress.needsInitialSetup)
        XCTAssertNil(defaults.object(forKey: SetupProgress.completionKey))
        XCTAssertNil(defaults.object(forKey: SetupProgress.companionsKey))
    }

    @MainActor
    func testToolStatusUpdatesPreserveFocusedSetupActionsAndSidebarFocus() async throws {
        let suite = "SetupFocusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = SetupProgress(defaults: defaults)
        progress.step = .tools
        var gitChecks = 0
        let tools = SetupTools { tool in
            await Task.yield()
            guard tool.id == "git" else { return false }
            gitChecks += 1
            return gitChecks.isMultiple(of: 2)
        }
        let updater = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let controller = SetupViewController(
            progress: progress, updater: updater.updater, runsChecks: false,
            defaults: defaults, tools: tools, onFinish: { _ in XCTFail("Status updates must not finish setup") }
        )
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SetupViewController.windowSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.viewWillAppear()
        defer {
            controller.viewWillDisappear()
            window.close()
        }

        for identifier in ["setup.navigation.continue", "setup.tool.tmux.instructions", "setup.step.0"] {
            let previous = try XCTUnwrap(button(identifier, in: controller.view))
            XCTAssertTrue(window.makeFirstResponder(previous), "The action must be keyboard focusable")
            await tools.refresh()
            for _ in 0..<4 { await Task.yield() }
            let current = try XCTUnwrap(button(identifier, in: controller.view))
            XCTAssertTrue(window.firstResponder === current, "Unrelated tool status updates moved focus from \(identifier)")
        }
        XCTAssertEqual(gitChecks, 3)
        XCTAssertTrue(progress.needsInitialSetup)
    }

    @MainActor
    private func button(_ identifier: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
        for child in view.subviews {
            if let button = button(identifier, in: child) { return button }
        }
        return nil
    }

    @MainActor
    private func containsHostingView(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).contains("NSHostingView")
            || view.subviews.contains(where: containsHostingView)
    }

    @MainActor
    private func containsHostingController(_ controller: NSViewController) -> Bool {
        NSStringFromClass(type(of: controller)).contains("NSHostingController")
            || controller.children.contains(where: containsHostingController)
    }
}
