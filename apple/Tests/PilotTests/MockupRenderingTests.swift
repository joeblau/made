import AppKit
import Testing
@testable import Pilot

@MainActor
@Suite struct MockupRenderingTests {
    private static let backdrop = MockupColor(red: 0, green: 1, blue: 0.24, space: .displayP3)

    private func stage(background: MockupBackground) -> MockupStageView {
        let document = MockupDocument()
        document.device = .iPhone17
        document.layout = MockupLayout.available(for: .iPhone17)[0]
        document.background = background
        document.screenshot = NSImage(size: CGSize(width: 390, height: 844), flipped: false) { rect in
            NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let stage = MockupStageView(document: document)
        stage.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        stage.layoutSubtreeIfNeeded()
        stage.update()
        return stage
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    }

    private func bytes(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> [Int] {
        let color = try #require(rep.colorAt(x: x * rep.pixelsWide / 100, y: y * rep.pixelsHigh / 100))
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    @Test("A Display P3 backdrop exports unclipped and the screen keeps its own blacks")
    func stillKeepsBackdropGamutAndScreenPixels() throws {
        let stage = stage(background: .solid(Self.backdrop))
        let image = try #require(stage.render(size: CGSize(width: 600, height: 600), time: nil, colorSpace: MockupRenderer.displayP3))
        let rep = try bitmap(image)
        #expect(rep.colorSpace.cgColorSpace?.name == CGColorSpace.displayP3)
        // sRGB output clipped this to 0/255/0.
        let corner = try bytes(rep, x: 3, y: 3)
        #expect(corner[0] <= 1 && corner[1] >= 254 && abs(corner[2] - 61) <= 2 && corner[3] == 255)
        // The screenshot's 10/255 black used to come out near 32.
        let screen = try bytes(rep, x: 50, y: 50)
        #expect(screen[0...2].allSatisfy { abs($0 - 10) <= 3 })

        let data = try #require(MockupRenderer.pngData(image))
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.colorSpace.cgColorSpace?.name == CGColorSpace.displayP3)
    }

    @Test("No backdrop still renders transparent; video frames stay sRGB")
    func transparencyAndVideoColorSpace() throws {
        let clear = try bitmap(try #require(stage(background: .none).render(size: CGSize(width: 300, height: 300), time: nil)))
        #expect(try bytes(clear, x: 3, y: 3)[3] == 0)
        let frame = try bitmap(try #require(stage(background: .solid(Self.backdrop)).render(size: CGSize(width: 300, height: 300), time: 0)))
        #expect(frame.colorSpace.cgColorSpace?.name == CGColorSpace.sRGB)
        #expect(try bytes(frame, x: 3, y: 3)[3] == 255)
    }

    @Test("Copy puts the exported PNG on the pasteboard")
    func copyWritesPNG() throws {
        let suite = "mockup-copy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MockupsViewController(defaults: defaults)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer { pasteboard.releaseGlobally() }
        controller.pasteboard = pasteboard
        controller.document.kind = .photo
        controller.document.background = .solid(Self.backdrop)
        controller.view.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        controller.updatePresentation(isActive: true, isSelected: true)
        controller.view.layoutSubtreeIfNeeded()
        defer { controller.updatePresentation(isActive: false, isSelected: false) }

        controller.copyToClipboard()

        let data = try #require(pasteboard.data(forType: .png))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(max(rep.pixelsWide, rep.pixelsHigh) == 3000)
        #expect(rep.colorSpace.cgColorSpace?.name == CGColorSpace.displayP3)
    }
}
