import Testing
@testable import Pilot

@Suite("Cockpit window title")
@MainActor
struct CockpitWindowTitleTests {
    @Test("Main surface title is only the workspace name")
    func mainSurfaceOmitsAppName() {
        let title = CockpitWindowController.windowTitle(workspaceName: "made", surface: .main)
        #expect(title == "made")
        #expect(!title.contains("Cockpit"))
    }

    @Test("Extension surface keeps the Extendo suffix")
    func extensionSurfaceKeepsExtendoSuffix() {
        #expect(CockpitWindowController.windowTitle(workspaceName: "made", surface: .extension) == "made — Extendo")
    }
}
