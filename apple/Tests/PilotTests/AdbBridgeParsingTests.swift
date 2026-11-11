import CoreGraphics
import Foundation
import Testing
@testable import Pilot

/// Every parser that touches adb output, plus the input-command escaping —
/// the surfaces where an adversarial device or adb server meets Pilot.
@Suite("AdbBridge parsing and input escaping")
struct AdbBridgeParsingTests {
    // MARK: - adb devices -l

    @Test
    func parsesDeviceListWithMetadata() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:2
        R5CT10XXXX             unauthorized usb:1-1 transport_id:3
        192.168.1.20:5555      offline product:raven model:Pixel_6_Pro transport_id:4

        """
        let devices = AdbBridge.parseDevicesOutput(output)
        #expect(devices.count == 3)

        let emulator = devices.first { $0.serial == "emulator-5554" }
        #expect(emulator?.state == .device)
        #expect(emulator?.model == "sdk_gphone64_arm64")
        #expect(emulator?.isEmulator == true)
        #expect(emulator?.displayName == "sdk gphone64 arm64")

        #expect(devices.first { $0.serial == "R5CT10XXXX" }?.state == .unauthorized)
        #expect(devices.first { $0.serial == "192.168.1.20:5555" }?.state == .offline)
        // Connectable devices sort first.
        #expect(devices[0].serial == "emulator-5554")
    }

    @Test
    func parsesEmulatorConsoleAVDNameWithCRLF() {
        #expect(AdbBridge.parseAVDNameOutput("Pixel_9_API_36\r\nOK\r\n") == "Pixel_9_API_36")
        #expect(AdbBridge.parseAVDNameOutput("Pixel_9_API_36\nOK\n") == "Pixel_9_API_36")
        #expect(AdbBridge.parseAVDNameOutput("OK\r\n") == nil)
        #expect(AdbBridge.parseAVDNameOutput("") == nil)
        #expect(AdbBridge.parseAVDNameOutput("Pixel 9; rm -rf\r\nOK\r\n") == nil)
    }

    @Test
    func androidPaneTargetsSeparateSimulatorsAndDevices() {
        let simulator = AndroidDevice(
            serial: "emulator-5554",
            state: .device,
            model: "sdk_gphone64_arm64",
            product: nil
        )
        let device = AndroidDevice(
            serial: "R5CT10XXXX",
            state: .device,
            model: "Pixel_9",
            product: nil
        )

        #expect(AndroidPaneTarget.simulator.includes(simulator))
        #expect(!AndroidPaneTarget.simulator.includes(device))
        #expect(AndroidPaneTarget.device.includes(device))
        #expect(!AndroidPaneTarget.device.includes(simulator))
    }

    @Test
    func ignoresNoiseBeforeHeaderAndUnknownStates() {
        let output = """
        adb server version (41) doesn't match this client
        List of devices attached
        SERIAL1 recovery
        SERIAL2 device
        """
        let devices = AdbBridge.parseDevicesOutput(output)
        #expect(devices.count == 2)
        #expect(devices.first { $0.serial == "SERIAL1" }?.state == .other)
        #expect(devices.first { $0.serial == "SERIAL1" }?.isConnectable == false)
    }

    @Test
    func boundsDeviceCountAndRejectsHostileSerials() {
        var output = "List of devices attached\n"
        for index in 0..<200 {
            output += "serial\(index) device\n"
        }
        output += "bad;rm$(x) device\n"
        let devices = AdbBridge.parseDevicesOutput(output)
        #expect(devices.count == 64)
        #expect(!devices.contains { $0.serial.contains(";") })
    }

    @Test
    func serialValidation() {
        #expect(AdbBridge.isValidSerial("emulator-5554"))
        #expect(AdbBridge.isValidSerial("192.168.1.20:5555"))
        #expect(AdbBridge.isValidSerial("R5CT10ABC.DE_F"))
        #expect(!AdbBridge.isValidSerial(""))
        #expect(!AdbBridge.isValidSerial(String(repeating: "a", count: 129)))
        #expect(!AdbBridge.isValidSerial("has space"))
        #expect(!AdbBridge.isValidSerial("dollar$ign"))
    }

    // MARK: - wm size

    @Test
    func parsesPhysicalAndOverrideSizes() {
        #expect(AdbBridge.parseWindowSize("Physical size: 1080x2400\n") == CGSize(width: 1_080, height: 2_400))
        let overridden = """
        Physical size: 1080x2400
        Override size: 720x1600
        """
        #expect(AdbBridge.parseWindowSize(overridden) == CGSize(width: 720, height: 1_600))
        #expect(AdbBridge.parseWindowSize("garbage") == nil)
        #expect(AdbBridge.parseWindowSize("Physical size: 0x2400") == nil)
        #expect(AdbBridge.parseWindowSize("Physical size: 99999x2400") == nil)
    }

    @Test
    func capsStreamSizeToEvenDimensions() {
        let capped = AdbBridge.cappedStreamSize(native: CGSize(width: 1_080, height: 2_400), longEdge: 1_600)
        #expect(capped == CGSize(width: 720, height: 1_600))
        // Under the cap: only even-rounding applies.
        let small = AdbBridge.cappedStreamSize(native: CGSize(width: 719, height: 1_599), longEdge: 1_600)
        #expect(Int(small.width) % 2 == 0)
        #expect(Int(small.height) % 2 == 0)
    }

    // MARK: - rotation watch

    @Test
    func parsesRotationLines() {
        #expect(AdbBridge.parseRotationLine("rotation=0") == 0)
        #expect(AdbBridge.parseRotationLine("rotation=3\r\n") == 3)
        #expect(AdbBridge.parseRotationLine("rotation=4") == nil)
        #expect(AdbBridge.parseRotationLine("rotation=") == nil)
        #expect(AdbBridge.parseRotationLine("mCurrentRotation=1") == nil)
        #expect(AdbBridge.parseRotationLine("") == nil)
    }

    // MARK: - input command construction

    @Test
    func clampsCoordinatesAndDurations() {
        #expect(AndroidInputCommand.tap(x: -5, y: 40_000).line == "input tap 0 32767")
        #expect(AndroidInputCommand.swipe(fromX: 1, fromY: 2, toX: 3, toY: 4, durationMS: 8_000).line
            == "input swipe 1 2 3 4 5000")
        #expect(AndroidInputCommand.keyevent(-2).line == "input keyevent 0")
        #expect(AndroidInputCommand.longPress(x: 10, y: 20, durationMS: 700).line
            == "input swipe 10 20 10 20 700")
        #expect(AndroidInputCommand.dragAndDrop(fromX: 1, fromY: 2, toX: 3, toY: 4, durationMS: 500).line
            == "input draganddrop 1 2 3 4 500")
    }

    @Test
    func textEscapingIsAllowlistFirst() {
        let (spaced, droppedSpaces) = AndroidInputCommand.escapeText("hello world")
        #expect(spaced == "hello%sworld")
        #expect(droppedSpaces == 0)

        // Shell metacharacters are dropped, never escaped-through.
        let hostile = "a'b\"c`d$e\\f%g\nh€i"
        let (escaped, dropped) = AndroidInputCommand.escapeText(hostile)
        #expect(escaped == "abcdefgh" + "i")
        #expect(dropped == 8)
        #expect(!escaped.contains("'"))
        #expect(!escaped.contains("$"))
        #expect(!escaped.contains("%") || escaped.contains("%s"))

        let (command, _) = AndroidInputCommand.text("ok then")
        #expect(command?.line == "input text 'ok%sthen'")

        let (empty, emptyDropped) = AndroidInputCommand.text("€€€")
        #expect(empty == nil)
        #expect(emptyDropped == 3)
    }

    @Test
    func textIsCappedAt256Characters() {
        let long = String(repeating: "a", count: 300)
        let (escaped, dropped) = AndroidInputCommand.escapeText(long)
        #expect(escaped.count == 256)
        #expect(dropped == 44)
    }

    // MARK: - input shell lifecycle

    /// #445: writing to an input shell whose adb already exited (device went
    /// offline, `adb kill-server`) must fail with a catchable EPIPE. Without
    /// F_SETNOSIGPIPE the write raises SIGPIPE, which kills the test host just
    /// as it kills Cockpit.
    @Test
    func writesToDeadInputShellFailWithoutSIGPIPE() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Stands in for `adb -s <serial> shell`: closes its stdin at once but
        // stays alive, so `isRunning` is still true when each write lands.
        let deadStdin = directory.appendingPathComponent("dead-stdin-adb")
        try Data("#!/bin/sh\nexec 0<&-\nexec sleep 30\n".utf8).write(to: deadStdin)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deadStdin.path)

        let injector = AndroidInputInjector(adbURL: deadStdin, serial: "emulator-5554")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await injector.failedWriteCount < 3, ContinuousClock.now < deadline {
            for index in 0..<16 {
                await injector.send(.tap(x: index, y: index))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await injector.shutdown()
        #expect(await injector.failedWriteCount >= 3)

        // A shell that exits immediately races `isRunning` against every
        // write; a burst of commands must not take the process down either.
        let exiting = directory.appendingPathComponent("exiting-adb")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exiting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exiting.path)
        let racing = AndroidInputInjector(adbURL: exiting, serial: "emulator-5554")
        for round in 0..<20 {
            for index in 0..<16 {
                await racing.send(.keyevent(round * 16 + index))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await racing.shutdown()
    }

    // MARK: - gesture classification

    @Test
    func classifiesTapLongPressSwipeAndDrag() {
        let clock = ContinuousClock()
        let start = clock.now

        var tap = AndroidGestureClassifier()
        tap.began(at: CGPoint(x: 100, y: 100), time: start)
        #expect(tap.ended(at: CGPoint(x: 102, y: 101), time: start.advanced(by: .milliseconds(80)))
            == .tap(x: 100, y: 100))

        var longPress = AndroidGestureClassifier()
        longPress.began(at: CGPoint(x: 50, y: 60), time: start)
        #expect(longPress.ended(at: CGPoint(x: 51, y: 60), time: start.advanced(by: .milliseconds(600)))
            == .longPress(x: 50, y: 60, durationMS: 600))

        var swipe = AndroidGestureClassifier()
        swipe.began(at: CGPoint(x: 100, y: 500), time: start)
        swipe.moved(to: CGPoint(x: 100, y: 300), time: start.advanced(by: .milliseconds(50)))
        #expect(swipe.ended(at: CGPoint(x: 100, y: 100), time: start.advanced(by: .milliseconds(150)))
            == .swipe(fromX: 100, fromY: 500, toX: 100, toY: 100, durationMS: 150))

        var drag = AndroidGestureClassifier()
        drag.began(at: CGPoint(x: 200, y: 200), time: start)
        drag.moved(to: CGPoint(x: 201, y: 200), time: start.advanced(by: .milliseconds(100)))
        drag.moved(to: CGPoint(x: 400, y: 200), time: start.advanced(by: .milliseconds(600)))
        let gesture = drag.ended(at: CGPoint(x: 400, y: 400), time: start.advanced(by: .milliseconds(1_100)))
        #expect(gesture == .dragAndDrop(fromX: 200, fromY: 200, toX: 400, toY: 400, durationMS: 500))
    }

    @Test
    func gestureWithoutBeginIsIgnored() {
        var classifier = AndroidGestureClassifier()
        #expect(classifier.ended(at: .zero) == nil)
    }

    // MARK: - pane presentation lifecycle

    @Test
    func presentationActivityWaitsForTheLastWindowToDepart() {
        var activity = AndroidPaneActivityState()
        let main = UUID()
        let extensionWindow = UUID()

        let mainActivatedThePane = activity.activate(main)
        let extensionReusedTheActivePane = activity.activate(extensionWindow)
        #expect(mainActivatedThePane)
        #expect(!extensionReusedTheActivePane)
        #expect(activity.isActive)
        let mainDepartureSuspends = activity.deactivate(main)
        #expect(!mainDepartureSuspends)
        #expect(activity.isActive)
        let finalDepartureSuspends = activity.deactivate(extensionWindow)
        #expect(finalDepartureSuspends)
        #expect(!activity.isActive)
    }

    // MARK: - restart policy

    @Test
    func policyRestartsHealthyStreamsWithoutStrikes() {
        var policy = AndroidStreamPolicy()
        #expect(policy.firstAttempt == AndroidStreamPolicy.Attempt(longEdgeCap: 1_600, timeLimitZero: true))
        // The 180 s cap / rotation exits after a healthy runtime: same params.
        for _ in 0..<10 {
            let decision = policy.nextDecision(runtime: .seconds(180), diagnostics: "")
            #expect(decision == .restart(AndroidStreamPolicy.Attempt(longEdgeCap: 1_600, timeLimitZero: true)))
        }
    }

    @Test
    func policyLaddersDownOnInstantExits() {
        var policy = AndroidStreamPolicy()
        // Old screenrecord rejecting --time-limit 0 exits instantly.
        let second = policy.nextDecision(runtime: .milliseconds(200), diagnostics: "bad time limit")
        #expect(second == .restart(AndroidStreamPolicy.Attempt(longEdgeCap: 1_600, timeLimitZero: false)))
        // An encoder that rejects the size exits instantly again.
        let third = policy.nextDecision(runtime: .milliseconds(200), diagnostics: "encoder")
        #expect(third == .restart(AndroidStreamPolicy.Attempt(longEdgeCap: 1_280, timeLimitZero: false)))
        // Fourth quick death in a row: give up with the diagnostics.
        _ = policy.nextDecision(runtime: .milliseconds(200), diagnostics: "still dying")
        let fifth = policy.nextDecision(runtime: .milliseconds(200), diagnostics: "still dying")
        #expect(fifth == .fail("still dying"))
    }

    @Test
    func policyCurrentAttemptKeepsTheLearnedRung() {
        var policy = AndroidStreamPolicy()
        #expect(policy.currentAttempt == policy.firstAttempt)
        // A pre-Android-10 device rejects --time-limit 0 instantly; a manual
        // restart (rotation, record-start) must reuse the learned rung, not
        // re-spawn a doomed first-rung child.
        _ = policy.nextDecision(runtime: .milliseconds(200), diagnostics: "")
        #expect(policy.currentAttempt == AndroidStreamPolicy.Attempt(longEdgeCap: 1_600, timeLimitZero: false))
    }

    @Test
    func policyRecoversStrikesAfterHealthyRuntime() {
        var policy = AndroidStreamPolicy()
        _ = policy.nextDecision(runtime: .milliseconds(200), diagnostics: "")
        _ = policy.nextDecision(runtime: .milliseconds(200), diagnostics: "")
        // A long healthy run clears the strike count…
        _ = policy.nextDecision(runtime: .seconds(60), diagnostics: "")
        // …so the next few quick deaths don't immediately give up.
        let decision = policy.nextDecision(runtime: .seconds(3), diagnostics: "")
        guard case .restart = decision else {
            Issue.record("expected restart, got \(decision)")
            return
        }
    }

    // MARK: - key map

    @Test
    func keyMapCoversNavigationKeys() {
        #expect(AndroidKeyMap.androidKeycode(forMacKeyCode: 36) == AndroidKeyMap.Keycode.enter)
        #expect(AndroidKeyMap.androidKeycode(forMacKeyCode: 51) == AndroidKeyMap.Keycode.del)
        #expect(AndroidKeyMap.androidKeycode(forMacKeyCode: 53) == AndroidKeyMap.Keycode.back)
        #expect(AndroidKeyMap.androidKeycode(forMacKeyCode: 126) == AndroidKeyMap.Keycode.dpadUp)
        // Printable keys are not in the table — they go through `input text`.
        #expect(AndroidKeyMap.androidKeycode(forMacKeyCode: 0) == nil)  // 'a'
    }
}
