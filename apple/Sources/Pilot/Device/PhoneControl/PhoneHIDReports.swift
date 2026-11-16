import AppKit
import Foundation

/// A point on the phone's screen, 0...1 on each axis, origin top-left.
struct PhonePoint: Equatable, Sendable {
    var x: Double
    var y: Double

    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
    var clamped: PhonePoint { PhonePoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)) }
}

/// Wire format for the Mac's Bluetooth HID pointer + keyboard, as iOS
/// AssistiveTouch reads it. Ported from ShortReel's BluetoothHIDHost.
enum PhoneHIDReport {
    /// Report ID 2: 32 buttons and absolute X/Y in 0...32767.
    static func pointer(buttons: UInt32, at point: PhonePoint) -> [UInt8] {
        func axis(_ value: Double) -> (UInt8, UInt8) {
            let scaled = UInt16(max(0, min(1, value.isFinite ? value : 0)) * 32767)
            return (UInt8(scaled & 0xFF), UInt8(scaled >> 8))
        }
        let (xLo, xHi) = axis(point.x)
        let (yLo, yHi) = axis(point.y)
        return [
            0xA1, 0x02,
            UInt8(buttons & 0xFF), UInt8((buttons >> 8) & 0xFF),
            UInt8((buttons >> 16) & 0xFF), UInt8((buttons >> 24) & 0xFF),
            xLo, xHi, yLo, yHi,
        ]
    }

    /// Report ID 1: boot-style keyboard with one key slot in use.
    static func keyboard(modifiers: UInt8, usage: UInt8) -> [UInt8] {
        [0xA1, 0x01, modifiers, 0x00, usage, 0x00, 0x00, 0x00, 0x00, 0x00]
    }

    static let primaryButton: UInt32 = 0x01
    /// The secondary button opens the AssistiveTouch menu.
    static let secondaryButton: UInt32 = 0x02

    /// HID keyboard modifier bits for the held Mac modifier keys.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var bits: UInt8 = 0
        if flags.contains(.control) { bits |= 0x01 }
        if flags.contains(.shift) { bits |= 0x02 }
        if flags.contains(.option) { bits |= 0x04 }
        if flags.contains(.command) { bits |= 0x08 }
        return bits
    }
}

/// The SDP service record the Mac publishes so the phone sees a HID
/// pointer + keyboard. Ported verbatim from ShortReel's HIDServiceRecord.
enum PhoneHIDServiceRecord {
    static let reportDescriptor: [UInt8] = [
        // Mouse, report ID 2: 32 buttons, absolute X/Y 0...32767.
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x20, 0x15, 0x00, 0x25, 0x01, 0x95, 0x20,
        0x75, 0x01, 0x81, 0x02, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00,
        0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0xC0, 0xC0,
        // Keyboard, report ID 1: modifiers, reserved, LEDs, six key slots.
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xE0,
        0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05, 0x75, 0x01, 0x05, 0x08,
        0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00,
        0x29, 0x65, 0x81, 0x00, 0xC0,
    ]

    static func makeRecord(serviceName: String) -> Data {
        var attributes = Data()
        var attributeCount: UInt16 = 0
        func attr(_ id: UInt16, _ element: PhoneSDPElement) {
            attributeCount += 1
            attributes.append(contentsOf: [UInt8(id & 0xFF), UInt8(id >> 8)])
            attributes.append(element.encoded)
        }

        attr(0x0001, .sequence([.uuid16(0x1124)]))
        attr(0x0004, .sequence([
            .sequence([.uuid16(0x0100), .uint16(0x0011)]),
            .sequence([.uuid16(0x0011)]),
        ]))
        attr(0x0005, .sequence([.uuid16(0x1002)]))
        attr(0x0006, .sequence([.uint16(0x656E), .uint16(0x006A), .uint16(0x0100)]))
        attr(0x0009, .sequence([.sequence([.uuid16(0x1124), .uint16(0x0101)])]))
        attr(0x000D, .sequence([
            .sequence([
                .sequence([.uuid16(0x0100), .uint16(0x0013)]),
                .sequence([.uuid16(0x0011)]),
            ]),
        ]))
        // SDP text lengths are 16-bit; a pathological Mac name is truncated.
        attr(0x0100, .text(String(serviceName.prefix(200))))
        attr(0x0101, .text("AssistiveTouch pointer and keyboard"))
        attr(0x0201, .uint16(0x0111))
        attr(0x0202, .uint8(0xC0))
        attr(0x0203, .uint8(0x21))
        attr(0x0204, .boolean(true))
        attr(0x0205, .boolean(false))
        attr(0x0206, .sequence([
            .sequence([.uint8(0x22), .textBytes(reportDescriptor)]),
        ]))
        attr(0x0207, .sequence([.sequence([.uint16(0x0409), .uint16(0x0100)])]))
        attr(0x0208, .boolean(false))
        attr(0x0209, .boolean(true))
        attr(0x020A, .boolean(true))
        attr(0x020B, .uint16(0x0101))
        attr(0x020C, .uint16(0x0C80))
        attr(0x020D, .boolean(true))
        attr(0x020E, .boolean(false))

        var record = Data([UInt8(attributeCount & 0xFF), UInt8(attributeCount >> 8)])
        record.append(attributes)
        return record
    }
}

/// CoreBluetooth's local SDP element encoding: a type byte, a little-endian
/// 16-bit size, then the value (integers always as 4 little-endian bytes).
indirect enum PhoneSDPElement {
    case uint8(UInt8)
    case uint16(UInt16)
    case uuid16(UInt16)
    case boolean(Bool)
    case text(String)
    case textBytes([UInt8])
    case sequence([PhoneSDPElement])

    var encoded: Data {
        switch self {
        case .uint8(let value): Self.header(type: 1, size: 1) + Self.integer(UInt32(value))
        case .uint16(let value): Self.header(type: 1, size: 2) + Self.integer(UInt32(value))
        case .uuid16(let value): Self.header(type: 3, size: 2) + Self.integer(UInt32(value))
        case .boolean(let value): Self.header(type: 5, size: 1) + Data([value ? 1 : 0])
        case .text(let string): PhoneSDPElement.textBytes(Array(string.utf8)).encoded
        case .textBytes(let bytes): Self.header(type: 4, size: bytes.count) + Data(bytes)
        case .sequence(let children):
            children.reduce(into: Self.header(type: 6, size: children.count)) { $0.append($1.encoded) }
        }
    }

    private static func header(type: UInt8, size: Int) -> Data {
        let size = min(size, Int(UInt16.max))
        return Data([type, UInt8(size & 0xFF), UInt8(size >> 8)])
    }

    private static func integer(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }
}

/// Scripted pointer paths for system gestures, timed like ShortReel's
/// tuned Home and App Switcher swipes.
enum PhoneGesturePath {
    struct Step: Equatable {
        var pressed: Bool
        var point: PhonePoint
        /// Seconds to wait before sending this step.
        var delay: Double
    }

    /// Bottom-edge swipe to the top, eased. Sent twice: apps that defer the
    /// bottom edge treat the first swipe as revealing the home indicator.
    static func home() -> [Step] {
        let swipe = edgeSwipe(to: 0.01, start: 0.99, steps: 35, hold: 0.5)
        var second = swipe
        second[0].delay = 0.25
        return swipe + second
    }

    /// Bottom-edge swipe to mid-screen, then a pause so the switcher opens.
    static func appSwitcher() -> [Step] {
        var steps = edgeSwipe(to: 0.55, start: 1.0, steps: 18, hold: 0)
        steps[steps.count - 1].delay = 0.9
        return steps
    }

    private static func edgeSwipe(to endY: Double, start startY: Double, steps count: Int, hold: Double) -> [Step] {
        let start = PhonePoint(x: 0.5, y: startY)
        var steps = [Step(pressed: false, point: start, delay: 0), Step(pressed: true, point: start, delay: 0.1)]
        for step in 1...count {
            let t = Double(step) / Double(count)
            let eased = t * t * (3 - 2 * t)
            steps.append(Step(pressed: true, point: PhonePoint(x: 0.5, y: startY + (endY - startY) * eased),
                              delay: step == 1 ? hold + 0.02 : 0.02))
        }
        steps.append(Step(pressed: false, point: PhonePoint(x: 0.5, y: endY), delay: 0))
        return steps
    }
}
