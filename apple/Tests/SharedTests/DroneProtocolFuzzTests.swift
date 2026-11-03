import Foundation
import XCTest
@testable import Copilot

final class DroneProtocolFuzzTests: XCTestCase {
    func testMalformedAndOversizedInputsStayBounded() {
        var state: UInt64 = 0xD303
        func randomByte() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        }
        for index in 0..<500 {
            let length = index * 7_919 % 2_048
            let data = Data((0..<length).map { _ in randomByte() })
            _ = try? DroneProtocolCodec.decode(data)
            var decoder = DroneWire.StreamDecoder()
            _ = decoder.append(data)
        }
    }

    func testOversizedFramePrefixFailsWithoutAllocation() {
        var decoder = DroneWire.StreamDecoder()
        let result = decoder.append(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        guard case .failure(let error) = result else {
            return XCTFail("Expected an oversized frame to fail")
        }
        XCTAssertEqual(error, .messageTooLarge)
    }

    func testReplayedAndOutOfOrderTrafficIsRejected() {
        var replay = ReplayWindow(size: 2)
        XCTAssertTrue(replay.accept(1))
        XCTAssertFalse(replay.accept(1))
        XCTAssertTrue(replay.accept(2))
        XCTAssertFalse(replay.accept(1))
        XCTAssertTrue(replay.accept(3))
        XCTAssertFalse(replay.accept(2))
    }
}
