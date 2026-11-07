#!/usr/bin/env swift

import AppKit
import CoreImage
import CryptoKit
import Foundation
import ImageIO

private enum IconToolError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message): message
        }
    }
}

private struct Output {
    let relativePath: String
    let pixels: Int
    let appearance: Appearance
}

private enum Appearance {
    case standard
    case dark
    case tinted
}

private let scriptURL = URL(fileURLWithPath: #filePath)
private let appleRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
private let masterURL = appleRoot.appendingPathComponent("Brand/AppIconMaster.png")

private let macCatalog = "Sources/Pilot/Assets.xcassets/AppIcon.appiconset"
private let iOSCatalogs = [
    "Sources/Copilot/Assets.xcassets/AppIcon.appiconset",
    "Sources/Plotter/Assets.xcassets/AppIcon.appiconset",
]
private let watchCatalog = "Sources/Wingman/Wingman Watch App/Assets.xcassets/AppIcon.appiconset"

private var outputs: [Output] {
    let macSizes = [16, 32, 64, 128, 256, 512, 1024]
    let mac = macSizes.map {
        Output(relativePath: "\(macCatalog)/AppIcon-\($0).png", pixels: $0, appearance: .standard)
    }
    let iOS = iOSCatalogs.flatMap { catalog in
        [
            Output(relativePath: "\(catalog)/AppIcon-1024.png", pixels: 1024, appearance: .standard),
            Output(relativePath: "\(catalog)/AppIcon-dark-1024.png", pixels: 1024, appearance: .dark),
            Output(relativePath: "\(catalog)/AppIcon-tinted-1024.png", pixels: 1024, appearance: .tinted),
        ]
    }
    let watch = [
        Output(relativePath: "\(watchCatalog)/AppIcon-1024.png", pixels: 1024, appearance: .standard),
    ]
    return mac + iOS + watch
}

private func fail(_ message: String) throws -> Never {
    throw IconToolError.message(message)
}

private func imageProperties(at url: URL) throws -> (
    width: Int,
    height: Int,
    hasAlpha: Bool,
    colorModel: String,
    profile: String
) {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
        try fail("Cannot read PNG metadata: \(url.path)")
    }
    guard
        let width = raw[kCGImagePropertyPixelWidth] as? Int,
        let height = raw[kCGImagePropertyPixelHeight] as? Int
    else {
        try fail("PNG has no pixel dimensions: \(url.path)")
    }
    return (
        width,
        height,
        raw[kCGImagePropertyHasAlpha] as? Bool ?? false,
        raw[kCGImagePropertyColorModel] as? String ?? "unknown",
        raw[kCGImagePropertyProfileName] as? String ?? "unknown"
    )
}

private func loadMaster() throws -> NSImage {
    let masterData = try Data(contentsOf: masterURL)
    let expectedSHA256 = "43621e02055dce6da8352f2b7184d1f9d5aeb907511782d815ebb191e0c2662f"
    let actualSHA256 = SHA256.hash(data: masterData).map { String(format: "%02x", $0) }.joined()
    guard actualSHA256 == expectedSHA256 else {
        try fail("Authoritative icon master checksum changed; update the documented source intentionally")
    }
    let properties = try imageProperties(at: masterURL)
    guard properties.width == 1024, properties.height == 1024 else {
        try fail("Authoritative icon master must be 1024x1024")
    }
    guard !properties.hasAlpha else {
        try fail("Authoritative icon master must be opaque")
    }
    guard properties.colorModel == "RGB" else {
        try fail("Authoritative icon master must use an RGB color model")
    }
    guard properties.profile.localizedCaseInsensitiveContains("sRGB") else {
        try fail("Authoritative icon master must embed an sRGB profile")
    }
    guard let image = NSImage(contentsOf: masterURL) else {
        try fail("Cannot decode icon master at \(masterURL.path)")
    }
    return image
}

private func renderedImage(from source: NSImage, pixels: Int, appearance: Appearance) throws -> NSBitmapImageRep {
    var proposedRect = NSRect(origin: .zero, size: source.size)
    guard let sourceCGImage = source.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
        try fail("Cannot decode master pixels")
    }

    let sourceToDraw: CGImage
    switch appearance {
    case .standard:
        sourceToDraw = sourceCGImage
    case .dark:
        guard
            let input = Optional(CIImage(cgImage: sourceCGImage)),
            let output = CIFilter(
                name: "CIExposureAdjust",
                parameters: [kCIInputImageKey: input, kCIInputEVKey: -0.08]
            )?.outputImage,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let cgImage = CIContext(options: [.workingColorSpace: colorSpace])
                .createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
        else {
            try fail("Cannot render dark appearance")
        }
        sourceToDraw = cgImage
    case .tinted:
        guard
            let input = Optional(CIImage(cgImage: sourceCGImage)),
            let monochrome = CIFilter(
                name: "CIColorMonochrome",
                parameters: [
                    kCIInputImageKey: input,
                    kCIInputColorKey: CIColor(red: 1, green: 1, blue: 1),
                    kCIInputIntensityKey: 1,
                ]
            )?.outputImage,
            let contrasted = CIFilter(
                name: "CIColorControls",
                parameters: [
                    kCIInputImageKey: monochrome,
                    kCIInputContrastKey: 1.18,
                    kCIInputSaturationKey: 0,
                ]
            )?.outputImage,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let cgImage = CIContext(options: [.workingColorSpace: colorSpace])
                .createCGImage(contrasted, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
        else {
            try fail("Cannot render tinted appearance")
        }
        sourceToDraw = cgImage
    }

    guard
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: pixels * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else {
        try fail("Cannot allocate \(pixels)x\(pixels) icon bitmap")
    }
    context.interpolationQuality = .high
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.draw(sourceToDraw, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let result = context.makeImage() else {
        try fail("Cannot finish \(pixels)x\(pixels) icon bitmap")
    }
    return NSBitmapImageRep(cgImage: result)
}

private func generate() throws {
    try runIconPython("build-icon-layers.py")
    let master = try loadMaster()
    for output in outputs {
        let destination = appleRoot.appendingPathComponent(output.relativePath)
        let bitmap = try renderedImage(from: master, pixels: output.pixels, appearance: output.appearance)
        guard let data = bitmap.representation(using: .png, properties: [.interlaced: false]) else {
            try fail("Cannot encode \(destination.path)")
        }
        try data.write(to: destination, options: .atomic)
    }
    print("Generated native vector layers and \(outputs.count) legacy catalog images from \(masterURL.path)")
}

private func validateCatalog(at relativePath: String) throws {
    let catalogURL = appleRoot.appendingPathComponent(relativePath)
    let contentsURL = catalogURL.appendingPathComponent("Contents.json")
    let data = try Data(contentsOf: contentsURL)
    guard
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let images = object["images"] as? [[String: Any]],
        !images.isEmpty
    else {
        try fail("Invalid asset catalog manifest: \(contentsURL.path)")
    }

    for image in images {
        guard let filename = image["filename"] as? String, !filename.isEmpty else {
            try fail("Every AppIcon slot must name an image: \(contentsURL.path)")
        }
        let fileURL = catalogURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try fail("Missing catalog image: \(fileURL.path)")
        }
        let properties = try imageProperties(at: fileURL)
        guard !properties.hasAlpha,
              properties.colorModel == "RGB",
              properties.profile.localizedCaseInsensitiveContains("sRGB") else {
            try fail("App icons must be opaque sRGB PNGs: \(fileURL.path)")
        }
        guard let sizeString = image["size"] as? String,
              let points = Double(sizeString.split(separator: "x")[0])
        else {
            try fail("Invalid AppIcon slot size: \(contentsURL.path)")
        }
        let scaleString = image["scale"] as? String ?? "1x"
        guard let scale = Double(scaleString.dropLast()) else {
            try fail("Invalid AppIcon slot scale: \(contentsURL.path)")
        }
        let expected = Int((points * scale).rounded())
        guard properties.width == expected, properties.height == expected else {
            try fail("\(filename) is \(properties.width)x\(properties.height); expected \(expected)x\(expected)")
        }
    }

    if iOSCatalogs.contains(relativePath) {
        let appearances = Set(images.compactMap { image in
            (image["appearances"] as? [[String: String]])?.first?["value"]
        })
        guard images.count == 3, appearances == Set(["dark", "tinted"]) else {
            try fail("iOS AppIcon catalogs require standard, dark, and tinted appearances")
        }
    }
}

private func validateSafeArea() throws {
    let masterData = try Data(contentsOf: masterURL)
    guard
        let bitmap = NSBitmapImageRep(data: masterData),
        bitmap.pixelsWide == 1024,
        bitmap.pixelsHigh == 1024
    else {
        try fail("Cannot inspect icon master safe area")
    }

    let inset = 82 // 8%: brighter structural detail must remain inside this boundary.
    for y in stride(from: 0, to: 1024, by: 4) {
        for x in stride(from: 0, to: 1024, by: 4)
        where x < inset || y < inset || x >= 1024 - inset || y >= 1024 - inset {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let brightest = max(color.redComponent, color.greenComponent, color.blueComponent)
            guard brightest < 0.28 else {
                try fail("Bright icon detail crosses the 8% platform-mask safe area at (\(x), \(y))")
            }
        }
    }
}

private func validateProjectSelection() throws {
    let project = try String(contentsOf: appleRoot.appendingPathComponent("project.yml"), encoding: .utf8)
    guard let targetSection = project.range(of: "\ntargets:\n") else {
        try fail("project.yml must define application targets")
    }
    let targets = String(project[targetSection.upperBound...])
    let selections = [
        "Pilot": "Cockpit", "Copilot": "Walkie", "Plotter": "Kneeboard", "Wingman Watch App": "AppIcon"
    ]
    for (target, icon) in selections {
        let escaped = NSRegularExpression.escapedPattern(for: target)
        let pattern = "(?ms)^  \(escaped):\\n(?:(?!^  \\S).)*"
        guard let range = targets.range(of: pattern, options: .regularExpression),
              targets[range].contains("ASSETCATALOG_COMPILER_APPICON_NAME: \(icon)\n") else {
            try fail("project.yml must select \(icon) for \(target)")
        }
    }
}

private func runIconPython(_ script: String, arguments: [String] = []) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", appleRoot.appendingPathComponent("bin/\(script)").path] + arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        try fail("\(script) failed with status \(process.terminationStatus)")
    }
}

private func validate() throws {
    _ = try loadMaster()
    try validateSafeArea()
    try validateCatalog(at: macCatalog)
    for catalog in iOSCatalogs { try validateCatalog(at: catalog) }
    try validateCatalog(at: watchCatalog)
    try validateProjectSelection()
    try runIconPython("composer-icons.py", arguments: ["validate"])
    print("Validated native layered icons, legacy catalog dimensions, opacity, RGB color, safe area, and target selection")
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "generate": try generate()
    case "validate": try validate()
    default: try fail("usage: app-icon-tool.swift generate|validate")
    }
} catch {
    fputs("app-icon-tool: \(error)\n", stderr)
    exit(1)
}
