import XCTest

/// fastlane snapshot UI tests for Copilot (iPhone).
///
/// Runs against demo mode (`-demoMode YES`), which injects representative
/// fixture state so the screens render without a live Pilot peer on the
/// network. See the Foundation harness / DEMO-MODE convention.
/// Main-actor isolated like PlotterUITests: fastlane's `setupSnapshot` and
/// `snapshot` helpers are `@MainActor`, so Swift 6 rejects calling them from
/// a nonisolated test class.
@MainActor
final class CopilotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSnapshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["-demoMode", "YES"]
        app.launch()

        // Primary screen: the workspace list.
        snapshot("01-Workspaces")
    }
}
