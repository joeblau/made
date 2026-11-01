import AppKit
import Foundation
import Testing
@testable import Pilot

@Suite("Device screen drag")
struct DeviceScreenDragTests {
    @Test("Touch panes only start a screen drag with Command held")
    func touchPanesRequireCommand() {
        var gesture = DeviceScreenDragGesture()
        let plain = gesture.press(at: .zero, modifiers: [], requiresCommand: true)
        #expect(!plain)
        #expect(!gesture.isTracking)
        let command = gesture.press(at: .zero, modifiers: [.command], requiresCommand: true)
        #expect(command)
        #expect(gesture.isTracking)
    }

    @Test("A drag begins once, only after the pointer passes the threshold")
    func beginsOnceAfterThreshold() {
        var gesture = DeviceScreenDragGesture()
        _ = gesture.press(at: .zero, modifiers: [], requiresCommand: false)
        let belowThreshold = gesture.drag(to: CGPoint(x: 1, y: 1))
        let pastThreshold = gesture.drag(to: CGPoint(x: 10, y: 0))
        let afterBegin = gesture.drag(to: CGPoint(x: 20, y: 0))
        gesture.release()
        let afterRelease = gesture.drag(to: CGPoint(x: 40, y: 0))
        #expect(!belowThreshold)
        #expect(pastThreshold)
        #expect(!afterBegin)
        #expect(!afterRelease)
        #expect(!gesture.isTracking)
    }

    @Test("A plain press after a Command drag goes back to touch input")
    func plainPressResets() {
        var gesture = DeviceScreenDragGesture()
        _ = gesture.press(at: .zero, modifiers: [.command], requiresCommand: true)
        _ = gesture.drag(to: CGPoint(x: 10, y: 0))
        // The drag session swallows mouseUp, so the next press must reset.
        let plain = gesture.press(at: .zero, modifiers: [], requiresCommand: true)
        #expect(!plain)
        #expect(!gesture.isTracking)
    }

    @Test("Screenshots are written as PNG files and stale ones are pruned")
    func writesAndPrunes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlauDeviceDragTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try #require(makeImage())

        let stale = try DeviceScreenDragFiles.write(image, name: "simulator", directory: directory)
        let old = Date().addingTimeInterval(-DeviceScreenDragFiles.maxAge - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)

        let fresh = try DeviceScreenDragFiles.write(image, name: "simulator", directory: directory)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(fresh.pathExtension == "png")
        #expect(NSImage(contentsOf: fresh) != nil)
        #expect(!fresh.lastPathComponent.contains(" "))
    }

    private func makeImage() -> CGImage? {
        let context = CGContext(
            data: nil, width: 4, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        return context?.makeImage()
    }
}

@Suite("Terminal drop text")
struct TerminalDropTextTests {
    @Test("Dropped file paths are shell-escaped and space-separated")
    func escapesPaths() {
        let text = TerminalDropText.text(forFileURLs: [
            URL(fileURLWithPath: "/tmp/plain.png"),
            URL(fileURLWithPath: "/tmp/My Shots/it's (1).png"),
        ])
        #expect(text == #"/tmp/plain.png /tmp/My\ Shots/it\'s\ \(1\).png"#)
    }

    @Test("Non-file URLs are ignored and the file count is bounded")
    func boundsInput() {
        #expect(TerminalDropText.text(forFileURLs: [URL(string: "https://example.com/a.png")!]) == nil)
        let many = (0..<(TerminalDropText.maxFileURLs + 10)).map { URL(fileURLWithPath: "/tmp/\($0).png") }
        let text = TerminalDropText.text(forFileURLs: many)
        #expect(text?.split(separator: " ").count == TerminalDropText.maxFileURLs)
    }

    @Test("Text drops paste as-is, files take precedence")
    @MainActor
    func readsPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("BlauTerminalDropTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("echo hi", forType: .string)
        #expect(TerminalDropText.text(from: pasteboard) == "echo hi")

        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/shot.png") as NSURL])
        #expect(TerminalDropText.text(from: pasteboard) == "/tmp/shot.png")
    }
}

/// The device-pane toasts float over a mirrored screen that can be pure white
/// whatever the app's appearance. Their black scrim alone must keep the text
/// at WCAG AA (4.5:1) over that worst case, for the default white label and
/// the orange "Recording without audio" heads-up (TYPE-3).
@Suite("Device pane toast contrast")
struct DeviceToastContrastTests {
    @Test("The scrim keeps toast text at 4.5:1 or better over a white screen")
    func scrimClearsAAOverWhite() throws {
        // Black at `scrimOpacity` over white, composited in sRGB.
        let backdrop = 1 - DevicePaneToast.scrimOpacity
        let backdropLuminance = Self.luminance(red: backdrop, green: backdrop, blue: backdrop)

        var orange: NSColor?
        try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            orange = NSColor.systemOrange.usingColorSpace(.sRGB)
        }
        let tint = try #require(orange)
        let tintLuminance = Self.luminance(
            red: Double(tint.redComponent),
            green: Double(tint.greenComponent),
            blue: Double(tint.blueComponent)
        )

        #expect(Self.contrast(1, backdropLuminance) >= 4.5)
        #expect(Self.contrast(tintLuminance, backdropLuminance) >= 4.5)
    }

    private static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
