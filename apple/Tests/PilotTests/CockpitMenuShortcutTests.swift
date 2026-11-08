import AppKit
@testable import Pilot
import Testing

/// Pins Cockpit's complete keyboard-shortcut map. Moving or rewriting menu
/// commands must not silently drop, rebind, or collide a shortcut; a deliberate
/// change updates this inventory in the same review.
@MainActor
@Suite("Cockpit menu shortcuts", .serialized)
struct CockpitMenuShortcutTests {
    private static let expected: [String: String] = {
        var map: [String: String] = [
            "Cockpit › Settings…": "⌘,",
            "Cockpit › Hide Cockpit": "⌘H",
            "Cockpit › Hide Others": "⌥⌘H",
            "Cockpit › Quit Cockpit": "⌘Q",
            "File › Show Main Window": "⌘N",
            "File › New Workspace…": "⇧⌘N",
            "File › New Tab": "⌘T",
            "File › Open…": "⌘O",
            "File › Save": "⌘S",
            "File › Close Tab": "⌘W",
            "File › Close Window": "⇧⌘W",
            "File › Close All Windows": "⌥⇧⌘W",
            "Edit › Undo": "⌘Z",
            "Edit › Redo": "⇧⌘Z",
            "Edit › Cut": "⌘X",
            "Edit › Copy": "⌘C",
            "Edit › Paste": "⌘V",
            "Edit › Select All": "⌘A",
            "Edit › Find… / Focus Selected Pane": "⌘F",
            "Edit › Find Next": "⌘G",
            "Edit › Find Previous": "⇧⌘G",
            "Edit › Use Selection for Find": "⌘E",
            "View › Toggle Sidebar": "⌃⌘S",
            "View › Toggle Inspector": "⌘I",
            "View › Toggle Notes": "⌘0",
            "View › Toggle Remote Desktop": "⇧⌘0",
            "View › Toggle Docker": "⌃⌘0",
            "View › Toggle Drawing": "⇧⌘D",
            "View › Increase Text Size": "⌘=",
            "View › Decrease Text Size": "⌘-",
            "View › Actual Size": "⌥⌘0",
            "View › Enter Full Screen": "⌃⌘F",
            "Browser › Reload / Run Fast Command": "⌘R",
            "Browser › Focus Address Bar": "⌘L",
            "Browser › Toggle Lasso": "⇧⌘A",
            "Browser › Debug Mobile App in Browser": "⌥⌘D",
            "Window › Toggle Extendo": "⌥⌘E",
            "Window › Minimize": "⌘M",
            "Window › Previous Panel": "⇧⌘[",
            "Window › Next Panel": "⇧⌘]",
        ]
        for index in 1...9 { map["Window › Workspace \(index)"] = "⌘\(index)" }
        return map
    }()

    @Test("Every shortcut keeps its binding and none collide")
    func shortcutInventory() throws {
        let original = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.servicesMenu)
        defer { NSApp.mainMenu = original.0; NSApp.windowsMenu = original.1; NSApp.servicesMenu = original.2 }
        let menus = CockpitMenuController(windowProvider: { nil }, showMain: {}, toggleExtendo: {},
                                          showSettings: {}, showSetup: {}, checkForUpdates: {})
        menus.install()
        let main = try #require(NSApp.mainMenu)

        var actual: [String: String] = [:]
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            for item in Self.leaves(of: submenu) where !item.keyEquivalent.isEmpty && !Self.isSystemInjected(item) {
                let path = "\(top.title) › \(item.title)"
                #expect(actual[path] == nil, "Duplicate menu item \(path)")
                actual[path] = Self.render(item)
            }
        }

        #expect(actual == Self.expected)
        for path in Set(actual.keys).union(Self.expected.keys).sorted() where actual[path] != Self.expected[path] {
            Issue.record("\(path): expected \(Self.expected[path] ?? "none"), got \(actual[path] ?? "none")")
        }

        var owners: [String: [String]] = [:]
        for (path, shortcut) in actual { owners[shortcut, default: []].append(path) }
        for (shortcut, paths) in owners where paths.count > 1 {
            Issue.record("\(shortcut) is bound to \(paths.sorted().joined(separator: ", "))")
        }
    }

    /// AppKit adds Emoji & Symbols, Start Dictation, and globe-key (fn)
    /// variants to the Edit and View menus on its own; Cockpit does not own them.
    private static func isSystemInjected(_ item: NSMenuItem) -> Bool {
        let injected: Set<String> = ["orderFrontCharacterPalette:", "startDictation:"]
        return item.keyEquivalentModifierMask.contains(.function)
            || item.action.map { injected.contains(NSStringFromSelector($0)) } == true
    }

    private static func leaves(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in item.submenu.map(leaves(of:)) ?? [item] }
    }

    /// Standard menu glyph order (⌃⌥⇧⌘), with an uppercase key equivalent
    /// counting as Shift the way AppKit matches it.
    private static func render(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        var modifiers = item.keyEquivalentModifierMask
        if key != key.lowercased() { modifiers.insert(.shift) }
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + key.uppercased()
    }
}
