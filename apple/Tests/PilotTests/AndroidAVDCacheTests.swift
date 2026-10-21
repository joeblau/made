import Foundation
import Testing
@testable import Pilot

/// The serial→AVD-name cache step behind the Android Simulator picker's 2 s
/// poll. Correlating a serial costs one `adb emu avd name` subprocess, so the
/// step must query each running emulator exactly once — while still evicting
/// stale serials, because adb reuses `emulator-55xx` serials across instances.
@Suite("AndroidDeviceSession AVD-name cache")
struct AndroidAVDCacheTests {
    @Test
    func cachedSerialsAreNotReQueried() {
        var queried: [String] = []
        let updated = AndroidDeviceSession.updatedAVDNames(
            cached: ["emulator-5554": "Pixel_7_API_34"],
            runningSerials: ["emulator-5554", "emulator-5556"],
            query: { serial in
                queried.append(serial)
                return "Medium_Phone_API_35"
            }
        )
        #expect(queried == ["emulator-5556"])
        #expect(updated == [
            "emulator-5554": "Pixel_7_API_34",
            "emulator-5556": "Medium_Phone_API_35",
        ])
    }

    @Test
    func evictsSerialsNoLongerRunning() {
        // emulator-5554 stopped; its serial can be reused by a different AVD,
        // so the stale mapping must not survive into the next scan.
        let updated = AndroidDeviceSession.updatedAVDNames(
            cached: ["emulator-5554": "Pixel_7_API_34", "emulator-5556": "Medium_Phone_API_35"],
            runningSerials: ["emulator-5556"],
            query: { _ in
                Issue.record("running serials were already cached; nothing should be queried")
                return nil
            }
        )
        #expect(updated == ["emulator-5556": "Medium_Phone_API_35"])
    }

    @Test
    func failedQueryStaysUncachedAndIsRetried() {
        var attempts = 0
        let first = AndroidDeviceSession.updatedAVDNames(
            cached: [:],
            runningSerials: ["emulator-5554"],
            query: { _ in
                attempts += 1
                return nil
            }
        )
        #expect(first.isEmpty)
        let second = AndroidDeviceSession.updatedAVDNames(
            cached: first,
            runningSerials: ["emulator-5554"],
            query: { _ in
                attempts += 1
                return "Pixel_7_API_34"
            }
        )
        #expect(attempts == 2)
        #expect(second == ["emulator-5554": "Pixel_7_API_34"])
    }
}
