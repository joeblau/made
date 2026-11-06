import AppKit
import XCTest
@testable import Pilot

final class NativePairingPromptTests: XCTestCase {
    @MainActor
    func testCancelledDecisionCannotBeApprovedByLateSheetCallback() {
        var results: [Bool] = []
        let decision = NativePairingDecision { results.append($0) }
        decision.resolve(approved: false)
        decision.resolve(approved: true)
        decision.resolve(approved: false)
        XCTAssertEqual(results, [false])
    }

    @MainActor
    func testDecisionIsConsumedBeforeReentrantCallback() {
        var results: [Bool] = []
        var decision: NativePairingDecision!
        decision = NativePairingDecision { approved in
            results.append(approved)
            decision.resolve(approved: !approved)
        }
        decision.resolve(approved: true)
        XCTAssertEqual(results, [true])
    }

    @MainActor
    func testOwnerlessAndShutdownRequestsAreRejected() {
        let coordinator = PairingPromptCoordinator()
        var results: [Bool] = []
        XCTAssertFalse(coordinator.present(id: UUID(), title: "Pair", message: "Code", window: nil) {
            results.append($0)
        })
        coordinator.shutdown()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(coordinator.present(id: UUID(), title: "Pair", message: "Code", window: window) {
            results.append($0)
        })
        XCTAssertEqual(results, [false, false])
        window.close()
    }

    @MainActor
    func testPairingWaitsForAnExistingAppSheetAndResolvesOnce() async throws {
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let existingSheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        existingSheet.isReleasedWhenClosed = false
        existingSheet.animationBehavior = .none
        let coordinator = PairingPromptCoordinator()
        defer {
            coordinator.shutdown()
            if let sheet = owner.attachedSheet { owner.endSheet(sheet) }
            existingSheet.close()
            owner.close()
        }
        owner.beginSheet(existingSheet, completionHandler: nil)
        let requestID = UUID()
        var results: [Bool] = []
        XCTAssertTrue(coordinator.present(id: requestID, title: "Pairing fixture", message: "Verify the code", window: owner) {
            results.append($0)
        })
        XCTAssertTrue(owner.attachedSheet === existingSheet)
        XCTAssertTrue(results.isEmpty)

        owner.endSheet(existingSheet)
        for _ in 0..<50 where owner.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(owner.attachedSheet)
        XCTAssertFalse(owner.attachedSheet === existingSheet)
        coordinator.cancel(id: requestID)
        coordinator.cancel(id: requestID)
        XCTAssertEqual(results, [false])
    }

    @MainActor
    func testCancellationWhileAnotherSheetIsOpenNeverPresentsTheQueuedPrompt() {
        let owner = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let existingSheet = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        existingSheet.isReleasedWhenClosed = false
        let coordinator = PairingPromptCoordinator()
        defer {
            coordinator.shutdown()
            owner.endSheet(existingSheet)
            existingSheet.close()
            owner.close()
        }
        owner.beginSheet(existingSheet, completionHandler: nil)
        let requestID = UUID()
        var results: [Bool] = []
        coordinator.present(id: requestID, title: "Pairing fixture", message: "Code", window: owner) { results.append($0) }
        coordinator.cancelAll()
        XCTAssertEqual(results, [false])
        XCTAssertTrue(owner.attachedSheet === existingSheet)
        coordinator.cancel(id: requestID)
        XCTAssertEqual(results, [false])
    }
}
