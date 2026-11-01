import Testing
@testable import Pilot

@Suite("Simulator runtime names")
struct SimctlRuntimeNameTests {
    private static let prefix = "com.apple.CoreSimulator.SimRuntime."

    @Test
    func generalRuntimesKeepTheirShortName() {
        #expect(SimctlBridge.runtimeDisplayName(Self.prefix + "iOS-26-4") == "iOS 26.4")
        #expect(SimctlBridge.runtimeDisplayName(Self.prefix + "watchOS-11-0") == "watchOS 11.0")
    }

    @Test
    func deviceSpecificRuntimesShowTheirHardwareVariant() {
        #expect(SimctlBridge.runtimeDisplayName(Self.prefix + "iOS-27-2-iPhone19-4") == "iOS 27.2 (iPhone19,4)")
    }

    @Test
    func sortKeysOrderNumericallyAndKeepVariantsDistinct() {
        let older = SimctlBridge.runtimeSortKey(Self.prefix + "iOS-9-0")
        let general = SimctlBridge.runtimeSortKey(Self.prefix + "iOS-27-2")
        let variant = SimctlBridge.runtimeSortKey(Self.prefix + "iOS-27-2-iPhone19-4")
        #expect(older < general)
        #expect(general != variant)
        #expect(general < variant)
    }
}
