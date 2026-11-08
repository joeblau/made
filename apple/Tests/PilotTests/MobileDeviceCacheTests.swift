import Foundation
import Testing
@testable import Pilot

@MainActor
@Suite("Mobile device cache", .serialized)
struct MobileDeviceCacheTests {
    @Test("New pickers open with the last known simulators and devices instead of an empty search")
    func sessionsSeedFromCache() {
        let cache = MobileDeviceCache.shared
        defer { cache.reset() }
        let phone = SimDevice(udid: "UDID", name: "iPhone 17", state: "Booted", deviceTypeIdentifier: nil,
                              runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0")
        let group = SimRuntimeGroup(id: phone.runtimeIdentifier, displayName: "iOS 26.0", sortKey: "26.0", devices: [phone])
        let seeker = AndroidDevice(serial: "SM02G4061986593", state: .device, model: "Seeker", product: "seeker")
        let emulator = AndroidDevice(serial: "emulator-5554", state: .device, model: "sdk_gphone64_arm64", product: nil)
        let iPhone = IOSCaptureDevice(id: "usb-iphone", name: "iPhone", modelID: "iPhone18,1")
        cache.record(simulators: [group])
        cache.record(androidDevices: [seeker, emulator])
        cache.record(appleDevices: [iPhone])

        #expect(SimulatorSession().devices == [group])
        #expect(AndroidDeviceSession(target: .device).devices == [seeker], "Physical devices only on the Device page")
        #expect(AndroidDeviceSession(target: .simulator).devices == [emulator])
        #expect(DeviceCaptureSession(paneID: UUID()).devices == [iPhone])
        #expect(DeviceCaptureSession(paneID: UUID(), deviceDiscovery: {
            DeviceCaptureSession.DiscoveryResult(attached: [], options: [])
        }).devices.isEmpty, "Injected discovery never reads the shared cache")
    }

    @Test("Before any scan, pickers start empty")
    func emptyCache() {
        MobileDeviceCache.shared.reset()
        #expect(SimulatorSession().devices.isEmpty)
        #expect(AndroidDeviceSession(target: .device).devices.isEmpty)
    }
}
