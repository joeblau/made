// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GhosttyKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            url: "https://github.com/joeblau/made/releases/download/ghosttykit-1.3.1-blau.2/GhosttyKit.xcframework.zip",
            checksum: "1a5aabddde32a057d70f91e7616322bef6a77ebac30893b25f26c9075b7fd8fe"
        ),
    ]
)
