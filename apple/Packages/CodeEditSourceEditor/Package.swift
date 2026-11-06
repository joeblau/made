// swift-tools-version: 5.9
import PackageDescription

// Native presentation adaptation of CodeEditSourceEditor 0.15.2.
// See UPSTREAM.md for the immutable source revision and local patch boundary.
let package = Package(
    name: "CodeEditSourceEditor",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CodeEditSourceEditor", targets: ["CodeEditSourceEditor"])],
    dependencies: [
        .package(url: "https://github.com/CodeEditApp/CodeEditTextView.git", exact: "0.12.1"),
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", exact: "0.1.20"),
        .package(url: "https://github.com/CodeEditApp/CodeEditSymbols.git", exact: "0.2.3"),
        .package(url: "https://github.com/ChimeHQ/TextFormation", exact: "0.9.0")
    ],
    targets: [
        .target(
            name: "CodeEditSourceEditor",
            dependencies: ["CodeEditTextView", "CodeEditLanguages", "TextFormation", "CodeEditSymbols"]
        )
    ]
)
