import CoreGraphics
import Foundation
import XCTest
@testable import Pilot

final class DeviceCaptureLifecycleTests: XCTestCase {
    func testIOSDiscoveryRejectsGenericThirdPartyMuxedCaptureDevice() {
        XCTAssertFalse(IOSCaptureDiscoveryPolicy.includes(
            name: "USB Video",
            modelID: "Cam Link 4K",
            manufacturer: "Elgato",
            isMuxed: true,
            transportType: Int32(bitPattern: 0x7573_6220)
        ))
    }

    func testIOSDiscoveryKeepsRenamedAppleUSBMuxedDevice() {
        XCTAssertTrue(IOSCaptureDiscoveryPolicy.includes(
            name: "Joe's Phone",
            modelID: "Mobile Device",
            manufacturer: "Apple Inc.",
            isMuxed: true,
            transportType: Int32(bitPattern: 0x7573_6220)
        ))
    }

    func testIOSDiscoveryRejectsGenericAppleVirtualDevice() {
        XCTAssertFalse(IOSCaptureDiscoveryPolicy.includes(
            name: "Virtual Camera",
            modelID: "Virtual Camera",
            manufacturer: "Apple Inc.",
            isMuxed: true,
            transportType: Int32(bitPattern: 0x7669_7274)
        ))
    }

    func testIOSDiscoveryKeepsExplicitIPadVideoRepresentation() {
        XCTAssertTrue(IOSCaptureDiscoveryPolicy.includes(
            name: "Design iPad",
            modelID: "iPad14,6",
            manufacturer: "",
            isMuxed: false,
            transportType: 0
        ))
    }

    func testIOSDiscoveryDoesNotTreatBIOSAsIOSIdentity() {
        XCTAssertFalse(IOSCaptureDiscoveryPolicy.includes(
            name: "BIOS Capture",
            modelID: "Video",
            manufacturer: "",
            isMuxed: true,
            transportType: Int32(bitPattern: 0x7573_6220)
        ))
    }

    func testIOSAudioPairingRequiresExactUniqueID() {
        XCTAssertTrue(IOSCaptureAudioPairingPolicy.matches(
            videoUniqueID: "phone-a",
            audioUniqueID: "phone-a"
        ))
        XCTAssertFalse(IOSCaptureAudioPairingPolicy.matches(
            videoUniqueID: "phone-a",
            audioUniqueID: "phone-b"
        ))
    }

    @MainActor
    func testRefreshPublishesDevicesWithoutBlockingMainActor() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let session = DeviceCaptureSession(paneID: UUID(), deviceDiscovery: {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            return DeviceCaptureSession.DiscoveryResult(
                attached: [],
                options: [IOSCaptureDevice(id: "phone-a", name: "Test iPhone", modelID: "iPhone18,1")]
            )
        })
        var observedIDs: [String] = []
        var observedRefreshing = false
        let observation = CockpitObservation {
            observedIDs = session.devices.map(\.id)
            observedRefreshing = session.isRefreshing
        }
        observation.start()
        defer {
            observation.stop()
            session.stop()
        }

        session.refreshDevices()
        XCTAssertTrue(session.isRefreshing)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(session.isRefreshing, "The main actor remains responsive while discovery is pending")
        XCTAssertTrue(observedRefreshing)

        continuation.yield()
        continuation.finish()
        for _ in 0..<100 where session.isRefreshing {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(session.isRefreshing)
        XCTAssertEqual(session.devices.map(\.id), ["phone-a"])
        XCTAssertEqual(session.devices.map(\.name), ["Test iPhone"])
        XCTAssertEqual(observedIDs, ["phone-a"])
        XCTAssertFalse(observedRefreshing)
    }

    func testScreenshotTimesOutWithRecoverableError() async {
        let coordinator = CaptureCoordinator()
        do {
            _ = try await coordinator.nextFrame(timeout: 0.02)
            XCTFail("expected timeout")
        } catch let error as CaptureFrameError {
            XCTAssertEqual(error, .timedOut)
            XCTAssertTrue(error.localizedDescription.contains("retry"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTaskCancellationResolvesPendingScreenshot() async {
        let coordinator = CaptureCoordinator()
        let request = Task { try await coordinator.nextFrame(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(20))
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("expected cancellation")
        } catch let error as CaptureFrameError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDetachResolvesEveryConcurrentScreenshotWithoutOverlapLoss() async {
        let coordinator = CaptureCoordinator()
        let first = Task { try await coordinator.nextFrame(timeout: 5) }
        let second = Task { try await coordinator.nextFrame(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(20))
        coordinator.cancelPendingFrames(reason: .detached)

        for request in [first, second] {
            do {
                _ = try await request.value
                XCTFail("expected detach failure")
            } catch let error as CaptureFrameError {
                XCTAssertEqual(error, .detached)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSessionStopAndCoordinatorShutdownResolvePendingScreenshots() async {
        let stoppedCoordinator = CaptureCoordinator()
        let stopped = Task { try await stoppedCoordinator.nextFrame(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(20))
        stoppedCoordinator.cancelPendingFrames(reason: .sessionStopped)
        await assertFrameError(.sessionStopped, from: stopped)

        let closedCoordinator = CaptureCoordinator()
        let closed = Task { try await closedCoordinator.nextFrame(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(20))
        closedCoordinator.shutdown()
        await assertFrameError(.coordinatorReleased, from: closed)
    }

    func testStoppingBeforeFirstFrameAlwaysFinishesRecordingState() async {
        let coordinator = CaptureCoordinator()
        let callback = expectation(description: "recording finish callback")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-no-frame-\(UUID().uuidString).mov")
        coordinator.onFinish = { finishedURL, error in
            XCTAssertEqual(finishedURL, url)
            XCTAssertTrue(error?.contains("before the first video frame") == true)
            callback.fulfill()
        }
        XCTAssertTrue(coordinator.startRecording(to: url))
        XCTAssertFalse(coordinator.startRecording(to: url), "overlapping recording starts must be explicit")
        coordinator.stopRecording()
        await fulfillment(of: [callback], timeout: 1)
    }

    @MainActor
    func testScreenshotNamesDoNotCollideAndWritesAreCreateOnly() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let identifiers = [
            UUID(uuidString: "01234567-0000-0000-0000-000000000000")!,
            UUID(uuidString: "01234567-1111-1111-1111-111111111111")!
        ]
        let urls = identifiers.map { uniqueID in
            DeviceCaptureSession.timestampedURL(
                folder: "Desktop",
                name: "iPhone Screenshot",
                ext: "png",
                date: date,
                uniqueID: uniqueID
            )
        }
        XCTAssertEqual(Set(urls).count, urls.count)
        XCTAssertTrue(urls[0].lastPathComponent.contains(identifiers[0].uuidString.lowercased()))
        XCTAssertTrue(urls[1].lastPathComponent.contains(identifiers[1].uuidString.lowercased()))

        let atomic = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-atomic-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: atomic) }
        try Data([1]).write(to: atomic, options: .withoutOverwriting)
        XCTAssertThrowsError(try Data([2]).write(to: atomic, options: .withoutOverwriting))
    }

    @MainActor
    func testDevicePreferencesAreScopedToPaneID() throws {
        let suiteName = "app.blau.pilot.tests.device-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstPaneID = UUID()
        let secondPaneID = UUID()
        defaults.set("first-device", forKey: DeviceCaptureSession.preferenceKey(for: firstPaneID))
        defaults.set("First iPhone", forKey: DeviceCaptureSession.preferenceNameKey(for: firstPaneID))
        defaults.set("second-device", forKey: DeviceCaptureSession.preferenceKey(for: secondPaneID))
        defaults.set("Second iPhone", forKey: DeviceCaptureSession.preferenceNameKey(for: secondPaneID))

        let firstSession = DeviceCaptureSession(paneID: firstPaneID, defaults: defaults)
        let secondSession = DeviceCaptureSession(paneID: secondPaneID, defaults: defaults)

        XCTAssertEqual(firstSession.preferredDeviceUniqueID, "first-device")
        XCTAssertEqual(firstSession.preferredDeviceName, "First iPhone")
        XCTAssertEqual(secondSession.preferredDeviceUniqueID, "second-device")
        XCTAssertEqual(secondSession.preferredDeviceName, "Second iPhone")
    }

    @MainActor
    func testSessionRestoresPersistedDevicePreference() throws {
        let suiteName = "app.blau.pilot.tests.device-preference-restore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let paneID = UUID()
        let preferenceKey = DeviceCaptureSession.preferenceKey(for: paneID)
        let preferenceNameKey = DeviceCaptureSession.preferenceNameKey(for: paneID)
        defaults.set("saved-device-id", forKey: preferenceKey)
        defaults.set("Joe's iPhone", forKey: preferenceNameKey)

        let session = DeviceCaptureSession(paneID: paneID, defaults: defaults)

        XCTAssertEqual(session.preferredDeviceUniqueID, "saved-device-id")
        XCTAssertEqual(session.preferredDeviceName, "Joe's iPhone")
    }

    @MainActor
    func testChooseAnotherDeviceClearsPersistedPreference() throws {
        let suiteName = "app.blau.pilot.tests.device-preference-clear.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let paneID = UUID()
        let preferenceKey = DeviceCaptureSession.preferenceKey(for: paneID)
        let preferenceNameKey = DeviceCaptureSession.preferenceNameKey(for: paneID)
        defaults.set("old-device-id", forKey: preferenceKey)
        defaults.set("Old iPhone", forKey: preferenceNameKey)
        let session = DeviceCaptureSession(paneID: paneID, defaults: defaults)

        session.chooseAnotherDevice()

        XCTAssertNil(session.preferredDeviceUniqueID)
        XCTAssertNil(session.preferredDeviceName)
        XCTAssertNil(defaults.object(forKey: preferenceKey))
        XCTAssertNil(defaults.object(forKey: preferenceNameKey))
        XCTAssertEqual(session.status, .picking)
    }

    @MainActor
    func testRegistryDestructiveRemoveClearsStandardDevicePreference() {
        let paneID = UUID()
        let preferenceKey = DeviceCaptureSession.preferenceKey(for: paneID)
        let preferenceNameKey = DeviceCaptureSession.preferenceNameKey(for: paneID)
        let defaults = UserDefaults.standard
        let registry = DeviceCaptureRegistry.shared
        defer {
            registry.remove(paneID: paneID)
            defaults.removeObject(forKey: preferenceKey)
            defaults.removeObject(forKey: preferenceNameKey)
        }

        defaults.set("removed-device-id", forKey: preferenceKey)
        defaults.set("Removed iPhone", forKey: preferenceNameKey)
        let session = registry.session(for: paneID)
        XCTAssertEqual(session.preferredDeviceUniqueID, "removed-device-id")
        XCTAssertEqual(session.preferredDeviceName, "Removed iPhone")

        registry.remove(paneID: paneID)

        XCTAssertNil(defaults.object(forKey: preferenceKey))
        XCTAssertNil(defaults.object(forKey: preferenceNameKey))
        XCTAssertNil(registry.existingSession(for: paneID))
    }

    @MainActor
    func testRegistrySuspendPreservesStandardDevicePreference() {
        let paneID = UUID()
        let preferenceKey = DeviceCaptureSession.preferenceKey(for: paneID)
        let preferenceNameKey = DeviceCaptureSession.preferenceNameKey(for: paneID)
        let defaults = UserDefaults.standard
        let registry = DeviceCaptureRegistry.shared
        defer {
            registry.remove(paneID: paneID)
            defaults.removeObject(forKey: preferenceKey)
            defaults.removeObject(forKey: preferenceNameKey)
        }

        defaults.set("suspended-device-id", forKey: preferenceKey)
        defaults.set("Suspended iPhone", forKey: preferenceNameKey)
        let original = registry.session(for: paneID)

        registry.suspend(paneID: paneID)

        XCTAssertEqual(defaults.string(forKey: preferenceKey), "suspended-device-id")
        XCTAssertEqual(defaults.string(forKey: preferenceNameKey), "Suspended iPhone")
        XCTAssertTrue(registry.existingSession(for: paneID) === original)
        let restored = registry.session(for: paneID)
        XCTAssertTrue(restored === original)
        XCTAssertEqual(restored.preferredDeviceUniqueID, "suspended-device-id")
        XCTAssertEqual(restored.preferredDeviceName, "Suspended iPhone")
    }

    private func assertFrameError(
        _ expected: CaptureFrameError,
        from request: Task<CGImage, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await request.value
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CaptureFrameError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
