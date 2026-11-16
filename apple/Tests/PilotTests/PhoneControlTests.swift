import AppKit
import Foundation
@preconcurrency import PhoneHIDKit
import Testing
@testable import Pilot

@Suite("iPhone control over Bluetooth HID")
struct PhoneControlTests {
    // MARK: Reports

    @Test("Pointer reports carry buttons and absolute 15-bit coordinates")
    func pointerReport() {
        #expect(PhoneHIDReport.pointer(buttons: 0, at: PhonePoint(x: 0, y: 0)) == [0xA1, 0x02, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(PhoneHIDReport.pointer(buttons: 1, at: PhonePoint(x: 1, y: 1)) == [0xA1, 0x02, 1, 0, 0, 0, 0xFF, 0x7F, 0xFF, 0x7F])
        let middle = PhoneHIDReport.pointer(buttons: 0x02, at: PhonePoint(x: 0.5, y: 0.25))
        #expect(middle[2] == 0x02)
        #expect(Int(middle[6]) | Int(middle[7]) << 8 == 16383)
        #expect(Int(middle[8]) | Int(middle[9]) << 8 == 8191)
        // Out-of-range and non-finite input never escapes the axis range.
        let wild = PhoneHIDReport.pointer(buttons: 0, at: PhonePoint(x: 3, y: .nan))
        #expect(Array(wild[6...9]) == [0xFF, 0x7F, 0, 0])
    }

    @Test("Keyboard reports and Mac modifier mapping")
    func keyboardReport() {
        #expect(PhoneHIDReport.keyboard(modifiers: 0x02, usage: 0x04) == [0xA1, 0x01, 0x02, 0, 0x04, 0, 0, 0, 0, 0])
        #expect(PhoneHIDReport.modifiers([]) == 0)
        #expect(PhoneHIDReport.modifiers([.control, .shift, .option, .command]) == 0x0F)
        #expect(PhoneHIDReport.modifiers([.shift, .capsLock]) == 0x02)
    }

    // MARK: SDP record

    private struct Element {
        var type: UInt8
        var bytes: [UInt8] = []
        var children: [Element] = []
        var number: Int { bytes.reversed().reduce(0) { ($0 << 8) | Int($1) } }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        mutating func take(_ count: Int) throws -> [UInt8] {
            guard offset + count <= bytes.count else { throw PhoneControlError("truncated") }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }
        mutating func uint16() throws -> Int { let value = try take(2); return Int(value[0]) | Int(value[1]) << 8 }
        mutating func element() throws -> Element {
            let type = try take(1)[0]
            let size = try uint16()
            if type == 6 { return Element(type: 6, children: try (0..<size).map { _ in try element() }) }
            guard [1, 3, 4, 5].contains(type) else { throw PhoneControlError("bad type \(type)") }
            return Element(type: type, bytes: try take(type == 1 || type == 3 ? 4 : size))
        }
    }

    @Test("SDP record is well-formed and advertises a HID pointer + keyboard", arguments: [
        "Cockpit", "Joe’s Mac", String(repeating: "M", count: 300),
    ])
    func serviceRecord(name: String) throws {
        var reader = Reader(bytes: Array(PhoneHIDServiceRecord.makeRecord(serviceName: name)))
        let count = try reader.uint16()
        #expect(count == 22)
        var attributes: [Int: Element] = [:]
        for _ in 0..<count {
            let id = try reader.uint16()
            #expect(attributes[id] == nil, "duplicate attribute \(id)")
            attributes[id] = try reader.element()
        }
        #expect(reader.offset == reader.bytes.count)
        // HID service class, control PSM 0x11, interrupt PSM 0x13.
        #expect(attributes[0x0001]?.children.first?.number == 0x1124)
        #expect(attributes[0x0004]?.children.first?.children.last?.number == 0x0011)
        #expect(attributes[0x000D]?.children.first?.children.first?.children.last?.number == 0x0013)
        let serviceName = try #require(attributes[0x0100])
        #expect(String(decoding: serviceName.bytes, as: UTF8.self) == String(name.prefix(200)))
        let descriptor = try #require(attributes[0x0206]?.children.first?.children.last)
        #expect(descriptor.bytes == PhoneHIDServiceRecord.reportDescriptor)
    }

    // MARK: Gestures

    @Test("Home and App Switcher press only while moving and end released")
    func gesturePaths() {
        for path in [PhoneGesturePath.home(), PhoneGesturePath.appSwitcher()] {
            #expect(path.first?.pressed == false)
            #expect(path.last?.pressed == false)
            #expect(path.allSatisfy { $0.point.isValid && $0.delay >= 0 })
            #expect(path.dropFirst().first?.pressed == true, "presses where it hovered")
        }
        let home = PhoneGesturePath.home()
        #expect(home.filter { !$0.pressed }.count == 4, "two full swipes")
        #expect(home.first?.point.y ?? 0 > 0.95)
        #expect(home.last?.point.y ?? 1 < 0.05)
        let switcher = PhoneGesturePath.appSwitcher()
        #expect(abs((switcher.last?.point.y ?? 0) - 0.55) < 1e-9)
        #expect(switcher.last?.delay == 0.9, "holds so the switcher opens before release")
    }

    @MainActor
    @Test("Trackpad scrolling drags with the content and stays on screen")
    func scrollMapping() {
        let anchor = PhonePoint(x: 0.5, y: 0.5)
        let moved = DeviceCaptureHostView.scrolled(anchor, by: CGSize(width: 50, height: -100), in: CGSize(width: 200, height: 400))
        #expect(abs(moved.x - 0.75) < 1e-9 && abs(moved.y - 0.25) < 1e-9)
        #expect(DeviceCaptureHostView.scrolled(anchor, by: CGSize(width: 9_999, height: 9_999), in: CGSize(width: 200, height: 400))
            == PhonePoint(x: 1, y: 1))
    }

    // MARK: Phone identity

    @Test("The pane's capture device maps to its USB phone")
    func matchesCapturedPhone() {
        let first = PhoneControl.USBPhone(udid: "00008110-001A2B3C4D5E6F70", name: "Work iPhone", trusted: true, bluetoothAddress: nil)
        let second = PhoneControl.USBPhone(udid: "00008120-0011223344556677", name: "Joe’s iPhone", trusted: true, bluetoothAddress: nil)
        let phones = [first, second]
        #expect(PhoneControl.match(phones, captureID: "00008110001a2b3c4d5e6f70", captureName: nil) == first)
        #expect(PhoneControl.match(phones, captureID: "unrelated", captureName: "Joe’s iPhone") == second)
        #expect(PhoneControl.match(phones, captureID: nil, captureName: nil) == nil, "ambiguous phones never guess")
        #expect(PhoneControl.match([first], captureID: nil, captureName: "Other") == first)
        #expect(PhoneControl.match([], captureID: "x", captureName: "y") == nil)
    }

    @Test("Bluetooth addresses are validated before use")
    func bluetoothAddresses() {
        #expect(PhoneControl.normalizedAddress("A4:C3:F0:12:34:56") == "a4c3f0123456")
        #expect(PhoneControl.normalizedAddress("a4-c3-f0-12-34-56") == "a4c3f0123456")
        #expect(PhoneControl.normalizedAddress("A4:C3:F0:12:34") == nil)
        #expect(PhoneControl.normalizedAddress("A4:C3:F0:12:34:5G") == nil)
        #expect(PhoneControl.normalizedAddress("A4:C3:F0:12:34:56:78") == nil)
        #expect(PhoneControl.normalizedAddress(nil) == nil)
        #expect(PhoneControl.formatted("a4c3f0123456") == "A4:C3:F0:12:34:56")
    }

    // MARK: Control channel

    @Test("Control channel answers GET_REPORT, SET_REPORT, protocol, and unplug")
    func controlSession() throws {
        let session = HIDControlSession()
        // GET_REPORT input, report ID 2 (pointer), returns the last pointer input.
        session.recordInput(Data(PhoneHIDReport.pointer(buttons: 1, at: PhonePoint(x: 1, y: 0))))
        let pointer = try #require(session.response(toPacket: Data([0x41, 0x02])))
        #expect(Array(pointer) == [0xA1, 0x02, 1, 0, 0, 0, 0xFF, 0x7F, 0, 0])
        // GET_REPORT with a size cap truncates.
        let capped = try #require(session.response(toPacket: Data([0x49, 0x02, 0x03, 0x00])))
        #expect(Array(capped) == [0xA1, 0x02, 1, 0])
        // Unknown report ID: handshake ERR_INVALID_REPORT_ID.
        #expect(session.response(toPacket: Data([0x41, 0x09])) == Data([0x02]))
        // SET_REPORT output for keyboard LEDs is acknowledged and readable.
        #expect(session.response(toPacket: Data([0x52, 0x01, 0x03])) == Data([0x00]))
        #expect(session.response(toPacket: Data([0x42, 0x01])) == Data([0xA2, 0x01, 0x03]))
        // GET_PROTOCOL reports report mode; SET_PROTOCOL boot is unsupported.
        #expect(session.response(toPacket: Data([0x60])) == Data([0xA0, 0x01]))
        #expect(session.response(toPacket: Data([0x70])) == Data([0x03]))
        // HID_CONTROL suspend, resume, virtual cable unplug.
        #expect(session.response(toPacket: Data([0x13])) == nil)
        #expect(session.suspended)
        _ = session.response(toPacket: Data([0x14]))
        #expect(!session.suspended)
        _ = session.response(toPacket: Data([0x15]))
        #expect(session.unplugged)
    }

    @MainActor
    @Test("Input is ignored until the phone is connected")
    func inputRequiresConnection() {
        let control = PhoneControl()
        #expect(control.status == .off)
        control.send(.down(PhonePoint(x: 0.5, y: 0.5)))
        control.send(.gesture(PhoneGesturePath.home()))
        #expect(control.status == .off)
        #expect(!control.isActive(for: UUID()))
    }
}
