import Foundation
import XCTest
@testable import Pilot

final class AirPlayReceiverTests: XCTestCase {
    private func message(_ kind: UInt8, _ payload: [UInt8] = []) -> Data {
        let length = UInt32(payload.count + 1)
        return Data([UInt8(length >> 24), UInt8((length >> 16) & 255),
                     UInt8((length >> 8) & 255), UInt8(length & 255), kind] + payload)
    }

    func testEverySplitInHeaderAndPINIsReassembled() throws {
        let bytes = message(2, Array("0123".utf8))
        for split in 0...bytes.count {
            var decoder = AirPlayPacketDecoder()
            let first = try decoder.append(bytes.prefix(split))
            let second = try decoder.append(bytes.suffix(bytes.count - split))
            XCTAssertEqual(first + second, [AirPlayPacket(kind: .pin, payload: Data("0123".utf8))])
            try decoder.finish()
        }
    }

    func testMultiplePacketsAndByteAtATimeDelivery() throws {
        let bytes = message(1) + message(2, Array("9999".utf8)) + message(5)
        var decoder = AirPlayPacketDecoder()
        var packets: [AirPlayPacket] = []
        for byte in bytes { packets += try decoder.append(Data([byte])) }
        XCTAssertEqual(packets.map(\.kind), [.ready, .pin, .heartbeat])
        try decoder.finish()
    }

    func testRejectsInvalidLengthsKindsAndPINs() {
        let invalid = [Data([0, 0, 0, 0]), Data([255, 255, 255, 255]),
                       message(99), message(1, [0]), message(2, [48, 48]),
                       message(2, Array("abcd".utf8)), message(3), message(7), message(7, [0, 0, 0]),
                       message(7, [0, 0, 0, 0, 0])]
        for bytes in invalid {
            var decoder = AirPlayPacketDecoder()
            XCTAssertThrowsError(try decoder.append(bytes))
        }
    }

    func testTruncatedMessageAtEOFIsRejected() throws {
        var decoder = AirPlayPacketDecoder()
        XCTAssertTrue(try decoder.append(Data([0, 0, 0, 20, 3, 1])).isEmpty)
        XCTAssertThrowsError(try decoder.finish())
    }

    func testDiscoveryErrorSurvivesFragmentation() throws {
        let bytes = message(7, [255, 254, 255, 221]) // DNSService registration not permitted (-65571).
        for split in 0...bytes.count {
            var decoder = AirPlayPacketDecoder()
            let packets = try decoder.append(bytes.prefix(split)) + decoder.append(bytes.suffix(bytes.count - split))
            XCTAssertEqual(packets, [AirPlayPacket(kind: .discoveryFailure, payload: Data([255, 254, 255, 221]))])
            try decoder.finish()
        }
    }

    func testDiscoveryDenialIsReportedBeforeChildExitWithoutHanging() async {
        let worker = shell("printf '\\000\\000\\000\\005\\007\\377\\376\\377\\335'; sleep 2")
        await assertFinishes(worker)
        guard case .failed(let reason) = worker.snapshot else { return XCTFail("Expected discovery denial") }
        XCTAssertTrue(reason.contains("service registration"), reason)
        XCTAssertTrue(reason.contains("-65571"), reason)
    }

    func testLocalNetworkDenialExplainsHowToGrantAccess() async {
        let worker = shell("printf '\\000\\000\\000\\005\\007\\377\\376\\377\\336'; exit 69")
        await assertFinishes(worker)
        guard case .failed(let reason) = worker.snapshot else { return XCTFail("Expected permission denial") }
        XCTAssertTrue(reason.contains("Privacy & Security > Local Network"), reason)
    }

    func testStaleBonjourMetadataReportsRegistrationError() async {
        let worker = shell("printf '\\000\\000\\000\\005\\007\\377\\376\\377\\355'; exit 69")
        await assertFinishes(worker)
        guard case .failed(let reason) = worker.snapshot else { return XCTFail("Expected metadata rejection") }
        XCTAssertTrue(reason.contains("service registration"), reason)
        XCTAssertTrue(reason.contains("-65555"), reason)
    }

    func testOversizedReadAndMessageFloodAreRejected() {
        var decoder = AirPlayPacketDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0, count: 65_537)))
        decoder = AirPlayPacketDecoder()
        let flood = (0..<1025).reduce(into: Data()) { result, _ in result.append(message(5)) }
        XCTAssertThrowsError(try decoder.append(flood))
    }

    func testH264ConvertsBothStartCodeLengthsAndExtractsConfiguration() throws {
        let packet = try AirPlayH264AccessUnit(Data([
            0, 0, 0, 1, 0x67, 42, 0, 0, 1, 0x68, 23,
            0, 0, 0, 1, 0x65, 99, 0, 0, 1, 0x61, 88
        ]))
        XCTAssertEqual(packet.parameterSets, [Data([0x67, 42]), Data([0x68, 23])])
        XCTAssertEqual(packet.sample, Data([0, 0, 0, 2, 0x65, 99, 0, 0, 0, 2, 0x61, 88]))
        XCTAssertTrue(packet.isKeyframe)
    }

    func testH264InterframeIsNotKeyframe() throws {
        let packet = try AirPlayH264AccessUnit(Data([0, 0, 1, 0x61, 7]))
        XCTAssertFalse(packet.isKeyframe)
        XCTAssertTrue(packet.parameterSets.isEmpty)
    }

    func testH264RejectsEmptyMissingAndInvalidNALHeaders() {
        for bytes: [UInt8] in [[], [0, 1, 2], [0, 0, 1], [0, 0, 1, 0xFF], [0, 0, 1, 0, 0, 1, 0x65]] {
            XCTAssertThrowsError(try AirPlayH264AccessUnit(Data(bytes)))
        }
    }

    func testWatchdogBoundsStartupHeartbeatPartialPacketAndPairing() {
        var watchdog = AirPlayWatchdog(started: 10, lastHeartbeat: 10)
        XCTAssertNil(watchdog.failure(at: 19))
        XCTAssertNotNil(watchdog.failure(at: 21))
        watchdog.ready = true
        watchdog.lastHeartbeat = 20
        XCTAssertNil(watchdog.failure(at: 24))
        XCTAssertNotNil(watchdog.failure(at: 26))
        watchdog.lastHeartbeat = 1000
        watchdog.partialMessageSince = 990
        XCTAssertNotNil(watchdog.failure(at: 1000))
        watchdog.partialMessageSince = nil
        watchdog.pairingSince = 900
        XCTAssertNotNil(watchdog.failure(at: 1000))
        watchdog.pairingSince = nil
        XCTAssertNil(watchdog.failure(at: 1000), "A healthy idle listener must not time out")
        watchdog.lastPeerActivity = 969
        XCTAssertNotNil(watchdog.failure(at: 1000), "A live helper must not hide a stalled device")
        watchdog.lastPeerActivity = 990
        XCTAssertNil(watchdog.failure(at: 1000), "Device feedback keeps a static screen connected")
    }

    func testMissingExecutableFailsWithoutHanging() async {
        let worker = AirPlayReceiverWorker()
        worker.run(executable: URL(fileURLWithPath: "/nonexistent/cockpit-receiver"), arguments: [], consume: { _ in false })
        await assertFinishes(worker)
        guard case .failed = worker.snapshot else { return XCTFail("Expected launch failure") }
    }

    func testCancellationTerminatesChildIgnoringSIGTERM() async {
        let worker = shell("trap '' TERM; printf '\\000\\000\\000\\001\\001'; while :; do sleep 1; done")
        await waitForReady(worker)
        worker.cancel()
        await assertFinishes(worker)
        XCTAssertEqual(worker.snapshot, .stopped)
    }

    func testInheritedPipeDoesNotKeepWorkerAliveAfterChildExit() async {
        // Descendant outlives the shell and keeps stdout open; EOF is not a deadline.
        let worker = shell("sleep 2 & exit 0")
        await assertFinishes(worker, timeout: 1)
        guard case .failed = worker.snapshot else { return XCTFail("Expected unexpected exit") }
    }

    func testMalformedHelperOutputFailsWithoutWaitingForExit() async {
        let worker = shell("printf '\\377\\377\\377\\377'; sleep 2")
        await assertFinishes(worker)
        guard case .failed = worker.snapshot else { return XCTFail("Expected invalid protocol failure") }
    }

    func testMainActorRemainsResponsiveWhileReceiverIsStalled() async {
        let worker = shell("trap '' TERM; while :; do sleep 1; done")
        let event = expectation(description: "UI queue remains responsive")
        DispatchQueue.main.async { event.fulfill() }
        await fulfillment(of: [event], timeout: 1)
        worker.cancel()
        await assertFinishes(worker)
    }

    private func shell(_ script: String) -> AirPlayReceiverWorker {
        let worker = AirPlayReceiverWorker()
        worker.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], consume: { _ in false })
        return worker
    }

    private func waitForReady(_ worker: AirPlayReceiverWorker) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while worker.snapshot == .starting, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(worker.snapshot, .waiting)
    }

    private func assertFinishes(_ worker: AirPlayReceiverWorker, timeout: TimeInterval = 2) async {
        defer { worker.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !worker.isFinished, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(worker.isFinished, "Receiver must finish within a bounded deadline")
    }
}
