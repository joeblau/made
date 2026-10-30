import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import Pilot

/// Keep rendered setup pages in the test result for visual review. Live checks
/// are disabled so rendering cannot probe tools or request system permissions.
final class SetupPresentationTests: XCTestCase {
    @MainActor
    func testSetupPagesRenderInBothAppearances() async throws {
        let suite = "SetupPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = SetupProgress(defaults: defaults)
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let size = SetupView.windowSize
        for colorScheme in [ColorScheme.light, .dark] {
            for step in SetupStep.allCases {
                progress.step = step
                let content = SetupView(
                    progress: progress, updater: controller.updater,
                    onFinish: { _ in }, runsChecks: false
                )
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, colorScheme)
                // ImageRenderer omits NSScrollView content. Cache the actual
                // AppKit hosting hierarchy to capture the complete page.
                let host = NSHostingView(rootView: content)
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: colorScheme == .light ? .aqua : .darkAqua)
                window.contentView = host
                host.frame = window.contentLayoutRect
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = NSImage(size: host.bounds.size)
                image.addRepresentation(bitmap)
                XCTAssertEqual(host.bounds.size, size)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Setup-\(step)-\(colorScheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.close()
            }
        }
        XCTAssertTrue(progress.needsInitialSetup)
        XCTAssertNil(defaults.object(forKey: SetupProgress.completionKey))
    }
}
