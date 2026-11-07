import AppKit
import GhosttyKit

// MARK: - Metal Surface NSView

enum GhosttyScrollModifiers {
    /// `ghostty_input_scroll_mods_t` is a packed byte, not a keyboard-modifier
    /// bitset. Bit 0 marks pixel-precise input and bits 1...3 contain momentum.
    static func packedValue(precision: Bool, momentumPhase: NSEvent.Phase) -> Int32 {
        let momentum: Int32 = switch momentumPhase {
        case .began: Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary: Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed: Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended: Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled: Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin: Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default: Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }

        return (precision ? 1 : 0) | (momentum << 1)
    }
}

enum GhosttyCapturedMouseSelectionPolicy {
    static let dragThreshold: Double = 3.0

    static func shouldDeferPress(
        isMouseCaptured: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        isMouseCaptured && !modifierFlags.contains(.shift)
    }

    static func shouldBeginSelection(clickCount: Int, dragDistance: Double) -> Bool {
        clickCount > 1 || dragDistance >= dragThreshold
    }

    static func selectionModifiers(from modifiers: ghostty_input_mods_e) -> ghostty_input_mods_e {
        ghostty_input_mods_e(rawValue: modifiers.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
    }
}

/// An NSView that hosts a Ghostty terminal surface with Metal rendering.
/// The surface creates its own Metal renderer using the NSView's layer.
@MainActor
class GhosttyMetalView: NSView, CALayerDelegate {
    private static let resizeDebounceInterval: TimeInterval = 0.15
    private static let abruptShrinkRatio: CGFloat = 0.5
    private static let transientShrinkPixelWidth: CGFloat = 500
    private static let transientShrinkPixelHeight: CGFloat = 300
    private static let defaultContentScale: CGFloat = 2.0
    private struct DeferredLeftMouseDown {
        let x: Double
        let y: Double
        let modifiers: ghostty_input_mods_e
        let clickCount: Int
        var isSelecting = false
    }

    /// Registry of live terminal views keyed by Pane ID.
    /// Used to target the active terminal for remote input (voice paste, watch Enter).
    private final class WeakView {
        weak var value: GhosttyMetalView?
        init(_ value: GhosttyMetalView) { self.value = value }
    }

    private static var registry: [UUID: WeakView] = [:]

    static func view(for paneID: UUID) -> GhosttyMetalView? {
        registry[paneID]?.value
    }

    @discardableResult
    static func focus(paneID: UUID) -> Bool {
        guard let view = registry[paneID]?.value, let window = view.window else { return false }
        if window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
        return true
    }

    var surface: ghostty_surface_t?
    nonisolated(unsafe) private(set) var callbackSurface: ghostty_surface_t?
    private var renderObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    private var trackingArea: NSTrackingArea?
    private let pane: Pane
    private var lastAppliedFontSizePoints: CGFloat = 0
    private var lastAppliedSurfacePixelSize: CGSize = .zero
    private var pendingSurfaceResize: DispatchWorkItem?
    private var pendingGeometryRefresh = false
    private var isPresentationActive = true
    private var lastReportedSurfaceVisibility: Bool?
    private var deferredLeftMouseDown: DeferredLeftMouseDown?

    init(app: ghostty_app_t, pane: Pane) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.backgroundColor = GhosttyRuntime.terminalBackgroundColor.cgColor

        // Create the surface - Ghostty will set up Metal on the layer itself
        let rawDirectory = pane.currentDirectory
        // Fall back to the user's home so new panes never inherit Pilot's own
        // cwd (which could be whatever directory Pilot was launched from).
        let persistedDirectory = Self.validWorkingDirectory(from: rawDirectory) ?? NSHomeDirectory()

        // Install OSC 7 hook silently via ZDOTDIR override.
        // We create a temp .zshenv that installs the precmd hook, then restores
        // the real ZDOTDIR so the user's normal config loads.
        //
        // Pane process discovery does not belong in this spawn environment.
        // Persistent tmux sessions can outlive Pilot, which makes app-scoped
        // pid files stale after relaunch. Workspace asks tmux for each pane's
        // root shell pid instead.
        let zdotdir = Self.setupOSC7ZdotDir()
        let envVars: [(key: String, value: String)] = zdotdir != nil
            ? [
                ("ZDOTDIR", zdotdir!),
                ("__PILOT_REAL_ZDOTDIR", NSHomeDirectory()),
              ]
            : []
        let bootstrap = pane.terminalSession.bootstrap(workingDirectory: persistedDirectory)
        let persistentSessionInput: String?
        if case .local(let initialInput) = bootstrap { persistentSessionInput = initialInput } else { persistentSessionInput = nil }

        let surface = Self.makeSurface(
            app: app,
            view: self,
            workingDirectory: persistedDirectory,
            initialInput: persistentSessionInput,
            envVars: envVars
        )

        guard let surface else { return }
        self.surface = surface
        self.callbackSurface = surface
        Self.registry[pane.id] = WeakView(self)

        // Redraw only the surface Ghostty invalidated, not every open terminal.
        renderObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyNeedsDisplay,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let surfaceID = notification.userInfo?["surfaceID"] as? UInt else { return }
            MainActor.assumeIsolated {
                if let surface = self.surface, surfaceID == UInt(bitPattern: surface) { self.needsDisplay = true }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWorkingDirectoryDidChange(_:)),
            name: .ghosttyWorkingDirectoryDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBellDidRing(_:)),
            name: .ghosttyBellDidRing,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserZoomDidChange),
            name: .ghosttyUserZoomDidChange,
            object: nil
        )

        // OSC 7 precmd hook (installed via ZDOTDIR) handles per-surface cwd tracking.
        // No polling needed. Each shell reports its own directory via Ghostty's PWD action.
    }

    @objc private func handleUserZoomDidChange() {
        guard let surface else { return }
        applyFontSizeIfNeeded(surface: surface)
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        dispose()
    }

    /// A detached view still belongs to its pane controller. Workspace switches
    /// and cross-window moves must not free its renderer or spawn a new shell.
    override func removeFromSuperview() {
        setPresentationActive(false)
        super.removeFromSuperview()
    }

    /// Called only when the pane controller is evicted, never when it moves.
    func dispose() {
        if Self.registry[pane.id]?.value == nil || Self.registry[pane.id]?.value === self {
            Self.registry.removeValue(forKey: pane.id)
        }
        pendingSurfaceResize?.cancel()
        pendingSurfaceResize = nil
        tearDownWindowObservers()
        if let renderObserver {
            NotificationCenter.default.removeObserver(renderObserver)
            self.renderObserver = nil
        }
        NotificationCenter.default.removeObserver(self, name: .ghosttyWorkingDirectoryDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .ghosttyBellDidRing, object: nil)
        NotificationCenter.default.removeObserver(self, name: .ghosttyUserZoomDidChange, object: nil)
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
            self.callbackSurface = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func layout() {
        super.layout()
        requestSurfaceGeometryRefresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        requestSurfaceGeometryRefresh()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        requestSurfaceGeometryRefresh()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        Self.blurOtherTerminalSurfaces(in: window, excluding: self)
        setSurfaceFocus(true)
        pane.workspace?.setFrontmostTerminalPaneID(pane.id)
        return super.becomeFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowObservers()
        // Pane selection owns focus. Attaching a surface after a window move
        // must not steal focus from the selected pane or a toolbar field.
        //
        // Call `requestSurfaceGeometryRefresh` directly (no outer
        // `main.async`): the refresh itself already debounces onto the next
        // run-loop tick. Adding a second async hop just delayed the moment
        // Ghostty learned the view's actual screen, so the renderer could
        // fire one or more frames using the surfaceCfg-derived
        // (NSScreen.main) scale instead of the LG external's real scale.
        requestSurfaceGeometryRefresh()
    }

    /// Backing properties change when the view's window moves to a screen
    /// with a different `backingScaleFactor` (e.g. dragging a window from
    /// a Retina built-in panel onto a 1x external LG). Without this hook
    /// we'd only react via the `NSWindow.didChangeBackingProperties`
    /// notification, which can lag the view's own callback.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestSurfaceGeometryRefresh()
    }

    func setPresentationActive(_ isActive: Bool) {
        isPresentationActive = isActive
        syncSurfaceOcclusion()
        if isActive {
            if isHidden { isHidden = false }
            requestSurfaceGeometryRefresh()
        } else {
            // Let responder and pane selection updates finish before hiding a
            // focused view and rebuilding the window's key view loop.
            if window == nil { isHidden = true } else if !isHidden {
                DispatchQueue.main.async { [weak self] in if self?.isPresentationActive == false { self?.isHidden = true } }
            }
            pendingGeometryRefresh = false
            pendingSurfaceResize?.cancel()
            pendingSurfaceResize = nil
        }
    }

    private func requestSurfaceGeometryRefresh() {
        guard !pendingGeometryRefresh else { return }
        pendingGeometryRefresh = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingGeometryRefresh = false
            self.refreshSurfaceGeometry()
        }
    }

    private func refreshSurfaceGeometry() {
        guard let surface else { return }
        applyFontSizeIfNeeded(surface: surface)
        guard isPresentationActive, !isHidden, window != nil else { return }
        guard bounds.width >= 1, bounds.height >= 1 else { return }

        let geometry = currentSurfaceGeometry()
        applySurfaceGeometryIfNeeded(
            surface: surface,
            pixelSize: geometry.pixelSize,
            contentScaleX: geometry.contentScaleX,
            contentScaleY: geometry.contentScaleY
        )
    }

    private func applyFontSizeIfNeeded(surface: ghostty_surface_t) {
        let fontSize = GhosttyRuntime.shared.terminalFontSize(for: window?.screen ?? NSScreen.main)
        guard abs(fontSize - lastAppliedFontSizePoints) > 0.05 else { return }
        guard let updatedConfig = GhosttyRuntime.shared.updatedConfig(overridingFontSize: fontSize) else { return }

        ghostty_surface_update_config(surface, updatedConfig)
        ghostty_config_free(updatedConfig)
        lastAppliedFontSizePoints = fontSize
    }

    private func currentSurfaceGeometry() -> (
        pixelSize: CGSize,
        contentScaleX: CGFloat,
        contentScaleY: CGFloat
    ) {
        let fallbackScale = resolvedContentScaleFallback()
        let backingBounds = convertToBacking(bounds)

        let pixelWidth = max(1, backingBounds.width.rounded(.down))
        let pixelHeight = max(1, backingBounds.height.rounded(.down))

        let contentScaleX = window != nil && bounds.width > 0
            ? max(backingBounds.width / bounds.width, 0.0)
            : fallbackScale
        let contentScaleY = window != nil && bounds.height > 0
            ? max(backingBounds.height / bounds.height, 0.0)
            : fallbackScale

        return (
            pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
            contentScaleX: contentScaleX,
            contentScaleY: contentScaleY
        )
    }

    private func resolvedContentScaleFallback() -> CGFloat {
        window?.screen?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? Self.defaultContentScale
    }

    private func configureWindowObservers() {
        tearDownWindowObservers()

        guard let window else { return syncSurfaceOcclusion() }
        let center = NotificationCenter.default
        // Notifications are delivered on `.main` already; just call the
        // refresh directly via `MainActor.assumeIsolated` instead of a
        // `Task { @MainActor }` hop, which previously delayed every
        // screen-change response by an extra run-loop tick.
        let refresh: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.requestSurfaceGeometryRefresh()
            }
        }
        let windowNotifications: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeScreenNotification,
        ]
        windowObservers = windowNotifications.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { _ in refresh() }
        } + [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                refresh()
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncSurfaceOcclusion() }
            },
        ]
        syncSurfaceOcclusion()
    }

    /// Tells Ghostty whether this surface can be seen, so hidden workspaces and
    /// occluded windows stop rendering (true = visible, as Ghostty's own app passes).
    private func syncSurfaceOcclusion() {
        guard let surface else { return }
        let visible = isPresentationActive && window?.occlusionState.contains(.visible) == true
        guard visible != lastReportedSurfaceVisibility else { return }
        lastReportedSurfaceVisibility = visible
        ghostty_surface_set_occlusion(surface, visible)
    }

    private func tearDownWindowObservers() {
        guard !windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private func applySurfaceGeometryIfNeeded(
        surface: ghostty_surface_t,
        pixelSize: CGSize,
        contentScaleX: CGFloat,
        contentScaleY: CGFloat
    ) {
        let layerScale = max(contentScaleX, contentScaleY)
        if let layer, abs(layer.contentsScale - layerScale) > 0.001 {
            layer.contentsScale = layerScale
        }

        ghostty_surface_set_content_scale(
            surface,
            Double(contentScaleX),
            Double(contentScaleY)
        )

        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return }

        if shouldDebounceAbruptShrink(to: pixelSize) {
            scheduleSurfaceResize(
                surface: surface,
                pixelSize: pixelSize,
                contentScaleX: contentScaleX,
                contentScaleY: contentScaleY
            )
            return
        }

        pendingSurfaceResize?.cancel()
        pendingSurfaceResize = nil
        applySurfaceSize(
            surface: surface,
            pixelSize: pixelSize,
            contentScaleX: contentScaleX,
            contentScaleY: contentScaleY
        )
    }

    private func shouldDebounceAbruptShrink(to pixelSize: CGSize) -> Bool {
        guard let window, !window.inLiveResize else { return false }
        guard lastAppliedSurfacePixelSize.width >= 1, lastAppliedSurfacePixelSize.height >= 1 else { return false }

        let shrankAbruptly =
            pixelSize.width < lastAppliedSurfacePixelSize.width * Self.abruptShrinkRatio ||
            pixelSize.height < lastAppliedSurfacePixelSize.height * Self.abruptShrinkRatio
        let isTransientlyTiny =
            pixelSize.width < Self.transientShrinkPixelWidth ||
            pixelSize.height < Self.transientShrinkPixelHeight

        return shrankAbruptly && isTransientlyTiny
    }

    private func scheduleSurfaceResize(
        surface: ghostty_surface_t,
        pixelSize: CGSize,
        contentScaleX: CGFloat,
        contentScaleY: CGFloat
    ) {
        pendingSurfaceResize?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let liveSurface = self.surface, liveSurface == surface else { return }
            guard self.isPresentationActive, !self.isHidden else { return }
            self.pendingSurfaceResize = nil
            self.applySurfaceSize(
                surface: liveSurface,
                pixelSize: pixelSize,
                contentScaleX: contentScaleX,
                contentScaleY: contentScaleY
            )
        }

        pendingSurfaceResize = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.resizeDebounceInterval,
            execute: workItem
        )
    }

    private func applySurfaceSize(
        surface: ghostty_surface_t,
        pixelSize: CGSize,
        contentScaleX: CGFloat,
        contentScaleY: CGFloat
    ) {
        let width = max(1, UInt32(pixelSize.width.rounded(.down)))
        let height = max(1, UInt32(pixelSize.height.rounded(.down)))
        ghostty_surface_set_size(surface, width, height)
        ghostty_surface_set_content_scale(
            surface,
            Double(contentScaleX),
            Double(contentScaleY)
        )
        lastAppliedSurfacePixelSize = CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    // Text accumulated during keyDown via insertText
    private var keyTextAccumulator: [String]?

    // Records the timestamp of the last event to performKeyEquivalent.
    // Used to re-dispatch command-modded key events that AppKit intercepted
    // via doCommand before our keyDown could handle them.
    private var lastPerformKeyEvent: TimeInterval?

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Fast path for Ctrl-modified keys (Ctrl+C, Ctrl+D, etc.)
        // Bypass interpretKeyEvents entirely and send raw keycode to Ghostty.
        if event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.command) {
            let text = event.charactersIgnoringModifiers
            _ = keyAction(action, event: event, text: text)
            return
        }

        let translationModsGhostty = eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(surface, ghosttyMods(event.modifierFlags))
        )

        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Reset the re-dispatch timestamp since interpretKeyEvents may trigger doCommand.
        self.lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // Sync preedit state after interpretKeyEvents
        syncPreedit()

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard surface != nil else { return false }
        // Only handle key equivalents if we are the first responder.
        // AppKit walks the view hierarchy for performKeyEquivalent, so
        // terminals in inactive workspaces would otherwise intercept
        // Cmd+V, Cmd+C, etc. before the active terminal sees them.
        guard window?.firstResponder === self else { return false }

        // Give Pilot's main menu first crack at its global shortcuts (⌘T new
        // terminal, ⌘B new browser, ⌘0 notes, ⌥⌘E toggle Extendo, …) before
        // Ghostty's binding system swallows the Cmd combo. See
        // GhosttyMenuKeyEquivalentPolicy for which combos stay with the terminal.
        if GhosttyMenuKeyEquivalentPolicy.forwardsToMainMenu(
            hasCommand: event.modifierFlags.contains(.command),
            hasControl: event.modifierFlags.contains(.control),
            hasOption: event.modifierFlags.contains(.option),
            characters: event.charactersIgnoringModifiers?.lowercased() ?? ""
        ), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }

        // Let ⌘, fall through to the app menu so it opens Pilot's Settings
        // window, instead of being swallowed by Ghostty's binding system.
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers == "," {
            return false
        }

        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            pane.workspace?.focusPane(pane)
            return true
        }

        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass C-<return> through verbatim
            // (prevent the default context menu equivalent)
            if !event.modifierFlags.contains(.control) {
                return false
            }
            equivalent = "\r"

        case "/":
            // Treat C-/ as C-_. We do this because C-/ makes macOS beep.
            if !event.modifierFlags.contains(.control) ||
                !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                return false
            }
            equivalent = "_"

        default:
            // Ignore synthetic events with zero timestamp
            if event.timestamp == 0 {
                return false
            }

            // Ignore all non-command/control events
            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            // If we have a prior command binding and the timestamp matches,
            // re-dispatch through keyDown for encoding.
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            // Send all Cmd/Ctrl combos through keyDown so Ghostty's C-level
            // binding system can handle them (paste, copy, etc.).
            self.keyDown(with: event)
            return true
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        self.keyDown(with: finalEvent!)
        return true
    }

    @objc func paste(_ sender: Any?) {
        _ = performPasteFromClipboard() || pasteGeneralClipboardContents()
    }

    /// Paste text directly into the terminal surface (bypasses clipboard).
    /// Used for remote voice-to-text input.
    func pasteText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Send an Enter keypress to the terminal surface.
    /// Used for watch double-pinch → Enter.
    func sendEnter() {
        _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x24) // kVK_Return
    }
    func sendUpArrow() { _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x7E) } // kVK_UpArrow
    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39:
            mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C:
            mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E:
            mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D:
            mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36:
            mod = GHOSTTY_MODS_SUPER.rawValue
        default:
            return
        }

        // If we're in the middle of a preedit, don't do anything with mods.
        if hasMarkedText() { return }

        let mods = ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface else { return }
        let pt = mousePoint(event)
        let eventMods = mods(event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, eventMods)

        // Pilot keeps shells alive inside an invisible tmux session with mouse
        // reporting enabled for scrollback. If we forward the press immediately,
        // tmux also owns every drag and its default MouseDragEnd binding clears the
        // highlight on release. Defer an unmodified captured press until we know
        // whether it is a click (forward to tmux/TUI) or a drag (native Ghostty
        // selection). Explicit Shift keeps Ghostty's standard override behavior.
        if GhosttyCapturedMouseSelectionPolicy.shouldDeferPress(
            isMouseCaptured: ghostty_surface_mouse_captured(surface),
            modifierFlags: event.modifierFlags
        ) {
            deferredLeftMouseDown = DeferredLeftMouseDown(
                x: pt.x,
                y: pt.y,
                modifiers: eventMods,
                clickCount: min(max(event.clickCount, 1), 3)
            )

            // Double/triple clicks are selections even before a drag begins.
            if GhosttyCapturedMouseSelectionPolicy.shouldBeginSelection(
                clickCount: event.clickCount,
                dragDistance: 0
            ), var deferred = deferredLeftMouseDown {
                beginCapturedSelection(surface: surface, deferred: &deferred)
                deferredLeftMouseDown = deferred
            }
            return
        }

        deferredLeftMouseDown = nil
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, eventMods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else {
            deferredLeftMouseDown = nil
            return
        }

        let pt = mousePoint(event)
        if let deferred = deferredLeftMouseDown {
            deferredLeftMouseDown = nil

            if deferred.isSelecting {
                let selectionMods = GhosttyCapturedMouseSelectionPolicy.selectionModifiers(from: mods(event))
                ghostty_surface_mouse_pos(surface, pt.x, pt.y, selectionMods)
                _ = ghostty_surface_mouse_button(
                    surface,
                    GHOSTTY_MOUSE_RELEASE,
                    GHOSTTY_MOUSE_LEFT,
                    selectionMods
                )
            } else {
                // It was a click, not a selection drag. Replay the deferred
                // press/release so mouse-aware terminal applications still work.
                ghostty_surface_mouse_pos(surface, deferred.x, deferred.y, deferred.modifiers)
                _ = ghostty_surface_mouse_button(
                    surface,
                    GHOSTTY_MOUSE_PRESS,
                    GHOSTTY_MOUSE_LEFT,
                    deferred.modifiers
                )
                let eventMods = mods(event)
                ghostty_surface_mouse_pos(surface, pt.x, pt.y, eventMods)
                _ = ghostty_surface_mouse_button(
                    surface,
                    GHOSTTY_MOUSE_RELEASE,
                    GHOSTTY_MOUSE_LEFT,
                    eventMods
                )
            }
            return
        }

        let eventMods = mods(event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, eventMods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, eventMods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(event)

        if var deferred = deferredLeftMouseDown {
            if !deferred.isSelecting {
                let distance = hypot(pt.x - deferred.x, pt.y - deferred.y)
                guard GhosttyCapturedMouseSelectionPolicy.shouldBeginSelection(
                    clickCount: deferred.clickCount,
                    dragDistance: distance
                ) else { return }
                beginCapturedSelection(surface: surface, deferred: &deferred)
                deferredLeftMouseDown = deferred
            }

            ghostty_surface_mouse_pos(
                surface,
                pt.x,
                pt.y,
                GhosttyCapturedMouseSelectionPolicy.selectionModifiers(from: mods(event))
            )
            return
        }

        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { super.rightMouseDown(with: event); return }
        // If the terminal app has captured the mouse, send the event to Ghostty.
        // Otherwise, show the system context menu.
        if ghostty_surface_mouse_captured(surface) {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event))
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        if ghostty_surface_mouse_captured(surface) {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event))
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // AppKit keeps delivering drag events outside the view. Preserve the
        // real position so Ghostty can extend/autoscroll the active selection.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, mods(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            scrollMods(event)
        )
    }

    // MARK: - Helpers

    private func setSurfaceFocus(_ isFocused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, isFocused)
    }

    private static func blurOtherTerminalSurfaces(in window: NSWindow?, excluding focusedView: GhosttyMetalView) {
        for entry in registry.values {
            guard let view = entry.value, view !== focusedView, view.window === window else { continue }
            view.setSurfaceFocus(false)
        }
    }

    private func mousePoint(_ event: NSEvent) -> (x: Double, y: Double) {
        let pt = convert(event.locationInWindow, from: nil)
        return (Double(pt.x), Double(bounds.height - pt.y))
    }

    private func performPasteFromClipboard() -> Bool {
        guard let surface else { return false }
        let action = "paste_from_clipboard"
        return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    private func pasteGeneralClipboardContents() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return false }
        pasteText(text)
        return true
    }

    private func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        ghosttyMods(event.modifierFlags)
    }

    private func scrollMods(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        ghostty_input_scroll_mods_t(GhosttyScrollModifiers.packedValue(
            precision: event.hasPreciseScrollingDeltas,
            momentumPhase: event.momentumPhase
        ))
    }

    /// Starts a native Ghostty selection while a terminal application has mouse
    /// reporting enabled. The unknown-button pair clears any previous selection
    /// and resets Ghostty's click counter, but encodes no bytes for tmux/TUIs.
    private func beginCapturedSelection(
        surface: ghostty_surface_t,
        deferred: inout DeferredLeftMouseDown
    ) {
        ghostty_surface_mouse_pos(surface, deferred.x, deferred.y, deferred.modifiers)
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_UNKNOWN,
            deferred.modifiers
        )
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_UNKNOWN,
            deferred.modifiers
        )

        let selectionMods = GhosttyCapturedMouseSelectionPolicy.selectionModifiers(from: deferred.modifiers)
        for clickIndex in 0..<deferred.clickCount {
            ghostty_surface_mouse_pos(surface, deferred.x, deferred.y, selectionMods)
            _ = ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_PRESS,
                GHOSTTY_MOUSE_LEFT,
                selectionMods
            )
            if clickIndex < deferred.clickCount - 1 {
                _ = ghostty_surface_mouse_button(
                    surface,
                    GHOSTTY_MOUSE_RELEASE,
                    GHOSTTY_MOUSE_LEFT,
                    selectionMods
                )
            }
        }
        deferred.isSelecting = true
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        var key = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing

        if let text,
           text.count > 0,
           let codepoint = text.utf8.first,
           codepoint >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }

        return ghostty_surface_key(surface, key)
    }

    @objc
    private func handleWorkingDirectoryDidChange(_ notification: Notification) {
        guard let changedSurfaceID = notification.userInfo?["surfaceID"] as? UInt else { return }
        guard let surface else { return }
        guard changedSurfaceID == UInt(bitPattern: surface) else { return }
        guard let pwd = notification.userInfo?["pwd"] as? String else { return }
        pane.setCurrentDirectory(pwd)
    }

    @objc
    private func handleBellDidRing(_ notification: Notification) {
        guard let bellSurfaceID = notification.userInfo?["surfaceID"] as? UInt else { return }
        guard let surface else { return }
        guard bellSurfaceID == UInt(bitPattern: surface) else { return }
        pane.incrementBellCount()
    }

    private nonisolated static func validWorkingDirectory(from directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expandedDirectory = NSString(string: trimmed).expandingTildeInPath
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: expandedDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return expandedDirectory
    }

    /// Creates a temp directory with a .zshenv that installs an OSC 7 precmd
    /// hook, then restores the real ZDOTDIR so the user's normal config loads.
    /// This hook intentionally reports only the working directory. Runtime
    /// process identity comes from tmux and stays valid across an app restart.
    /// It never depends on an app-scoped pid file.
    private nonisolated static func setupOSC7ZdotDir() -> String? {
        let dir = NSTemporaryDirectory() + "pilot-zsh-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let zshenv = """
        # Pilot: install OSC 7 working directory reporting
        # Shell pid reporting deliberately stays out of this hook.
        # A persistent tmux session may predate this Pilot process;
        # app-scoped pid files would therefore be stale after relaunch.
        # The live tmux server remains the authority for pane ownership.
        __pilot_osc7_precmd() {
            printf '\\e]7;file://%s%s\\a' "$(hostname)" "$(pwd)"
        }
        precmd_functions+=(__pilot_osc7_precmd)
        # Restore real ZDOTDIR and source the user's .zshenv if it exists
        export ZDOTDIR="$__PILOT_REAL_ZDOTDIR"
        unset __PILOT_REAL_ZDOTDIR
        [[ -f "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
        """

        do {
            try zshenv.write(toFile: dir + "/.zshenv", atomically: true, encoding: .utf8)
            return dir
        } catch {
            return nil
        }
    }

    /// Best guess at which screen a brand-new terminal view will end up
    /// living on. The view isn't in a window yet at surface-creation time,
    /// so we walk the app's windows — a `keyWindow` or `mainWindow` is the
    /// most likely host. Falls back to the global `NSScreen.main` only if
    /// nothing else is available.
    @MainActor
    private static func likelyTargetScreen() -> NSScreen? {
        if let screen = NSApp.keyWindow?.screen { return screen }
        if let screen = NSApp.mainWindow?.screen { return screen }
        for window in NSApp.windows where window.isVisible {
            if let screen = window.screen { return screen }
        }
        return NSScreen.main
    }

    private nonisolated static func makeSurface(
        app: ghostty_app_t,
        view: GhosttyMetalView,
        workingDirectory: String?,
        initialInput: String?,
        envVars: [(key: String, value: String)] = []
    ) -> ghostty_surface_t? {
        func build(
            _ directory: UnsafePointer<CChar>?,
            _ input: UnsafePointer<CChar>?,
            _ envPtrs: UnsafeMutablePointer<ghostty_env_var_s>?,
            _ envCount: Int
        ) -> ghostty_surface_t? {
            var surfaceCfg = ghostty_surface_config_new()
            surfaceCfg.userdata = Unmanaged.passUnretained(view).toOpaque()
            surfaceCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
            surfaceCfg.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(view).toOpaque()
                )
            )
            // The view is not yet in a window when this runs (we're inside
            // GhosttyMetalView.init), so view.window is nil. NSScreen.main
            // is wrong on multi-monitor setups where the app's window lives
            // on a different screen (e.g. an external LG attached to a
            // Retina-internal Mac) — Ghostty would bootstrap its renderer
            // with the wrong scale_factor + font_size, allocate Metal
            // resources for the wrong DPI, and then have to fix everything
            // up after the post-window-attach refresh. Prefer the screen
            // hosting the current key window — that's overwhelmingly likely
            // to be where this new view ends up too.
            let (initialScale, initialFontSize): (Double, Float) = MainActor.assumeIsolated {
                let screen = Self.likelyTargetScreen()
                return (
                    Double(screen?.backingScaleFactor ?? 2.0),
                    Float(GhosttyRuntime.shared.terminalFontSize(for: screen))
                )
            }
            surfaceCfg.scale_factor = initialScale
            surfaceCfg.font_size = initialFontSize
            surfaceCfg.working_directory = directory
            surfaceCfg.initial_input = input
            surfaceCfg.env_vars = envPtrs
            surfaceCfg.env_var_count = envCount
            return ghostty_surface_new(app, &surfaceCfg)
        }

        // All string -> CString conversions must be nested so pointers stay valid
        func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
            if let string { return string.withCString { body($0) } }
            return body(nil)
        }

        if envVars.isEmpty {
            return withOptionalCString(workingDirectory) { dirPtr in
                withOptionalCString(initialInput) { inputPtr in
                    build(dirPtr, inputPtr, nil, 0)
                }
            }
        }

        // Keep NSStrings alive so utf8String pointers remain valid through build()
        let nsKeys = envVars.map { NSString(string: $0.key) }
        let nsValues = envVars.map { NSString(string: $0.value) }
        var envArray = (0..<envVars.count).map { i in
            ghostty_env_var_s(key: nsKeys[i].utf8String, value: nsValues[i].utf8String)
        }
        _ = nsKeys   // prevent premature deallocation
        _ = nsValues

        return withOptionalCString(workingDirectory) { dirPtr in
            withOptionalCString(initialInput) { inputPtr in
                envArray.withUnsafeMutableBufferPointer { buf in
                    build(dirPtr, inputPtr, buf.baseAddress, buf.count)
                }
            }
        }
    }
}

// MARK: - NSTextInputClient

extension GhosttyMetalView: @MainActor NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        if let s = string as? NSAttributedString {
            chars = s.string
        } else if let s = string as? String {
            chars = s
        } else {
            return
        }

        // If insertText is called, our preedit must be over.
        unmarkText()

        // If we have an accumulator we're in a keyDown event so we just
        // accumulate and return.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Fallback: text arriving outside keyDown (dictation, accessibility, etc.)
        sendTextToSurface(chars)
    }

    /// Send text directly to the surface, handling special characters.
    /// Used for text that arrives outside the normal keyDown path.
    private func sendTextToSurface(_ text: String) {
        guard surface != nil else { return }
        var buffer = ""
        var prevWasCR = false
        func flush() {
            guard !buffer.isEmpty else { return }
            buffer.withCString { ptr in
                guard let surface = self.surface else { return }
                var key = ghostty_input_key_s()
                key.action = GHOSTTY_ACTION_PRESS
                key.keycode = 0
                key.mods = GHOSTTY_MODS_NONE
                key.consumed_mods = GHOSTTY_MODS_NONE
                key.text = ptr
                key.composing = false
                key.unshifted_codepoint = 0
                _ = ghostty_surface_key(surface, key)
            }
            buffer = ""
        }

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D: // CR
                flush()
                _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x24) // kVK_Return
                prevWasCR = true
                continue
            case 0x0A: // LF
                if !prevWasCR {
                    flush()
                    _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x24)
                }
            case 0x09: // Tab
                flush()
                _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x30) // kVK_Tab
            case 0x1B: // Escape
                flush()
                _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x35) // kVK_Escape
            default:
                buffer.append(Character(scalar))
            }
            prevWasCR = false
        }
        flush()
    }

    /// Send a bare keycode press (no text) for special keys.
    private func keyAction(_ action: ghostty_input_action_e, keycode: UInt32) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = keycode
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.text = nil
        key.composing = false
        key.unshifted_codepoint = 0
        return ghostty_surface_key(surface, key)
    }

    override func doCommand(by selector: Selector) {
        // If we are being processed by performKeyEquivalent with a command binding,
        // we send it back through the event system so it can be encoded.
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
            return
        }

        // This function needs to exist to prevent audible NSBeep for
        // unimplemented actions. Commands like deleteBackward:, insertNewline:
        // etc. are handled by keyDown sending the key event to Ghostty directly.
    }

    // MARK: - IME / Marked Text

    private static var markedTextKey: UInt8 = 0

    private var markedText: NSMutableAttributedString {
        get {
            objc_getAssociatedObject(self, &Self.markedTextKey) as? NSMutableAttributedString
                ?? NSMutableAttributedString()
        }
        set {
            objc_setAssociatedObject(self, &Self.markedTextKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: s)
        } else if let s = string as? String {
            markedText = NSMutableAttributedString(string: s)
        }

        // If not inside keyDown, sync preedit immediately
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        syncPreedit()
    }

    func syncPreedit() {
        guard let surface else { return }
        let text = markedText.string
        if text.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
        } else {
            text.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
            }
        }
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        // Convert from Ghostty top-left to AppKit bottom-left
        let viewRect = NSRect(x: x, y: bounds.height - y - height, width: width, height: height)
        let windowRect = convert(viewRect, to: nil)
        let screenOrigin = window.convertPoint(toScreen: windowRect.origin)
        return NSRect(origin: screenOrigin, size: windowRect.size)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }
}

// MARK: - Notification

extension Notification.Name {
    static let ghosttyNeedsDisplay = Notification.Name("ghosttyNeedsDisplay")
    static let ghosttyWorkingDirectoryDidChange = Notification.Name("ghosttyWorkingDirectoryDidChange")
    static let ghosttyBellDidRing = Notification.Name("ghosttyBellDidRing")
    static let ghosttyUserZoomDidChange = Notification.Name("ghosttyUserZoomDidChange")
}

private func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags()
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
}

private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    let rawFlags = flags.rawValue

    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    if flags.contains(.shift), rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 {
        mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue
    }
    if flags.contains(.control), rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 {
        mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue
    }
    if flags.contains(.option), rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 {
        mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue
    }
    if flags.contains(.command), rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 {
        mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue
    }

    return ghostty_input_mods_e(rawValue: mods)
}

private extension NSEvent {
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(keyCode)
        key.text = nil
        key.composing = false

        key.mods = ghosttyMods(modifierFlags)
        key.consumed_mods = ghosttyMods((translationMods ?? modifierFlags).subtracting([.control, .command]))

        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            key.unshifted_codepoint = codepoint.value
        } else {
            key.unshifted_codepoint = 0
        }

        return key
    }

    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
