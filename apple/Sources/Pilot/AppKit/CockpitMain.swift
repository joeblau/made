import AppKit

@main
enum CockpitMain {
    @MainActor
    static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--cockpit-fixture") || UserDefaults.standard.bool(forKey: "demoMode") {
            setenv("BLAU_COCKPIT_FIXTURE", "1", 1)
        }
        let application = NSApplication.shared
        let delegate = PilotAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
