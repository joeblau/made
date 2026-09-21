// Swift-interface Fastfile for the made screenshot harness.
//
// fastlane is iOS-only here, so it captures the two iOS apps:
//   - Copilot (iPhone 16 Pro)
//   - Plotter (iPad Pro 13-inch (M4))
//
// Pilot (macOS) and Wingman (watchOS) are captured by the shell scripts in
// apple/bin/ instead.
//
// Every app implements the DEMO-MODE convention: launching with the argument
// pair ["-demoMode", "YES"] flips UserDefaults `demoMode` to true and the app
// renders representative fixture state with no live peer on the network. The
// UI-test bundles (CopilotUITests / PlotterUITests) inject that launch arg, so
// captureScreenshots only needs to point at the right scheme + device.
//
// Output lands in workers/web/public/screenshots/<app>/ so the landing page can ship
// the images directly.
//
// Usage (from apple/):
//   fastlane snapshotCopilot
//   fastlane snapshotPlotter
//   fastlane snapshotAll

import Foundation

class Fastfile: LaneFile {
    func snapshotCopilotLane() {
        desc("Capture Copilot (iPhone) screenshots in demo mode")
        captureScreenshots(
            project: .userDefined("made.xcodeproj"),
            devices: .userDefined(["iPhone 16 Pro"]),
            outputDirectory: "../workers/web/public/screenshots/copilot",
            reinstallApp: .userDefined(true),
            clean: .userDefined(true),
            scheme: .userDefined("Copilot"),
            disableSlideToType: .userDefined(true)
        )
    }

    func snapshotPlotterLane() {
        desc("Capture Plotter (iPad) screenshots in demo mode")
        captureScreenshots(
            project: .userDefined("made.xcodeproj"),
            devices: .userDefined(["iPad Pro 13-inch (M4)"]),
            outputDirectory: "../workers/web/public/screenshots/plotter",
            reinstallApp: .userDefined(true),
            clean: .userDefined(true),
            scheme: .userDefined("Plotter"),
            disableSlideToType: .userDefined(true)
        )
    }

    func snapshotAllLane() {
        desc("Capture screenshots for both iOS apps (Copilot + Plotter)")
        snapshotCopilotLane()
        snapshotPlotterLane()
    }
}
