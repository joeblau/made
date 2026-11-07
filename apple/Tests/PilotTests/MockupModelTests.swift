import AppKit
import AVFoundation
import SceneKit
import simd
import Testing
@testable import Pilot

@Suite("Mock-ups model")
@MainActor
struct MockupModelTests {
    @Test("Aspect presets have unique ids and positive ratios")
    func presetsAreWellFormed() {
        let ids = MockupAspectRatio.presets.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(MockupAspectRatio.presets.allSatisfy { $0.ratio > 0 })
        #expect(MockupAspectRatio.preset(id: "x-header")?.label == "3:1")
        #expect(MockupAspectRatio.preset(id: "golden")?.label == "1.62:1")
    }

    @Test("Artboards fit inside the inset bounds at the requested ratio")
    func fitKeepsRatio() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let wide = MockupAspectRatio.fit(ratio: 16.0 / 9.0, in: bounds, inset: 20)
        #expect(bounds.insetBy(dx: 20, dy: 20).contains(wide))
        #expect(abs(wide.width / wide.height - 16.0 / 9.0) < 0.01)
        let tall = MockupAspectRatio.fit(ratio: 9.0 / 16.0, in: bounds, inset: 20)
        #expect(tall.height == 560)
        #expect(abs(tall.midX - bounds.midX) <= 1)
        #expect(MockupAspectRatio.fit(ratio: 1, in: .zero) == .zero)
    }

    @Test("Every device has at least one finish and a sane panel")
    func devicesAreWellFormed() {
        for device in MockupDevice.allCases {
            #expect(!device.finishes.isEmpty)
            #expect(device.screenPixels.width > 0 && device.screenPixels.height > 0)
        }
        let document = MockupDocument()
        document.finishIndex = 99
        #expect(document.finish == document.device.finishes.last)
        document.device = .iPadPro13
        #expect(document.finishIndex == 0)
    }

    @Test("Every bundled Apple model loads with a screen, facing the camera at the normalised span")
    func bundledModelsLoad() throws {
        for device in MockupDevice.allCases {
            for finish in device.finishes {
                let model = try MockupDeviceLibrary.model(for: device, finish: finish)
                #expect(!model.displays.isEmpty, "\(device) \(finish.name) has no screen")
                let bounds = MockupDeviceLibrary.visibleBounds(model.node)
                let size = bounds.max - bounds.min
                #expect(abs(max(size.x, size.y, size.z) - MockupDeviceModel.span) < 0.5, "\(device) is not normalised")
                // The primary screen faces +Z (toward the camera).
                let primary = try #require(MockupDeviceLibrary.screens(in: model.node).max { $0.area < $1.area })
                let frame = try #require(MockupDeviceLibrary.screenFrame(primary.node))
                #expect(frame.normal.z > 0.8, "\(device) \(finish.name) faces \(frame.normal)")
                #expect(frame.up.y > 0.8 || device.keepsBaseLevel, "\(device) is not upright")
                let landscape = device.screenPixels.width > device.screenPixels.height
                #expect((frame.width > frame.height) == landscape, "\(device) panel orientation")
            }
        }
    }

    @Test("Hinged models open and close; slabs ignore it")
    func hinges() throws {
        let laptop = try MockupDeviceLibrary.model(for: .macBookPro14, finish: MockupDevice.macBookPro14.finishes[0])
        #expect(laptop.hasHinge)
        let open = MockupDeviceLibrary.visibleBounds(laptop.node)
        laptop.setOpen(0)
        let closed = MockupDeviceLibrary.visibleBounds(laptop.node)
        #expect((closed.max.y - closed.min.y) < (open.max.y - open.min.y) * 0.3, "closing the lid must flatten the laptop")
        let phone = try MockupDeviceLibrary.model(for: .iPhone17, finish: MockupDevice.iPhone17.finishes[0])
        #expect(!phone.hasHinge)
    }

    @Test("The Duo folds through Xcode's rig when the pinned file is installed, else loads the static model")
    func duoFold() throws {
        let duo = try MockupDeviceLibrary.model(for: .iPhoneDuo, finish: MockupDevice.iPhoneDuo.finishes[0])
        #expect(duo.displays.count >= 1)
        guard DuoRig.locate() != nil else {
            #expect(!duo.hasHinge)
            return
        }
        #expect(duo.hasHinge)
        // Skinning deforms on the GPU, so measure the two half joints of the
        // pinned rig: parallel when flat, folded onto each other when closed.
        let left = try #require(duo.node.childNode(withName: "pXhjqgUFTJHRqSk", recursively: true))
        let right = try #require(duo.node.childNode(withName: "mXxhFfVnnQRwgSU", recursively: true))
        // Dot of the halves' local Y (screen-normal) axes: +1 flat, 0 at a
        // right angle, −1 folded shut.
        func alignment() -> Float {
            simd_dot(left.simdWorldOrientation.act(simd_float3(0, 1, 0)), right.simdWorldOrientation.act(simd_float3(0, 1, 0)))
        }
        duo.setOpen(1)
        #expect(alignment() > 0.98, "flat open, got \(alignment())")
        duo.setOpen(0.5)
        #expect(abs(alignment()) < 0.1, "half open, got \(alignment())")
        duo.setOpen(0)
        #expect(alignment() < -0.98, "closed, got \(alignment())")
    }

    @Test("Duo rig lookup ignores unpinned files and maps fold amount onto the symmetric clip")
    func duoRigLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("Xcode-99.app").appendingPathComponent(DuoRig.relativePath)
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not the rig".utf8).write(to: fake)
        #expect(DuoRig.locate(searching: [root]) == nil)
        #expect(abs(DuoRig.time(open: 1) - 260.0 / 24) < 1e-9)
        #expect(abs(DuoRig.time(open: 0) - 380.0 / 24) < 1e-9)
    }

    @Test("Screenshots are cropped to the panel aspect and turned for rotated panels")
    func screenFitting() throws {
        let material = SCNMaterial()
        let source = NSImage(size: NSSize(width: 1000, height: 1000))
        let wide = MockupDeviceModel.fitted(source, display: .init(material: material, aspect: 2, quarterTurns: 0))
        #expect(wide.size == NSSize(width: 1000, height: 500))
        let turned = MockupDeviceModel.fitted(source, display: .init(material: material, aspect: 2, quarterTurns: 1))
        #expect(turned.size == NSSize(width: 500, height: 1000))
    }

    @Test("Motion presets are pure functions of time and loop")
    func motionLoops() {
        for motion in MockupMotion.allCases {
            #expect(motion.pose(at: 0.7) == motion.pose(at: 0.7))
            let a = motion.pose(at: 0.25), b = motion.pose(at: 0.25 + motion.duration)
            #expect(abs(a.yaw - b.yaw) < 1e-9 && abs(a.open - b.open) < 1e-9)
        }
        let reveal = MockupMotion.openReveal
        #expect(reveal.pose(at: 0).open == 0)
        #expect(reveal.pose(at: reveal.duration * 0.95).open == 1)
    }

    @Test("Social video settings are even, 1080 on the short side, capped at 1920")
    func socialVideoSettings() {
        let vertical = MockupVideoExporter.Settings.social(ratio: 9.0 / 16.0, duration: 6)
        #expect(vertical.size == CGSize(width: 1080, height: 1920))
        let square = MockupVideoExporter.Settings.social(ratio: 1, duration: 6)
        #expect(square.size == CGSize(width: 1080, height: 1080))
        let header = MockupVideoExporter.Settings.social(ratio: 3, duration: 6)
        #expect(header.size == CGSize(width: 1920, height: 640))
        let golden = MockupVideoExporter.Settings.social(ratio: 1.618, duration: 6)
        #expect(Int(golden.size.width) % 2 == 0 && Int(golden.size.height) % 2 == 0)
        #expect(vertical.frameCount == 180)
    }

    @Test("The exporter writes a playable H.264 MP4")
    func exportsH264() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mockup-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = MockupVideoExporter.Settings(size: CGSize(width: 320, height: 240), duration: 0.5)
        let frame = try #require(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        try await MockupVideoExporter().export(to: url, settings: settings, progress: { _ in }, render: { _ in frame })
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let formats = try await track.load(.formatDescriptions)
        #expect(formats.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_H264)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 240))
    }

    @Test("Image loader decodes small images and rejects junk and oversized headers")
    func imageLoaderBounds() throws {
        let image = try MockupImageLoader.load(data: Self.png(width: 4, height: 8)).get()
        #expect(image.size == NSSize(width: 4, height: 8))

        #expect(MockupImageLoader.load(data: Data("not an image".utf8)) == .failure(.unreadable))
        let tooWide = try Self.png(width: MockupImageLoader.maxPixelEdge + 1, height: 1)
        #expect(MockupImageLoader.load(data: tooWide) == .failure(.dimensions))
        let atLimit = try Self.png(width: MockupImageLoader.maxPixelEdge, height: 1)
        #expect((try? MockupImageLoader.load(data: atLimit).get()) != nil)
        #expect(MockupImageLoader.load(data: Data(count: MockupImageLoader.maxBytes + 1)) == .failure(.tooLarge))
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
