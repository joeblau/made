import Foundation
import Testing
@testable import Pilot

/// Chrome derives an unpacked extension's identifier from its absolute load
/// path. Pilot must compute the same value CEF will, because that identifier is
/// the `chrome-extension://` origin the wallet UI is served from — get it wrong
/// and the popup silently addresses an extension that does not exist.
@Suite("Wallet extension discovery")
struct WalletExtensionTests {
    /// The two identifiers the earlier spike hardcoded, now reproduced from the
    /// paths alone. These are real values Chrome assigned to those directories,
    /// so they pin the algorithm to observed behavior rather than to my reading
    /// of it.
    @Test("Identifiers match the ones Chrome assigns")
    func derivesKnownIdentifiers() {
        let root = "/Users/joeblau/Developer/joeblau/src/blau/apple/build/spike"
        #expect(
            WalletExtensionRegistry.identifier(
                forDirectory: URL(fileURLWithPath: "\(root)/rabby-unpacked")
            ) == "adbojkblhgobhcdckcplhgemldmjldel"
        )
        #expect(
            WalletExtensionRegistry.identifier(
                forDirectory: URL(fileURLWithPath: "\(root)/backpack-unpacked")
            ) == "mihjmhdibgkjmjdfmkdihbeachlaooho"
        )
    }

    @Test("Identifiers are 32 characters in Chrome's a–p alphabet")
    func identifierShape() {
        let id = WalletExtensionRegistry.identifier(
            forDirectory: URL(fileURLWithPath: "/tmp/some-wallet")
        )
        #expect(id.count == 32)
        #expect(id.allSatisfy { $0 >= "a" && $0 <= "p" })
    }

    @Test("A moved extension gets a different identifier")
    func identifierFollowsThePath() {
        let first = WalletExtensionRegistry.identifier(forDirectory: URL(fileURLWithPath: "/tmp/wallet-a"))
        let second = WalletExtensionRegistry.identifier(forDirectory: URL(fileURLWithPath: "/tmp/wallet-b"))
        #expect(first != second)
    }

    @Test("A trailing slash addresses the same extension")
    func trailingSlashIsIrrelevant() {
        let bare = WalletExtensionRegistry.identifier(forDirectory: URL(fileURLWithPath: "/tmp/wallet"))
        let slashed = WalletExtensionRegistry.identifier(
            forDirectory: URL(fileURLWithPath: "/tmp/wallet", isDirectory: true)
        )
        #expect(bare == slashed)
    }

    // MARK: - Manifest handling

    @Test("A manifest's popup path is read from action or browser_action")
    func readsPopupFromEitherManifestVersion() throws {
        let mv3 = try makeExtension(manifest: #"{"name":"MV3 Wallet","action":{"default_popup":"popup.html"}}"#)
        #expect(mv3.walletExtension?.popupPath == "popup.html")
        #expect(mv3.walletExtension?.name == "MV3 Wallet")

        let mv2 = try makeExtension(
            manifest: #"{"name":"MV2 Wallet","browser_action":{"default_popup":"ui/popup.html"}}"#
        )
        #expect(mv2.walletExtension?.popupPath == "ui/popup.html")
    }

    @Test("An extension with no action popup is skipped")
    func skipsExtensionsWithoutAPopup() throws {
        let fixture = try makeExtension(manifest: #"{"name":"No Popup"}"#)
        #expect(fixture.walletExtension == nil)
    }

    @Test("A directory without a readable manifest is skipped")
    func skipsUnreadableDirectories() throws {
        let fixture = try makeExtension(manifest: "not json at all")
        #expect(fixture.walletExtension == nil)
    }

    @Test("The popup URL is the extension origin plus the manifest path")
    func buildsPopupURL() throws {
        let fixture = try makeExtension(manifest: #"{"name":"W","action":{"default_popup":"popup.html"}}"#)
        let walletExtension = try #require(fixture.walletExtension)
        #expect(walletExtension.popupURL?.absoluteString
            == "chrome-extension://\(walletExtension.id)/popup.html")
    }

    /// The manifest is third-party text that becomes a URL path, so an escape
    /// out of the extension root has to be rejected rather than normalized.
    @Test("Popup paths cannot escape the extension root")
    func rejectsEscapingPopupPaths() {
        #expect(WalletExtensionRegistry.sanitizedRelativePath("popup.html") == "popup.html")
        #expect(WalletExtensionRegistry.sanitizedRelativePath("ui/popup.html") == "ui/popup.html")
        #expect(WalletExtensionRegistry.sanitizedRelativePath("../../etc/passwd") == nil)
        #expect(WalletExtensionRegistry.sanitizedRelativePath("a/../../b") == nil)
        #expect(WalletExtensionRegistry.sanitizedRelativePath("/etc/passwd") == nil)
        #expect(WalletExtensionRegistry.sanitizedRelativePath("https://evil.example/x") == nil)
        #expect(WalletExtensionRegistry.sanitizedRelativePath("") == nil)
        #expect(WalletExtensionRegistry.sanitizedRelativePath("popup\u{0000}.html") == nil)
        #expect(WalletExtensionRegistry.sanitizedRelativePath(String(repeating: "a", count: 300)) == nil)
    }

    // MARK: - Localized names

    private let localizedManifest =
        #"{"name":"__MSG_appName__","default_locale":"en","action":{"default_popup":"popup.html"}}"#

    @Test("A __MSG_ name resolves from the default locale's messages")
    func resolvesLocalizedName() throws {
        let fixture = try makeExtension(
            manifest: localizedManifest,
            messages: ["en": #"{"appName":{"message":"Rabby Wallet","description":"x"}}"#]
        )
        #expect(fixture.walletExtension?.name == "Rabby Wallet")
        #expect(fixture.walletExtension?.systemImageName == "hare")
    }

    @Test("Message names match case-insensitively, as in Chrome")
    func messageNamesIgnoreCase() throws {
        let fixture = try makeExtension(
            manifest: localizedManifest,
            messages: ["en": #"{"APPNAME":{"message":"Backpack"}}"#]
        )
        #expect(fixture.walletExtension?.name == "Backpack")
    }

    @Test("An unresolvable __MSG_ name falls back to the folder name")
    func unresolvedNameFallsBackToFolder() throws {
        let missingCatalog = try makeExtension(manifest: localizedManifest)
        #expect(missingCatalog.walletExtension?.name == "wallet")

        let missingKey = try makeExtension(
            manifest: localizedManifest,
            messages: ["en": #"{"other":{"message":"Nope"}}"#]
        )
        #expect(missingKey.walletExtension?.name == "wallet")

        let traversal = try makeExtension(
            manifest: #"{"name":"__MSG_appName__","default_locale":"../en","action":{"default_popup":"p.html"}}"#,
            messages: ["en": #"{"appName":{"message":"Escaped"}}"#]
        )
        #expect(traversal.walletExtension?.name == "wallet")

        let selfReference = try makeExtension(
            manifest: localizedManifest,
            messages: ["en": #"{"appName":{"message":"__MSG_appName__"}}"#]
        )
        #expect(selfReference.walletExtension?.name == "wallet")
    }

    @Test("A resolved name is untrusted text: control characters stripped, length capped")
    func resolvedNameIsSanitized() throws {
        let long = String(repeating: "W", count: 500)
        let fixture = try makeExtension(
            manifest: localizedManifest,
            messages: ["en": #"{"appName":{"message":"Ra\u0007bby\u202E \#(long)"}}"#]
        )
        let name = try #require(fixture.walletExtension?.name)
        #expect(name.hasPrefix("Rabby W"))
        #expect(name.count <= 61)
        #expect(!name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }

    @Test("An oversized or out-of-root messages file is not read")
    func boundsTheMessagesFile() throws {
        let oversized = try makeExtension(
            manifest: localizedManifest,
            messages: ["en": #"{"appName":{"message":"Big"},"pad":""# + String(repeating: "x", count: 4 * 1024 * 1024) + #""}"#]
        )
        #expect(oversized.walletExtension?.name == "wallet")

        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appending(path: "messages.json")
        try Data(#"{"appName":{"message":"Outside"}}"#.utf8).write(to: target)
        let linked = try makeExtension(manifest: localizedManifest)
        let localeDirectory = linked.directory.appending(path: "_locales/en")
        try FileManager.default.createDirectory(at: localeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: localeDirectory.appending(path: "messages.json"), withDestinationURL: target
        )
        #expect(WalletExtensionRegistry.load(directory: linked.directory)?.name == "wallet")
    }

    @Test("Only a whole-string __MSG_key__ is a message reference")
    func recognizesMessageReferences() {
        #expect(WalletExtensionRegistry.messageKey(in: "__MSG_appName__") == "appName")
        #expect(WalletExtensionRegistry.messageKey(in: "__MSG_app@name_2__") == "app@name_2")
        #expect(WalletExtensionRegistry.messageKey(in: "Rabby") == nil)
        #expect(WalletExtensionRegistry.messageKey(in: "__MSG___") == nil)
        #expect(WalletExtensionRegistry.messageKey(in: "x __MSG_appName__") == nil)
        #expect(WalletExtensionRegistry.messageKey(in: "__MSG_app/../name__") == nil)
    }

    // MARK: - Discovery

    @Test("Discovery returns readable extensions sorted by name")
    func discoversSortedExtensions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(
            manifest: #"{"name":"Zebra","action":{"default_popup":"popup.html"}}"#,
            into: root.appending(path: "zebra")
        )
        try write(
            manifest: #"{"name":"Alpha","action":{"default_popup":"popup.html"}}"#,
            into: root.appending(path: "alpha")
        )
        // Not an extension — must not appear.
        try FileManager.default.createDirectory(
            at: root.appending(path: "empty"), withIntermediateDirectories: true
        )

        let discovered = WalletExtensionRegistry.discover(roots: [root])
        #expect(discovered.map(\.name) == ["Alpha", "Zebra"])
    }

    @Test("A missing search root is not an error")
    func toleratesMissingRoots() {
        let missing = URL(fileURLWithPath: "/tmp/pilot-wallets-absent-\(UUID().uuidString)")
        #expect(WalletExtensionRegistry.discover(roots: [missing]).isEmpty)
    }

    @Test("The environment override takes priority over Application Support")
    func environmentOverrideLeadsTheSearch() {
        let roots = WalletExtensionRegistry.searchRoots(
            environment: ["PILOT_WALLET_EXTENSIONS_DIR": "/tmp/dev-wallets"],
            applicationSupport: URL(fileURLWithPath: "/Users/me/Library/Application Support")
        )
        #expect(roots.first?.path == "/tmp/dev-wallets")
        #expect(roots.contains { $0.path.hasSuffix("Pilot/Extensions") })
    }

    // MARK: - Fixtures

    private struct Fixture {
        let directory: URL
        let walletExtension: WalletExtension?
    }

    private func makeExtension(manifest: String, messages: [String: String] = [:]) throws -> Fixture {
        let root = try temporaryDirectory()
        let directory = root.appending(path: "wallet")
        try write(manifest: manifest, into: directory)
        for (locale, catalog) in messages {
            let localeDirectory = directory.appending(path: "_locales").appending(path: locale)
            try FileManager.default.createDirectory(at: localeDirectory, withIntermediateDirectories: true)
            try Data(catalog.utf8).write(to: localeDirectory.appending(path: "messages.json"))
        }
        return Fixture(
            directory: directory,
            walletExtension: WalletExtensionRegistry.load(directory: directory)
        )
    }

    private func write(manifest: String, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: directory.appending(path: "manifest.json"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pilot-wallet-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

@Suite("Wallet popup placement")
struct WalletPopupPlacementTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 400, height: 600)

    @Test("The popup hangs below its button")
    func sitsBelowTheAnchor() {
        let anchor = NSRect(x: 200, y: 800, width: 32, height: 24)
        let origin = WalletPopupPlacement.originBelow(anchor: anchor, size: size, screenFrame: screen)
        #expect(origin.x == 200)
        #expect(origin.y < anchor.minY)
    }

    @Test("A popup near the right edge stays on screen")
    func clampsToTheRightEdge() {
        let anchor = NSRect(x: 1400, y: 800, width: 32, height: 24)
        let origin = WalletPopupPlacement.originBelow(anchor: anchor, size: size, screenFrame: screen)
        #expect(origin.x <= screen.maxX - size.width)
    }

    @Test("A popup with no room beneath flips above the button")
    func flipsWhenThereIsNoRoomBelow() {
        let anchor = NSRect(x: 200, y: 120, width: 32, height: 24)
        let origin = WalletPopupPlacement.originBelow(anchor: anchor, size: size, screenFrame: screen)
        // Top-left origin sits above the button, so the panel body lands on screen.
        #expect(origin.y > anchor.maxY)
    }
}
