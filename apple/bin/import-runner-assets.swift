#!/usr/bin/env swift
import AppKit

// Reproduce the runner hardware silhouettes from the locally installed Sensei
// asset catalog: swift apple/bin/import-runner-assets.swift [Sensei.app path]
// The remaining hardware types use SF Symbols because Sensei has no matching
// dashboard asset. No dependency on Sensei is needed at app runtime.
let sourcePath = CommandLine.arguments.dropFirst().first ?? "/Applications/Sensei.app"
guard let bundle = Bundle(path: sourcePath) else { fatalError("Missing bundle at \(sourcePath)") }
let appleRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = appleRoot.appendingPathComponent("Sources/Pilot/Assets.xcassets")
let assets = [
    "dashboard-imac": "RunnerIMac",
    "dashboard-mac-mini": "RunnerMacMini",
    "dashboard-mac-pro-cylinder": "RunnerMacProCylinder",
    "dashboard-mac-pro-tower": "RunnerMacProTower",
    "dashboard-macbook": "RunnerMacBook",
]
for (source, destination) in assets.sorted(by: { $0.key < $1.key }) {
    guard let image = bundle.image(forResource: NSImage.Name(source)),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Missing image: \(source)")
    }
    let directory = catalog.appendingPathComponent("\(destination).imageset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try png.write(to: directory.appendingPathComponent("\(destination).png"))
    let metadata: [String: Any] = [
        "images": [["filename": "\(destination).png", "idiom": "universal", "scale": "2x"]],
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"],
    ]
    var json = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    json.append(0x0A)
    try json.write(to: directory.appendingPathComponent("Contents.json"))
    print("Imported \(source) → \(destination) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
}
