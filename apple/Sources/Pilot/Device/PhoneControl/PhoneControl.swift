import AppKit
import CoreBluetooth
@preconcurrency import IOBluetooth
import Observation
import OSLog
@preconcurrency import PhoneHIDKit

private let phoneControlLog = Logger(subsystem: "app.blau.pilot", category: "PhoneControl")

/// Drives the iPhone shown in a wired Device pane from this Mac: Cockpit
/// becomes a Bluetooth pointer + keyboard and AssistiveTouch turns the
/// pointer into touches. No Developer Mode and nothing installed on the
/// phone. See docs/iphone-control.md for the setup flow and threat model.
///
/// One phone at a time: the pane that turns control on owns it until it
/// turns it off. The Bluetooth service is published only while control is
/// on, and only the phone identified over USB may connect.
@MainActor
@Observable
final class PhoneControl {
    static let shared = PhoneControl()

    enum Status: Equatable {
        case off
        /// Reading the phone over USB, enabling AssistiveTouch, starting Bluetooth.
        case preparing(String)
        /// Published and waiting for the phone to open its HID channels.
        case waitingForPhone(phoneName: String, macName: String)
        case connected(phoneName: String)
        case failed(String)
    }

    private(set) var status: Status = .off
    /// The Device pane that owns control.
    private(set) var paneID: UUID?

    var isConnected: Bool { if case .connected = status { true } else { false } }

    func isActive(for paneID: UUID) -> Bool { self.paneID == paneID && status != .off }

    @ObservationIgnored private let usb = USBPhoneBridge()
    @ObservationIgnored private var bridge: CBHIDBridge?
    @ObservationIgnored private var expectedAddress: String?
    @ObservationIgnored private var phoneName = "iPhone"
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private lazy var macName = Host.current().localizedName ?? "this Mac"

    // Serial input queue: AssistiveTouch needs small gaps between a hover,
    // a press and a release, so every report goes through one pump.
    @ObservationIgnored private var queue: [Input] = []
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var pressed = false
    @ObservationIgnored private var pressedAt = ContinuousClock.now
    @ObservationIgnored private var lastPoint = PhonePoint(x: 0.5, y: 0.5)
    @ObservationIgnored private var generation = 0

    /// Pending events beyond this are dropped; a stalled channel must not
    /// grow memory without bound.
    static let maximumQueuedInputs = 256

    enum Input: Equatable {
        case down(PhonePoint)
        case move(PhonePoint)
        case up(PhonePoint)
        case key(modifiers: UInt8, usage: UInt8)
        case keyUp
        case assistiveTouchMenu
        case gesture([PhoneGesturePath.Step])
    }

    // MARK: Lifecycle

    /// Turns control on for the phone a Device pane is mirroring.
    /// `captureID` is the AVCaptureDevice uniqueID and `captureName` its
    /// localized name; either may match the phone's USB identity.
    func enable(paneID: UUID, captureID: String?, captureName: String?) {
        disable()
        self.paneID = paneID
        generation += 1
        let request = generation
        status = .preparing("Finding the iPhone over USB…")
        setupTask = Task { [weak self] in
            await self?.prepare(request: request, captureID: captureID, captureName: captureName)
        }
    }

    func disable() {
        generation += 1
        setupTask?.cancel()
        setupTask = nil
        queue.removeAll()
        if pressed, let address = expectedAddress {
            try? bridge?.sendReport(Data(PhoneHIDReport.pointer(buttons: 0, at: lastPoint)), toPeerWithAddress: address)
        }
        pressed = false
        if let address = expectedAddress { bridge?.disconnectPeer(withAddress: address) }
        bridge?.stop()
        bridge = nil
        expectedAddress = nil
        paneID = nil
        status = .off
    }

    private func prepare(request: Int, captureID: String?, captureName: String?) async {
        do {
            try Self.checkBluetoothPermission()
            let phones = try await usbPhones()
            guard request == generation else { return }
            guard let phone = Self.match(phones, captureID: captureID, captureName: captureName) else {
                throw PhoneControlError(phones.isEmpty
                    ? "No iPhone is connected over USB. Connect it with a cable to set up control."
                    : "Couldn't tell which USB iPhone this pane is showing. Disconnect the others and try again.")
            }
            phoneName = phone.name
            if !phone.trusted {
                status = .preparing("Unlock \(phone.name) and tap Trust…")
                _ = try await usbCall { self.usb.requestTrust(forIdentifier: phone.udid, completion: $0) }
                guard request == generation else { return }
            }
            status = .preparing("Turning on AssistiveTouch…")
            let prepared = try await usbCall { self.usb.preparePhone(withIdentifier: phone.udid, completion: $0) }
            guard request == generation else { return }
            guard let address = Self.normalizedAddress(prepared.bluetoothAddress) else {
                throw PhoneControlError("\(phone.name) didn't report a Bluetooth address. Keep it unlocked and try again.")
            }
            try startBluetooth(expecting: address)
            status = .waitingForPhone(phoneName: phone.name, macName: macName)
            if IOBluetoothDevice(addressString: Self.formatted(address))?.isPaired() == true {
                bridge?.requestConnection(address: address)
            }
        } catch is CancellationError {
        } catch {
            guard request == generation else { return }
            phoneControlLog.error("setup failed: \(error.localizedDescription, privacy: .public)")
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        let owner = paneID
        disable()
        paneID = owner
        status = .failed(message)
    }

    private func startBluetooth(expecting address: String) throws {
        let bridge = CBHIDBridge()
        // Callbacks arrive on the bridge's queue; @Sendable keeps them out
        // of main-actor isolation, and each hops to the main actor.
        bridge.onLog = { @Sendable message in phoneControlLog.debug("\(message, privacy: .public)") }
        bridge.onPeerChannelsChanged = { @Sendable [weak self] state in
            let address = state.address, ready = state.hasControlChannel && state.hasInterruptChannel
            Task { @MainActor in self?.channelsChanged(address: address, ready: ready) }
        }
        bridge.onPeerDisconnected = { @Sendable [weak self] address in
            Task { @MainActor in self?.peerDisconnected(address: address) }
        }
        bridge.onConnectionFailed = { @Sendable [weak self] address, error in
            let message = error.localizedDescription
            Task { @MainActor in self?.connectionFailed(address: address, message: message) }
        }
        let name = macName
        try bridge.start(withServiceName: name, serviceRecord: PhoneHIDServiceRecord.makeRecord(serviceName: name))
        self.bridge = bridge
        expectedAddress = address
    }

    private func channelsChanged(address: String, ready: Bool) {
        guard let expectedAddress, bridge != nil else { return }
        guard address == expectedAddress else {
            // Only the phone identified over USB may drive the session.
            phoneControlLog.notice("rejected HID peer \(address, privacy: .private)")
            bridge?.disconnectPeer(withAddress: address)
            return
        }
        if ready {
            status = .connected(phoneName: phoneName)
        } else if isConnected {
            status = .waitingForPhone(phoneName: phoneName, macName: macName)
        }
    }

    private func peerDisconnected(address: String) {
        guard address == expectedAddress, isConnected else { return }
        queue.removeAll()
        pressed = false
        status = .waitingForPhone(phoneName: phoneName, macName: macName)
    }

    private func connectionFailed(address: String, message: String) {
        guard address == expectedAddress, !isConnected else { return }
        // The phone can still connect from its AssistiveTouch device list.
        phoneControlLog.notice("reconnect failed: \(message, privacy: .public)")
    }

    // MARK: Input

    func send(_ input: Input) {
        guard isConnected else { return }
        if case .move = input, case .move = queue.last {
            queue[queue.count - 1] = input
        } else {
            guard queue.count < Self.maximumQueuedInputs else { return }
            queue.append(input)
        }
        pump()
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        let request = generation
        Task { [weak self] in
            while let self, request == self.generation, !self.queue.isEmpty {
                let input = self.queue.removeFirst()
                do {
                    try await self.perform(input)
                } catch {
                    guard request == self.generation else { break }
                    phoneControlLog.error("input failed: \(error.localizedDescription, privacy: .public)")
                    self.queue.removeAll()
                    self.pressed = false
                    if self.isConnected { self.status = .waitingForPhone(phoneName: self.phoneName, macName: self.macName) }
                }
            }
            self?.pumping = false
        }
    }

    private func perform(_ input: Input) async throws {
        switch input {
        case .down(let point):
            if pressed { try report(buttons: 0, point: lastPoint) }
            try report(buttons: 0, point: point)
            try await Task.sleep(for: .milliseconds(50))
            try report(buttons: PhoneHIDReport.primaryButton, point: point)
            pressed = true
            pressedAt = .now
        case .move(let point):
            guard pressed else { return }
            try report(buttons: PhoneHIDReport.primaryButton, point: point)
        case .up(let point):
            guard pressed else { return }
            // A click shorter than this reads as nothing to AssistiveTouch.
            let held = ContinuousClock.now - pressedAt
            if held < .milliseconds(90) { try await Task.sleep(for: .milliseconds(90) - held) }
            pressed = false
            try report(buttons: 0, point: point)
        case .key(let modifiers, let usage):
            try send(PhoneHIDReport.keyboard(modifiers: modifiers, usage: usage))
        case .keyUp:
            try send(PhoneHIDReport.keyboard(modifiers: 0, usage: 0))
        case .assistiveTouchMenu:
            try report(buttons: 0, point: lastPoint)
            try report(buttons: PhoneHIDReport.secondaryButton, point: lastPoint)
            try await Task.sleep(for: .milliseconds(60))
            try report(buttons: 0, point: lastPoint)
        case .gesture(let steps):
            defer { if pressed { try? report(buttons: 0, point: lastPoint); pressed = false } }
            for step in steps {
                if step.delay > 0 { try await Task.sleep(for: .seconds(step.delay)) }
                try report(buttons: step.pressed ? PhoneHIDReport.primaryButton : 0, point: step.point)
                pressed = step.pressed
            }
        }
    }

    private func report(buttons: UInt32, point: PhonePoint) throws {
        let point = point.clamped
        try send(PhoneHIDReport.pointer(buttons: buttons, at: point))
        lastPoint = point
    }

    private func send(_ bytes: [UInt8]) throws {
        guard let bridge, let expectedAddress else { throw PhoneControlError("Control is off.") }
        try bridge.sendReport(Data(bytes), toPeerWithAddress: expectedAddress)
    }

    // MARK: USB

    /// A Sendable copy of what setup needs from a USBPhoneSnapshot.
    struct USBPhone: Equatable, Sendable {
        var udid: String
        var name: String
        var trusted: Bool
        var bluetoothAddress: String?

        init(udid: String, name: String, trusted: Bool, bluetoothAddress: String?) {
            self.udid = udid
            self.name = name
            self.trusted = trusted
            self.bluetoothAddress = bluetoothAddress
        }

        init(_ snapshot: USBPhoneSnapshot) {
            self.init(udid: snapshot.identifier, name: snapshot.name, trusted: snapshot.trusted,
                      bluetoothAddress: snapshot.bluetoothAddress)
        }
    }

    private func usbPhones() async throws -> [USBPhone] {
        try await withCheckedThrowingContinuation { continuation in
            usb.fetchConnectedPhones { @Sendable phones, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: phones.map(USBPhone.init)) }
            }
        }
    }

    private func usbCall(
        _ call: (@escaping @Sendable (USBPhoneSnapshot?, Error?) -> Void) -> Void
    ) async throws -> USBPhone {
        try await withCheckedThrowingContinuation { continuation in
            call { @Sendable phone, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let phone {
                    continuation.resume(returning: USBPhone(phone))
                } else {
                    continuation.resume(throwing: PhoneControlError("The iPhone disconnected from USB."))
                }
            }
        }
    }

    /// The USB phone a capture device shows: same identifier (AVFoundation
    /// reports the UDID, sometimes without dashes), else same name, else the
    /// only phone connected.
    nonisolated static func match(_ phones: [USBPhone], captureID: String?, captureName: String?) -> USBPhone? {
        func key(_ value: String) -> String { value.lowercased().filter(\.isHexDigit) }
        if let captureID, !key(captureID).isEmpty,
           let phone = phones.first(where: { key($0.udid) == key(captureID) }) { return phone }
        if let captureName {
            let named = phones.filter { $0.name == captureName }
            if named.count == 1 { return named[0] }
        }
        return phones.count == 1 ? phones[0] : nil
    }

    /// 12 lowercase hex digits, or nil for anything that isn't a Bluetooth address.
    nonisolated static func normalizedAddress(_ raw: String?) -> String? {
        guard let raw, raw.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == "-") }) else { return nil }
        let digits = raw.lowercased().filter(\.isHexDigit)
        return digits.count == 12 ? digits : nil
    }

    nonisolated static func formatted(_ address: String) -> String {
        stride(from: 0, to: min(address.count, 12), by: 2)
            .map { address.dropFirst($0).prefix(2).uppercased() }
            .joined(separator: ":")
    }

    private static func checkBluetoothPermission() throws {
        switch CBManager.authorization {
        case .notDetermined, .allowedAlways: return
        case .denied: throw PhoneControlError("Bluetooth access is off for Cockpit. Allow it in System Settings › Privacy & Security › Bluetooth, then try again.")
        case .restricted: throw PhoneControlError("Bluetooth is restricted on this Mac.")
        @unknown default: throw PhoneControlError("macOS couldn't confirm Bluetooth access for Cockpit.")
        }
    }
}

struct PhoneControlError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
