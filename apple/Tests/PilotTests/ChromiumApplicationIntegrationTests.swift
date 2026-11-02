import AppKit
@preconcurrency import ChromiumKit
import Testing
@testable import Pilot

/// SwiftUI's App lifecycle instantiates its own `NSApplication` subclass, so
/// CEF's `CefAppProtocol` has to be added to that class at runtime. Without it
/// Chromium's message pump calls `-[NSApp isHandlingSendEvent]` and the app
/// dies with an unrecognized selector (the wallet popup crash).
@Suite("Chromium application integration")
@MainActor
struct ChromiumApplicationIntegrationTests {
    private typealias IsHandling = @convention(c) (AnyObject, Selector) -> Bool
    private typealias SetHandling = @convention(c) (AnyObject, Selector, Bool) -> Void

    private let isHandlingSelector = Selector(("isHandlingSendEvent"))
    private let setHandlingSelector = Selector(("setHandlingSendEvent:"))

    @Test("NSApp gains CefAppProtocol only when CEF is linked")
    func applicationProtocolFollowsTheRuntime() throws {
        let application = try #require(NSApp)
        let installed = ChromiumEngine.installApplicationIntegration()
        guard ChromiumEngine.shared.isRuntimeAvailable else {
            // Debug and Release link the stub bridge: NSApp stays untouched.
            #expect(!installed)
            #expect(!application.responds(to: isHandlingSelector))
            #expect(!application.responds(to: setHandlingSelector))
            return
        }
        #expect(installed)
        // Idempotent: the launch-time call and the engine's own call both run.
        #expect(ChromiumEngine.installApplicationIntegration())
        #expect(application.responds(to: isHandlingSelector))
        #expect(application.responds(to: setHandlingSelector))

        let isHandling = unsafeBitCast(application.method(for: isHandlingSelector), to: IsHandling.self)
        let setHandling = unsafeBitCast(application.method(for: setHandlingSelector), to: SetHandling.self)
        let original = isHandling(application, isHandlingSelector)
        setHandling(application, setHandlingSelector, true)
        #expect(isHandling(application, isHandlingSelector))
        setHandling(application, setHandlingSelector, original)
        #expect(isHandling(application, isHandlingSelector) == original)
    }

    @Test("Quitting waits for a live engine and ignores repeated requests")
    func terminationPolicy() {
        for state in [ChromiumEngineState.notStarted, .failed, .shutDown] {
            #expect(ChromiumTerminationPolicy.decision(engineState: state, shutdownPending: false) == .terminateNow)
            #expect(ChromiumTerminationPolicy.decision(engineState: state, shutdownPending: true) == .terminateNow)
        }
        for state in [ChromiumEngineState.initializing, .running, .shuttingDown] {
            #expect(ChromiumTerminationPolicy.decision(engineState: state, shutdownPending: false) == .shutDownFirst)
            #expect(ChromiumTerminationPolicy.decision(engineState: state, shutdownPending: true) == .alreadyPending)
        }
        // The re-issued quit after shutdown (or its timeout) always goes through.
        #expect(ChromiumTerminationPolicy.decision(
            engineState: .shuttingDown, shutdownPending: false, shutdownFinished: true
        ) == .terminateNow)
        // A logout must not be cancelled by Cockpit waiting on CEF.
        #expect(ChromiumTerminationPolicy.decision(
            engineState: .running, shutdownPending: false, systemPoweringOff: true
        ) == .terminateNow)
        #expect(ChromiumTerminationPolicy.shutdownTimeout > .zero)
    }
}
