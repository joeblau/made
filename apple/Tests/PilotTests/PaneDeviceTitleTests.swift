import Foundation
import Testing
@testable import Pilot

@MainActor
@Suite("Pane device titles")
struct PaneDeviceTitleTests {
    @Test("Capture panes read as a platform breadcrumb ending in the device name")
    func breadcrumbWithName() {
        #expect(PaneDeviceTitle.breadcrumb(kind: .device, androidTarget: .simulator, deviceName: "SR2") == "Device / Apple / SR2")
        #expect(PaneDeviceTitle.breadcrumb(kind: .android, androidTarget: .device, deviceName: "Seeker") == "Device / Android / Seeker")
        #expect(PaneDeviceTitle.breadcrumb(kind: .android, androidTarget: .simulator, deviceName: "Pixel 9") == "Simulator / Android / Pixel 9")
        #expect(PaneDeviceTitle.breadcrumb(kind: .simulator, androidTarget: .simulator, deviceName: "iPhone 17 Pro") == "Simulator / Apple / iPhone 17 Pro")
    }

    @Test("Before a device is chosen the breadcrumb stops at the platform")
    func breadcrumbWithoutName() {
        #expect(PaneDeviceTitle.breadcrumb(kind: .device, androidTarget: .simulator, deviceName: nil) == "Device / Apple")
        #expect(PaneDeviceTitle.breadcrumb(kind: .android, androidTarget: .device, deviceName: nil) == "Device / Android")
        #expect(PaneDeviceTitle.breadcrumb(kind: .android, androidTarget: .simulator, deviceName: "  \n ") == "Simulator / Android")
        #expect(PaneDeviceTitle.breadcrumb(kind: .simulator, androidTarget: .device, deviceName: "") == "Simulator / Apple")
    }

    @Test("Other pane kinds keep their own titles")
    func nonCaptureKinds() {
        for kind in [PaneKind.terminal, .browser, .editor, .agentChat] {
            #expect(PaneDeviceTitle.breadcrumb(kind: kind, androidTarget: .device, deviceName: "SR2") == nil)
        }
    }

    @Test("External device names are trimmed, single-line, and bounded")
    func sanitizesNames() {
        #expect(PaneDeviceTitle.sanitizedName("  Joe's\tiPhone\n") == "Joe's iPhone")
        #expect(PaneDeviceTitle.sanitizedName("SR2\u{0007}\u{0000}x") == "SR2 x")
        let long = String(repeating: "a", count: 500)
        let bounded = PaneDeviceTitle.sanitizedName(long)
        #expect(bounded?.count == PaneDeviceTitle.maximumNameLength)
        #expect(bounded?.hasSuffix("…") == true)
        let exact = String(repeating: "b", count: PaneDeviceTitle.maximumNameLength)
        #expect(PaneDeviceTitle.sanitizedName(exact) == exact)
    }

    @Test("A device pane uses its persisted device choice before its session exists")
    func persistedDeviceName() {
        let pane = Pane(kind: .device)
        let key = DeviceCaptureSession.preferenceNameKey(for: pane.id)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(pane.displayTitle == "Device / Apple")
        UserDefaults.standard.set("  SR2 ", forKey: key)
        #expect(pane.displayTitle == "Device / Apple / SR2")
        #expect(pane.tabTitle == "Device / Apple / SR2")
    }

    @Test("An Android pane's prefix follows its target")
    func androidTarget() {
        let pane = Pane(kind: .android)
        pane.androidTarget = .device
        #expect(pane.displayTitle == "Device / Android")
        pane.androidTarget = .simulator
        #expect(pane.displayTitle == "Simulator / Android")
    }
}
