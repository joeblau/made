import XCTest

/// fastlane snapshot UI tests for Copilot (iPhone).
///
/// Runs against demo mode (`-demoMode YES`), which injects representative
/// fixture state so the screens render without a live Pilot peer on the
/// network. See the Foundation harness / DEMO-MODE convention.
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

        // Best-effort: drill into the first workspace if one is present.
        // Resilient — never fails the run if the cell isn't there yet.
        let firstCell = app.cells.firstMatch
        if firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
            snapshot("02-Workspace-Detail")
        }
    }
}
