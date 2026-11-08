import AppKit
import AVFoundation
import SceneKit
import simd
import Testing
@testable import Pilot

@Suite("Mock-ups model")
@MainActor
struct MockupModelTests {
    @Test("Each device exposes its reference catalog across every aspect ratio")
    func deviceLayouts() {
        #expect(Set(MockupLayout.allCases.map(\.id)).count == MockupLayout.allCases.count)
        for device in MockupDevice.allCases {
            let expectedCount = device == .macBookPro14 ? 7 : device == .iPadPro13 ? 8 : 19
            #expect(MockupLayout.referenceLayouts(for: device).count == expectedCount)
            for layout in MockupLayout.available(for: device) {
                let devices = layout.devices(for: device)
                #expect(devices.count == layout.screenCount)
                for aspect in MockupAspectRatio.presets {
                    let canvas = CGSize(width: 600 * aspect.ratio, height: 600)
                    let positions = layout.placements(for: device, in: canvas, sizes: devices.map(MockupLayoutButton.silhouetteSize))
                    #expect(positions.count == devices.count)
                    #expect(positions.allSatisfy { $0.scale.isFinite && $0.scale > 0 && $0.center.x.isFinite && $0.center.y.isFinite })
                    #expect(positions.allSatisfy { $0.center.x >= 0 && $0.center.x <= canvas.width })
                }
            }
        }
        #expect(MockupLayout.responsive.devices(for: .iPhone17) == [.iPhone17, .macBookPro14])
        #expect(MockupLayout.responsive.devices(for: .iPadPro13) == [.iPhone18Pro, .macBookPro14])
    }

    @Test("Layouts keep independent screenshots when slots are hidden and restored")
    func layoutContentSurvivesSwitches() {
        let document = MockupDocument()
        document.layout = .tripleFan
        let images = (0..<3).map { _ in NSImage(size: CGSize(width: 10, height: 20)) }
        for index in images.indices {
            document.selectedScreen = index
            document.screenshot = images[index]
        }
        document.kind = .video
        document.rotation = 30
        document.selectLayout(.centered)
        #expect(document.selectedScreen == 0)
        #expect(document.rotation == 0)
        #expect(document.kind == .video)
        document.device = .macBookPro14
        document.selectLayout(.pair)
        for index in images.indices { #expect(document.screenshot(at: index) === images[index]) }
        document.selectedScreen = 1
        document.screenshot = nil
        #expect(document.screenshot(at: 0) === images[0])
        #expect(document.screenshot(at: 1) == nil)
        #expect(document.screenshot(at: 2) === images[2])
    }

    @Test("Layout geometry scales with export resolution and deliberately crops details")
    func layoutFraming() throws {
        for device in MockupDevice.allCases {
            for layout in MockupLayout.available(for: device) {
                let sizes = layout.devices(for: device).map(MockupLayoutButton.silhouetteSize)
                let preview = layout.placements(for: device, in: CGSize(width: 400, height: 300), sizes: sizes)
                let export = layout.placements(for: device, in: CGSize(width: 3000, height: 2250), sizes: sizes)
                for (a, b) in zip(preview, export) {
                    #expect(abs(a.center.x * 7.5 - b.center.x) < 0.001)
                    #expect(abs(a.center.y * 7.5 - b.center.y) < 0.001)
                    #expect(abs(a.scale * 7.5 - b.scale) < 0.001)
                }
            }
        }
        let size = MockupLayoutButton.silhouetteSize(.iPhone18Pro)
        let canvas = CGSize(width: 400, height: 300)
        let top = try #require(MockupLayout.topCloseUp.placements(for: .iPhone18Pro, in: canvas, sizes: [size]).first)
        let bottom = try #require(MockupLayout.bottomCloseUp.placements(for: .iPhone18Pro, in: canvas, sizes: [size]).first)
        #expect(top.center.y - size.height * top.scale / 2 < 0)
        #expect(bottom.center.y + size.height * bottom.scale / 2 > canvas.height)
        #expect(abs(top.center.y + bottom.center.y - canvas.height) < 0.001)
    }

    @Test("Multi-device scenes isolate materials and export the same static pose in video")
    func layoutRendering() throws {
        let document = MockupDocument()
        document.device = .iPhone17
        document.layout = .tripleFan
        document.background = .none
        document.motion = .still
        let stage = MockupStageView(document: document)
        stage.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        stage.layoutSubtreeIfNeeded()
        stage.update()
        #expect(stage.models.count == 3)
        let screens = stage.models.compactMap { $0.screens.first }
        #expect(screens.count == 3)
        #expect(screens[0] !== screens[1] && screens[1] !== screens[2])
        let untouched = screens[0].emission.contents as? NSImage
        document.selectedScreen = 1
        document.screenshot = NSImage(size: CGSize(width: 100, height: 200))
        stage.update()
        #expect((screens[0].emission.contents as? NSImage) === untouched)
        let size = CGSize(width: 400, height: 300)
        let transforms = stage.models.map { $0.node.parent!.transform }
        let photo = try #require(stage.render(size: size, time: nil))
        let video = try #require(stage.render(size: size, time: 0))
        // SceneKit's output dithers between snapshots; compare decoded pixels
        // instead of TIFF containers, allowing one byte of average GPU noise.
        #expect(try pixelDifference(photo, video) < 1)
        _ = try #require(stage.render(size: CGSize(width: 180, height: 320), time: nil))
        let restored = try #require(stage.render(size: size, time: nil))
        #expect(try pixelDifference(photo, restored) < 1)
        for (model, transform) in zip(stage.models, transforms) {
            #expect(SCNMatrix4EqualToMatrix4(model.node.parent!.transform, transform))
        }
        if let path = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"] {
            for (name, image) in [("photo-check", photo), ("video-check", video), ("restored-check", restored)] {
                let data = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        document.layout = .centered
        stage.update()
        #expect(stage.models.count == 1)
        document.layout = .responsive
        stage.update()
        #expect(stage.models.count == 2)
        #expect(stage.models[1].hasHinge)
    }

    @Test("Laptop crops and tablet alignments use their distinct reference framing")
    func wideDeviceFraming() throws {
        let canvas = CGSize(width: 400, height: 400)
        func placement(_ layout: MockupLayout, _ device: MockupDevice) throws -> MockupLayout.Placement {
            try #require(layout.placements(for: device, in: canvas, sizes: [MockupLayoutButton.silhouetteSize(device)]).first)
        }
        let left = try placement(.leftCloseUp, .macBookPro14)
        let right = try placement(.rightCloseUp, .macBookPro14)
        #expect(left.center.x - left.scale / 2 < 0)
        #expect(right.center.x + right.scale / 2 > canvas.width)
        #expect(left.center.y < canvas.height / 2 && right.center.y == left.center.y)
        #expect(abs(left.center.x + right.center.x - canvas.width) < 0.001)
        let top = try placement(.topAligned, .iPadPro13)
        let bottom = try placement(.bottomAligned, .iPadPro13)
        #expect(top.center.y > canvas.height / 2 && bottom.center.y < canvas.height / 2)
        #expect(top.scale == bottom.scale)
        #expect(try placement(.angled, .iPadPro13).rotation == 8)
        for device in [MockupDevice.iPadPro13, .macBookPro14] {
            #expect(!MockupLayout.available(for: device).contains(.tripleFan))
            let sizes = Array(repeating: MockupLayoutButton.silhouetteSize(device), count: 2)
            let pair = MockupLayout.pair.placements(for: device, in: canvas, sizes: sizes)
            #expect(pair[0].center.y == pair[1].center.y)
            #expect(pair[0].center.x + pair[0].scale / 2 < pair[1].center.x - pair[1].scale / 2)
            let totalWidth = pair[1].center.x - pair[0].center.x + pair[0].scale
            #expect(totalWidth > canvas.width * 0.9 && totalWidth < canvas.width * 0.93)
        }
        let overlap = MockupLayout.pairOverlap.slots(for: .iPadPro13)
        #expect(overlap[0].scale == 1 && overlap[1].scale == 1)
        #expect(overlap[0].y > overlap[1].y && overlap[0].layer < overlap[1].layer)
    }

    @Test("Device switches and stale preferences cannot retain unsupported layouts")
    func deviceLayoutSelection() throws {
        let document = MockupDocument()
        document.layout = .tripleFan
        document.selectedScreen = 2
        let image = NSImage(size: CGSize(width: 10, height: 20))
        document.screenshot = image
        document.device = .macBookPro14
        #expect(document.layout == .centered && document.selectedScreen == 0)
        #expect(document.screenshot(at: 2) === image)
        document.layout = .leftCloseUp
        document.device = .iPadPro13
        #expect(document.layout == .centered)
        document.layout = .pairFan
        document.device = .iPhone17
        #expect(document.layout == .pairFan)
        let suite = "mockup-stale-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MockupDevice.macBookPro14.rawValue, forKey: "mockups.device")
        defaults.set(MockupLayout.tripleFan.rawValue, forKey: "mockups.layout")
        #expect(MockupsViewController(defaults: defaults).document.layout == .centered)
    }

    @Test("Wide-device compositions render the same pose in photo and video", arguments: [MockupDevice.iPadPro13, .macBookPro14])
    func wideDeviceRendering(device: MockupDevice) throws {
        let document = MockupDocument()
        document.device = device
        document.layout = device == .iPadPro13 ? .pairFan : .pair
        document.motion = .still
        let stage = MockupStageView(document: document)
        stage.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        stage.layoutSubtreeIfNeeded()
        stage.update()
        #expect(stage.models.count == 2)
        let bounds = MockupDeviceLibrary.visibleBounds(try #require(stage.models.first).node)
        let actual = bounds.max - bounds.min
        let silhouette = MockupLayoutButton.silhouetteSize(device)
        #expect(abs(CGFloat(actual.y / actual.x) - silhouette.height / silhouette.width) < 0.08)
        let photo = try #require(stage.render(size: stage.bounds.size, time: nil))
        let video = try #require(stage.render(size: stage.bounds.size, time: 0))
        #expect(try pixelDifference(photo, video) < 1)
    }

    private func pixelDifference(_ first: NSImage, _ second: NSImage) throws -> Double {
        func pixels(_ image: NSImage) throws -> [UInt8] {
            let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let context = try #require(CGContext(data: nil, width: cgImage.width, height: cgImage.height,
                                                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            let data = try #require(context.data)
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: cgImage.width * cgImage.height * 4))
        }
        let a = try pixels(first), b = try pixels(second)
        #expect(a.count == b.count)
        return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }

    @Test("The layout picker is reachable, applies layouts, and restores its selection")
    func layoutPicker() throws {
        let suite = "mockup-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MockupLayout.pairFan.rawValue, forKey: "mockups.layout")
        let controller = MockupsViewController(defaults: defaults)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1280, height: 900)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.document.layout == .pairFan)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(controller.view).compactMap { $0 as? MockupLayoutButton }
        #expect(buttons.map(\.layout) == controller.document.availableLayouts)
        #expect(buttons.allSatisfy { $0.frame.width > 150 && $0.frame.height == 124 })
        #expect(buttons.allSatisfy { !$0.isFlipped }, "Preview geometry uses a bottom-left origin")
        let canvas = try #require(descendants(controller.view).first { $0 is MockupStageView })
        #expect(canvas.frame.width > 400 && canvas.frame.height > 400)
        let colorField = try #require(descendants(controller.view).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Backdrop color value" })
        #expect(colorField.frame.width >= 96)
        let triple = try #require(buttons.first { $0.layout == .tripleFan })
        triple.performClick(nil)
        #expect(controller.document.layout == .tripleFan)
        controller.updatePresentation(isActive: true, isSelected: true)
        #expect(defaults.string(forKey: "mockups.layout") == MockupLayout.tripleFan.rawValue)
        let picker = try #require(descendants(controller.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityIdentifier() == "mockups.device-picker" })
        for device in [MockupDevice.macBookPro14, .iPadPro13, .iPhoneDuo, .iPhone17] {
            picker.selectItem(withTitle: device.name)
            picker.sendAction(picker.action, to: picker.target)
            controller.updatePresentation(isActive: true, isSelected: true)
            controller.view.layoutSubtreeIfNeeded()
            let currentButtons = descendants(controller.view).compactMap { $0 as? MockupLayoutButton }
            #expect(currentButtons.map(\.layout) == MockupLayout.available(for: device))
            #expect(currentButtons.filter { $0.state == .on }.map(\.layout) == [controller.document.layout])
            #expect(currentButtons.allSatisfy { $0.frame.width > 150 })
            #expect(currentButtons.first?.enclosingScrollView?.contentView.bounds.origin.y == 0)
        }
        controller.updatePresentation(isActive: false, isSelected: false)
    }

    @Test("Layout review renders every composition and device family")
    func layoutReview() throws {
        guard let path = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = MockupDocument()
        document.device = .iPhone17
        document.background = .gradient(MockupGradient.presets[0])
        let stage = MockupStageView(document: document)
        stage.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        stage.layoutSubtreeIfNeeded()
        func save(_ image: NSImage, name: String) throws {
            let data = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        for device in [MockupDevice.iPhone17, .iPadPro13, .macBookPro14] {
            document.device = device
            for layout in MockupLayout.available(for: device) {
                document.layout = layout
                stage.update()
                try save(try #require(stage.render(size: CGSize(width: 360, height: 360), time: nil)),
                         name: device.id + "-" + layout.id)
            }
        }
        for device in MockupDevice.allCases {
            document.device = device
            document.layout = .pair
            stage.update()
            try save(try #require(stage.render(size: CGSize(width: 400, height: 300), time: nil)), name: device.id)
        }
        let suite = "mockup-review-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MockupsViewController(defaults: defaults)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 1280, height: 900))
        controller.view.frame = CGRect(x: 0, y: 0, width: 1280, height: 900)
        window.appearance = NSAppearance(named: .darkAqua)
        for device in [MockupDevice.iPhone17, .iPadPro13, .macBookPro14] {
            controller.document.device = device
            controller.document.layout = .pair
            controller.updatePresentation(isActive: true, isSelected: true)
            window.contentView?.layoutSubtreeIfNeeded()
            let view = controller.view
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            try save(image, name: "studio-" + device.id)
        }
        controller.document.kind = .video
        controller.document.device = .iPhone17
        controller.document.applyMotion(.turntable)
        controller.document.isPlaying = false
        if let first = controller.document.timeline.keyframes.first { controller.document.selectKeyframe(first.id) }
        controller.updatePresentation(isActive: true, isSelected: true)
        window.contentView?.layoutSubtreeIfNeeded()
        let view = controller.view
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        try save(image, name: "studio-video-timeline")
        controller.updatePresentation(isActive: false, isSelected: false)
    }

    @Test("Backdrop colors default to Display P3; device finishes stay sRGB")
    func backdropIsDisplayP3() {
        #expect(MockupColor.palette.allSatisfy { $0.space == .displayP3 })
        #expect(MockupGradient.presets.allSatisfy { $0.start.space == .displayP3 && $0.end.space == .displayP3 })
        #expect(MockupDocument().background == .solid(MockupColor(hex: 0x7CF866, space: .displayP3)))
        #expect(MockupColor(hex: 0x7CF866, space: .displayP3).nsColor.colorSpace == .displayP3)
        #expect(MockupColor(hex: 0x7CF866).nsColor.colorSpace == .sRGB)
    }

    @Test("Each format shows the backdrop color and parses it back", arguments: MockupColorFormat.allCases)
    func formatsRoundTrip(format: MockupColorFormat) throws {
        let color = MockupColor(hex: 0x7CF866, space: .displayP3)
        let text = format.string(for: color)
        let parsed = try #require(format.color(from: text), "\(format.rawValue) couldn't parse \(text)")
        #expect(parsed.space == .displayP3)
        #expect(MockupColorFormat.hex.string(for: parsed) == "#7CF866" || format == .hsl || format == .hsv,
                "\(format.rawValue) \(text) round-tripped to \(MockupColorFormat.hex.string(for: parsed))")
        for channel in [parsed.red - color.red, parsed.green - color.green, parsed.blue - color.blue] {
            #expect(abs(channel) < 0.01, "\(format.rawValue) drifted by \(channel)")
        }
    }

    @Test("Formats render the expected text and reject malformed input")
    func formatText() {
        let color = MockupColor(hex: 0x7CF866, space: .displayP3)
        #expect(MockupColorFormat.hex.string(for: color) == "#7CF866")
        #expect(MockupColorFormat.rgb.string(for: color) == "124, 248, 102")
        #expect(MockupColorFormat.hex.color(from: "#fff") == MockupColor(hex: 0xFFFFFF, space: .displayP3))
        #expect(MockupColorFormat.rgb.color(from: "rgb(255, 0, 0)") == MockupColor(red: 1, green: 0, blue: 0))
        #expect(MockupColorFormat.hex.color(from: "#12345") == nil)
        #expect(MockupColorFormat.rgb.color(from: "300, 0, 0") == nil)
        #expect(MockupColorFormat.hex.color(from: "#7CF866", space: .sRGB)?.space == .sRGB)
        #expect(MockupColor.palette(in: .sRGB).allSatisfy { $0.space == .sRGB })
        #expect(color.interpreted(in: .sRGB).nsColor.colorSpace == .sRGB && color.interpreted(in: .sRGB).red == color.red,
                "Switching spaces keeps the values and changes the gamut")
        #expect(!MockupColorFormat.allCases.map(\.rawValue).contains("Display P3"), "P3 is a separate setting, not a format")
        #expect(MockupColorFormat.hsl.color(from: "120, 100") == nil)
        #expect(MockupColorFormat.hex.color(from: String(repeating: "f", count: 100)) == nil)
    }

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

    @Test("A single-color model retints only its tinted shell, keeping shading in proportion")
    func recolorRule() throws {
        let gold = MockupRecolor(source: MockupDevice.iPhoneAirBodyTone, target: 0xD9CCB4)
        let body = MockupRecolor.components(MockupDevice.iPhoneAirBodyTone)
        let retinted = try #require(gold.retint(body))
        let target = MockupRecolor.components(0xD9CCB4)
        #expect(abs(retinted.red - target.red) < 0.005 && abs(retinted.blue - target.blue) < 0.005)
        #expect(gold.retint((0.35, 0.35, 0.35)) == nil, "Neutral grays keep Apple's values")
        #expect(gold.retint((0.02, 0.03, 0.04)) == nil, "Near-black parts keep Apple's values")
        let highlight = try #require(gold.retint((0.97, 0.99, 1.0)))
        #expect(highlight.red <= 1 && highlight.green <= 1 && highlight.blue <= 1)
    }

    @Test("iPhone Air offers Apple's four finishes, each with a distinct frame")
    func iPhoneAirFinishes() throws {
        let finishes = MockupDevice.iPhoneAir.finishes
        #expect(finishes.map(\.name) == ["Sky Blue", "Light Gold", "Cloud White", "Space Black"])
        #expect(finishes[0].recolor == nil, "Sky Blue is Apple's authored model")
        let body = MockupRecolor.components(MockupDevice.iPhoneAirBodyTone)
        func skyTintedMaterials(_ finish: MockupFinish) throws -> Int {
            let model = try MockupDeviceLibrary.model(for: .iPhoneAir, finish: finish)
            var count = 0
            model.node.enumerateHierarchy { node, _ in
                for material in node.geometry?.materials ?? [] {
                    guard let color = (material.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB) else { continue }
                    // Apple's authored Sky Blue frame tone.
                    if abs(color.redComponent - body.red) < 0.03, abs(color.greenComponent - body.green) < 0.03,
                       abs(color.blueComponent - body.blue) < 0.03 { count += 1 }
                }
            }
            return count
        }
        #expect(try skyTintedMaterials(finishes[0]) > 0)
        for finish in finishes.dropFirst() {
            #expect(try skyTintedMaterials(finish) == 0, "\(finish.name) still renders the Sky Blue frame")
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

    @Test("Motion presets generate valid, deterministic keyframe timelines")
    func motionPresets() {
        for motion in MockupMotion.allCases {
            let timeline = MockupTimeline.preset(motion, base: MockupPose())
            #expect(timeline.isValid && timeline.duration > 0)
            #expect(timeline.pose(at: 0.7) == timeline.pose(at: 0.7))
            #expect(timeline.pose(at: timeline.duration) == timeline.keyframes.last?.pose)
        }
        let reveal = MockupTimeline.preset(.openReveal, base: MockupPose())
        #expect(reveal.pose(at: 0).open == 0)
        #expect(reveal.pose(at: reveal.duration).open == 1)
    }

    @Test("Keyframe timelines interpolate every pose channel and clamp at the ends")
    func keyframeInterpolation() {
        let first = MockupPose(yaw: 0, pitch: 0.1, pan: -0.2, lift: -0.1, scale: 0.8, open: 0)
        let second = MockupPose(yaw: 1, pitch: 0.3, pan: 0.2, lift: 0.1, scale: 1.2, open: 1)
        var timeline = MockupTimeline(keyframes: [
            MockupKeyframe(pose: first, duration: 2, easing: .linear),
            MockupKeyframe(pose: second, duration: 1),
        ])
        #expect(timeline.duration == 3)
        #expect(timeline.startTime(at: 1) == 2)
        #expect(timeline.pose(at: -1) == first)
        #expect(timeline.pose(at: 0) == first)
        #expect(timeline.pose(at: 1) == MockupPose.lerp(first, second, 0.5))
        #expect(timeline.pose(at: 2) == second)
        #expect(timeline.pose(at: 4) == second)
        timeline.setEasing(.easeInOut, for: timeline.keyframes[0].id)
        #expect(timeline.pose(at: 1) != MockupPose.lerp(first, second, 0.5))
        for easing in MockupEasing.allCases {
            #expect(easing.value(at: 0) == 0)
            #expect(abs(easing.value(at: 1) - 1) < 0.000001)
            let values = stride(from: 0.0, through: 1.0, by: 0.05).map(easing.value)
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 0.000001 })
        }
    }

    @Test("Inserting, retiming, and removing diamonds preserves continuous segments")
    func keyframeEditing() throws {
        let first = MockupKeyframe(pose: MockupPose(), duration: 2, easing: .linear)
        let second = MockupKeyframe(pose: MockupPose(yaw: 1), duration: 2, easing: .easeOut)
        var timeline = MockupTimeline(keyframes: [first, second])
        let inserted = timeline.addKeyframe(at: 1, pose: MockupPose(yaw: 0.5))
        let insertedID = try #require(inserted)
        #expect(timeline.keyframes.map(\.duration) == [1, 1, 2])
        #expect(timeline.keyframes.map(\.easing) == [.linear, .linear, .easeOut])
        timeline.moveKeyframe(insertedID, to: 1.5)
        #expect(timeline.keyframes.map(\.duration) == [1.5, 0.5, 2])
        #expect(timeline.duration == 4)
        timeline.setDuration(2, for: insertedID)
        #expect(timeline.duration == 5.5)
        timeline.removeKeyframe(insertedID)
        #expect(timeline.keyframes.map(\.id) == [first.id, second.id])
        #expect(timeline.keyframes.map(\.duration) == [3.5, 2])
        let appended = timeline.addKeyframe(at: timeline.duration, pose: MockupPose(yaw: 2))
        let appendedID = try #require(appended)
        #expect(timeline.keyframes.last?.id == appendedID)
        #expect(timeline.duration == 7.5)
        let encoded = try JSONEncoder().encode(timeline)
        #expect(try JSONDecoder().decode(MockupTimeline.self, from: encoded) == timeline)
        #expect(timeline.isValid)
        #expect(!MockupTimeline(keyframes: []).isValid)
    }

    @Test("The document captures inspector poses into selected keyframes")
    func documentKeyframeEditing() throws {
        let document = MockupDocument()
        document.kind = .video
        document.applyMotion(.still)
        document.isPlaying = false
        document.seek(to: document.timeline.duration)
        document.positionX = 0.2
        document.tiltY = 0.4
        document.addKeyframe()
        #expect(document.timeline.keyframes.count == 2)
        #expect(document.selectedKeyframe?.pose.pan == 0.2)
        #expect(document.selectedKeyframe?.pose.yaw == 0.4)
        #expect(document.motion == .custom)
        document.rotation = 15
        document.updateSelectedPose()
        #expect(abs(try #require(document.selectedKeyframe).pose.roll - 15 * .pi / 180) < 0.000001)
        let firstID = try #require(document.timeline.keyframes.first).id
        document.selectKeyframe(firstID)
        document.setSelectedDuration(1.5)
        document.setSelectedEasing(.linear)
        #expect(document.selectedKeyframe?.duration == 1.5)
        #expect(document.selectedKeyframe?.easing == .linear)
        document.deleteSelectedKeyframe()
        #expect(document.timeline.keyframes.count == 1)
        #expect(document.selectedKeyframeID == document.timeline.keyframes.first?.id)
    }

    @Test("Adding during playback captures the visible interpolated pose")
    func addDuringPlayback() {
        let document = MockupDocument()
        document.kind = .video
        document.applyMotion(.turntable)
        document.playhead = 3
        let expected = document.timeline.pose(at: 3)
        #expect(document.basePose != expected)
        document.addKeyframe()
        #expect(document.selectedKeyframe?.pose == expected)
        #expect(!document.isPlaying)
    }

    @Test("The fixed first diamond does not become a custom edit when dragged")
    func firstKeyframeStaysFixed() {
        let document = MockupDocument()
        document.kind = .video
        document.applyMotion(.still)
        let timeline = document.timeline
        document.moveSelectedKeyframe(to: 1)
        #expect(document.timeline == timeline)
        #expect(document.motion == .still)
    }

    @Test("Video mode presents the native timeline and restores its saved keyframes")
    func timelinePresentation() throws {
        let suite = "mockup-timeline-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MockupKind.video.rawValue, forKey: "mockups.kind")
        let controller = MockupsViewController(defaults: defaults)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1440, height: 1000)
        controller.view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let timeline = try #require(descendants(controller.view).compactMap { $0 as? MockupTimelineView }.first)
        #expect(!timeline.isHidden && timeline.frame.height >= 160)
        controller.document.applyMotion(.still)
        controller.document.seek(to: 3)
        controller.document.addKeyframe()
        controller.updatePresentation(isActive: true, isSelected: true)
        let data = try #require(defaults.data(forKey: "mockups.timeline"))
        let restored = try JSONDecoder().decode(MockupTimeline.self, from: data)
        #expect(restored == controller.document.timeline)
        controller.updatePresentation(isActive: false, isSelected: false)
    }

    @Test("Keyframe poses drive the actual SceneKit video frames")
    func timelineRendering() throws {
        let document = MockupDocument()
        document.kind = .video
        document.device = .iPhone17
        document.isPlaying = false
        document.timeline = MockupTimeline(keyframes: [
            MockupKeyframe(pose: MockupPose(pan: -0.2), duration: 0.5, easing: .linear),
            MockupKeyframe(pose: MockupPose(pan: 0.2), duration: 0.5),
        ])
        let stage = MockupStageView(document: document)
        stage.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        stage.layoutSubtreeIfNeeded()
        stage.update()
        let first = try #require(stage.render(size: stage.bounds.size, time: 0))
        let second = try #require(stage.render(size: stage.bounds.size, time: 0.5))
        #expect(try pixelDifference(first, second) > 1)
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

    @Test("The exporter writes the exact keyframe timeline from the live stage")
    func exportsKeyframeTimeline() async throws {
        let document = MockupDocument()
        document.kind = .video
        document.device = .iPhone17
        document.isPlaying = false
        document.timeline = MockupTimeline(keyframes: [
            MockupKeyframe(pose: MockupPose(pan: -0.15), duration: 0.25, easing: .linear),
            MockupKeyframe(pose: MockupPose(pan: 0.15), duration: 0.25),
        ])
        let stage = MockupStageView(document: document)
        stage.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        stage.layoutSubtreeIfNeeded()
        stage.update()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mockup-timeline-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = MockupVideoExporter.Settings(size: stage.bounds.size, duration: document.timeline.duration)
        try await MockupVideoExporter().export(to: url, settings: settings, progress: { _ in }, render: { time in
            stage.render(size: settings.size, time: time)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        })
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - document.timeline.duration) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == stage.bounds.size)
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
