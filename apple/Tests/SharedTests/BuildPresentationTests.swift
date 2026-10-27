import SwiftUI
import UIKit
import XCTest
@testable import Copilot

final class BuildPresentationTests: XCTestCase {
    @MainActor
    func testBuildCardsAndPickerRender() async throws {
        let now = Date().timeIntervalSince1970
        let run = BuildWorkflowRun(workspaceID: UUID(), workspaceName: "made", repository: "blau/made", runID: 123,
                                   attempt: 2, branch: "feature/build-monitor", workflow: "Apple builds", title: "Build monitoring",
                                   state: BuildActivityState(status: "in_progress", startedAt: now - 154, checkedAt: now))
        for scheme in [ColorScheme.light, .dark] {
            for status in ["in_progress", "success", "failure", "delayed"] {
                var state = run.state
                if ["success", "failure"].contains(status) {
                    state.status = "completed"
                    state.conclusion = status
                    state.finishedAt = now
                }
                let card = BuildActivityCard(attributes: BuildActivityAttributes(run: run), state: state, isStale: status == "delayed")
                    .frame(width: 370).background(Color(uiColor: .secondarySystemBackground))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: card)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertGreaterThan(image.size.height, 70)
                XCTAssertLessThan(image.size.height, 160)
                attach(image, name: "Build-\(status)-\(scheme)")
            }
        }

        let monitor = BuildActivityController()
        monitor.receive([run])
        let view = BuildMonitorView(monitor: monitor, connected: true).environment(\.colorScheme, .dark)
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        attach(image, name: "Build-picker-dark")
        window.isHidden = true
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
