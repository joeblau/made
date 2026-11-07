import AppKit
import GhosttyKit

// MARK: - Ghostty App Singleton

/// Manages the global Ghostty app instance. One per process.
final class GhosttyRuntime: @unchecked Sendable {
    static let shared = GhosttyRuntime()
    static let terminalBackgroundColor = NSColor(
        srgbRed: 0x1C / 255.0,
        green: 0x1C / 255.0,
        blue: 0x1C / 255.0,
        alpha: 1.0
    )
    static let terminalBackgroundHex = "#1c1c1c"
    static var terminalOverrideConfig: String {
        """
        background = \(terminalBackgroundHex)
        macos-option-as-alt = true
        mouse-scroll-multiplier = precision:1,discrete:1
        mouse-shift-capture = never
        """
    }
    private static let defaultTerminalFontSizePoints: CGFloat = 13.0
    private static let nativeDisplayModeFlag: UInt32 = 0x02000000

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var baseFontSizePoints: CGFloat = 13.0

    /// IDE-wide zoom factor (driven by ⌘+/⌘-/⌘0). Multiplied into
    /// `terminalFontSize` on top of the screen-density scale. Setting
    /// it broadcasts a notification so live `GhosttyMetalView`s
    /// re-apply their font size without restart.
    var userZoomFactor: Double = 1.0 {
        didSet {
            guard userZoomFactor != oldValue else { return }
            NotificationCenter.default.post(name: .ghosttyUserZoomDidChange, object: nil)
        }
    }

    private init() {
        // Initialize the Ghostty library
        ghostty_init(0, nil)

        // Create and finalize config
        guard let cfg = ghostty_config_new() else { return }
        ghostty_config_load_default_files(cfg)

        // Force a stable dark terminal background regardless of macOS appearance.
        let bgConfigPath = Self.writeBackgroundConfig()
        if let bgConfigPath {
            bgConfigPath.withCString { path in
                ghostty_config_load_file(cfg, path)
            }
        }

        ghostty_config_finalize(cfg)
        self.config = cfg
        self.baseFontSizePoints = Self.resolvedBaseFontSize(from: cfg)

        // Clean up temp file
        if let bgConfigPath {
            try? FileManager.default.removeItem(atPath: bgConfigPath)
        }

        // Create the runtime config with C callbacks
        var runtime_cfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { _ in
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.tick()
                }
            },
            action_cb: { app, target, action in
                return GhosttyRuntime.handleAction(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, loc, state in
                return GhosttyRuntime.readClipboard(userdata, location: loc, state: state)
            },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                GhosttyRuntime.confirmReadClipboard(
                    userdata,
                    string: str,
                    state: state,
                    request: request
                )
            },
            write_clipboard_cb: { _, loc, content, len, _ in
                guard let content, len > 0 else { return }
                guard let dataPtr = content.pointee.data else { return }
                let str = String(cString: dataPtr)
                let pb = GhosttyRuntime.pasteboard(for: loc)
                pb.clearContents()
                pb.setString(str, forType: .string)
            },
            close_surface_cb: { _, _ in }
        )

        guard let ghosttyApp = ghostty_app_new(&runtime_cfg, cfg) else { return }
        self.app = ghosttyApp

        // Track app focus for cursor blink, etc.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func terminalFontSize(for screen: NSScreen?) -> CGFloat {
        baseFontSizePoints * Self.displayModeFontScale(for: screen) * userZoomFactor
    }

    func updatedConfig(overridingFontSize fontSize: CGFloat) -> ghostty_config_t? {
        guard let config, let updatedConfig = ghostty_config_clone(config) else { return nil }

        let overridePath = Self.writeOverrideConfig(
            named: "ghostty-font-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            content: "font-size = \(String(format: "%.2f", fontSize))\n"
        )

        if let overridePath {
            overridePath.withCString { path in
                ghostty_config_load_file(updatedConfig, path)
            }
        }

        ghostty_config_finalize(updatedConfig)

        if let overridePath {
            try? FileManager.default.removeItem(atPath: overridePath)
        }

        return updatedConfig
    }

    private static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard {
        if location == GHOSTTY_CLIPBOARD_SELECTION {
            return NSPasteboard(name: NSPasteboard.Name("com.mitchellh.ghostty.selection"))
        }
        return .general
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let surface = surface(from: userdata) else { return false }
        let pb = pasteboard(for: location)

        let pasteString: String? = if Thread.isMainThread {
            pb.string(forType: .string)
        } else {
            DispatchQueue.main.sync {
                pb.string(forType: .string)
            }
        }

        guard let pasteString, !pasteString.isEmpty else { return false }
        completeClipboardRequest(surface: surface, string: pasteString, state: state)
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE else { return }
        guard let surface = surface(from: userdata) else { return }
        guard let string else { return }

        let pasteString = String(cString: string)
        completeClipboardRequest(surface: surface, string: pasteString, state: state, confirmed: true)
    }

    private static func completeClipboardRequest(
        surface: ghostty_surface_t,
        string: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        string.withCString { cString in
            ghostty_surface_complete_clipboard_request(surface, cString, state, confirmed)
        }
    }

    private static func surface(from userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let userdata else { return nil }
        let view = Unmanaged<GhosttyMetalView>.fromOpaque(userdata).takeUnretainedValue()
        return view.callbackSurface
    }

    private static func handleAction(_ app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            NotificationCenter.default.post(name: .ghosttyNeedsDisplay, object: nil, userInfo: ["surfaceID": UInt(bitPattern: target.target.surface)])
            return true
        case GHOSTTY_ACTION_PWD:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
            guard let pwd = action.action.pwd.pwd else { return true }
            let surfaceID = UInt(bitPattern: target.target.surface)
            NotificationCenter.default.post(
                name: .ghosttyWorkingDirectoryDidChange,
                object: nil,
                userInfo: [
                    "surfaceID": surfaceID,
                    "pwd": String(cString: pwd),
                ]
            )
            return true
        case GHOSTTY_ACTION_RING_BELL:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
            let surfaceID = UInt(bitPattern: target.target.surface)
            NotificationCenter.default.post(
                name: .ghosttyBellDidRing,
                object: nil,
                userInfo: ["surfaceID": surfaceID]
            )
            return true
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_VISIBILITY, GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_CONFIG_CHANGE:
            return true
        default:
            return false
        }
    }

    /// Writes a temporary Ghostty config file that forces a consistent dark
    /// terminal background to avoid light empty regions in terminal panes.
    private static func writeBackgroundConfig() -> String? {
        return writeOverrideConfig(
            named: "ghostty-bg-\(ProcessInfo.processInfo.processIdentifier)",
            content: terminalOverrideConfig
        )
    }

    private static func writeOverrideConfig(named name: String, content: String) -> String? {
        let path = NSTemporaryDirectory() + "\(name).conf"
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    private static func resolvedBaseFontSize(from config: ghostty_config_t) -> CGFloat {
        let key = "font-size"
        var value = Float(defaultTerminalFontSizePoints)
        guard ghostty_config_get(config, &value, key, UInt(key.count)), value > 0 else {
            return defaultTerminalFontSizePoints
        }
        return CGFloat(value)
    }

    private static func displayModeFontScale(for screen: NSScreen?) -> CGFloat {
        guard let screen, screen.backingScaleFactor > 1.0 else {
            return 1.0
        }
        guard let nativeLogicalSize = nativeLogicalDisplaySize(for: screen) else {
            return 1.0
        }
        guard nativeLogicalSize.width > 0, nativeLogicalSize.height > 0 else {
            return 1.0
        }

        let widthScale = screen.frame.width / nativeLogicalSize.width
        let heightScale = screen.frame.height / nativeLogicalSize.height
        return max(1.0, min(max(widthScale, heightScale), 1.35))
    }

    private static func nativeLogicalDisplaySize(for screen: NSScreen) -> CGSize? {
        guard let displayID = displayID(for: screen) else { return nil }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
              !modes.isEmpty else {
            return nil
        }

        let nativeModes = modes.filter { ($0.ioFlags & nativeDisplayModeFlag) != 0 }
        if let smallestNativeMode = nativeModes.min(by: { pointArea(of: $0) < pointArea(of: $1) }) {
            return pointSize(for: smallestNativeMode)
        }

        let backingScale = max(screen.backingScaleFactor, 1.0)
        let pixelWidth = CGFloat(CGDisplayPixelsWide(displayID))
        let pixelHeight = CGFloat(CGDisplayPixelsHigh(displayID))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGSize(width: pixelWidth / backingScale, height: pixelHeight / backingScale)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private static func pointSize(for mode: CGDisplayMode) -> CGSize {
        CGSize(width: CGFloat(mode.width), height: CGFloat(mode.height))
    }

    private static func pointArea(of mode: CGDisplayMode) -> CGFloat {
        CGFloat(mode.width) * CGFloat(mode.height)
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }
}
