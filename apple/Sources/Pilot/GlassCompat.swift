import AppKit
import QuartzCore

struct PilotSegmentedMenuItem {
    let title: String
    let isEnabled: Bool
    let isDestructive: Bool
    let action: () -> Void

    init(
        _ title: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.action = action
    }
}

@MainActor
final class PilotNativeSegmentedControl: NSSegmentedControl {
    var onDrop: ((NSPasteboard, Int) -> Bool)?
    /// When false, a click selects its segment on mouse-down instead of
    /// running AppKit's press tracking. That tracking lifts the pressed glass
    /// pill from 16pt to 26pt, past a small control's 20pt bounds, so the
    /// control appears to change height on every click. The pill still
    /// slides to its new segment. Opt-out only: it bypasses press-and-hold
    /// segment menus and drags that start on the control.
    var liftsOnPress = true
    var showsCloseButton = false
    var isCloseHovering = false
    var isCloseEnabled = true
    private var closeTrackingArea: NSTrackingArea?
    /// Alpha the close button is resting at or fading toward.
    private var closeButtonTargetAlpha: CGFloat = 0

    /// Side of the close button and of the transparent image slot reserved
    /// for it at the start of every segment.
    static let closeSlotSize: CGFloat = 16

    /// Where AppKit draws a left-aligned segment image, measured from the
    /// segment's leading edge (macOS 26+ capsule style, `.fillEqually`).
    private var imageLeadingInset: CGFloat {
        controlSize == .regular || controlSize == .large || controlSize == .extraLarge ? 14 : 12
    }

    /// Matches the workspace pane tabs: a small bold glyph on a circular
    /// tertiary fill, sized to the slot instead of scaled up to fill it.
    lazy var closeButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        button.image?.isTemplate = true
        button.imageScaling = .scaleNone
        button.contentTintColor = NSColor.secondaryLabelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.closeSlotSize / 2
        button.alphaValue = 0
        return button
    }()

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCloseButtonFill()
    }

    private func updateCloseButtonFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            closeButton.layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
        }
    }

    override func layout() {
        super.layout()
        updateCloseButton()
    }

    override func mouseDown(with event: NSEvent) {
        guard !liftsOnPress else { return super.mouseDown(with: event) }
        guard isEnabled, segmentCount > 0, bounds.width > 0 else { return }
        let location = convert(event.locationInWindow, from: nil)
        let segment = min(max(0, Int(location.x * CGFloat(segmentCount) / bounds.width)), segmentCount - 1)
        guard isEnabled(forSegment: segment), segment != selectedSegment else { return }
        // Implicit animation keeps the glass pill's slide between segments.
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            selectedSegment = segment
        }
        sendAction(action, to: target)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateCloseButton()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let closeTrackingArea { removeTrackingArea(closeTrackingArea) }
        closeTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let closeTrackingArea { addTrackingArea(closeTrackingArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        isCloseHovering = true
        updateCloseButton()
    }

    override func mouseExited(with event: NSEvent) {
        isCloseHovering = false
        updateCloseButton()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard segmentCount > 0, bounds.width > 0 else { return false }
        let location = convert(sender.draggingLocation, from: nil)
        let segment = min(max(0, Int(location.x * CGFloat(segmentCount) / bounds.width)), segmentCount - 1)
        return onDrop?(sender.draggingPasteboard, segment) ?? false
    }

    func updateCloseButton() {
        let isVisible = showsCloseButton && isCloseHovering && selectedSegment >= 0 && segmentCount > 0
        closeButton.isHidden = !showsCloseButton || selectedSegment < 0
        closeButton.isEnabled = isVisible && isCloseEnabled
        if isVisible {
            // Sits on the selected segment's reserved image slot, inside the
            // segment and to the left of its title.
            let segmentWidth = bounds.width / CGFloat(segmentCount)
            let side = Self.closeSlotSize
            closeButton.frame = NSRect(
                x: segmentWidth * CGFloat(selectedSegment) + imageLeadingInset,
                y: (bounds.height - side) / 2,
                width: side,
                height: side
            )
            updateCloseButtonFill()
        }
        // `layout()` and every content update call this; start a fade only
        // when visibility actually flips.
        let targetAlpha: CGFloat = isVisible ? 1 : 0
        guard closeButtonTargetAlpha != targetAlpha else { return }
        closeButtonTargetAlpha = targetAlpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            closeButton.animator().alphaValue = targetAlpha
        }
    }
}

/// A native typed segmented control. Updating a selection preserves the same
/// AppKit control, first responder, and native accessibility elements.
@MainActor
final class PilotSegmentedControl<Value: Hashable>: NSView {
    let control = PilotNativeSegmentedControl()
    var selection: Value { didSet { updateSelection() } }
    var onSelectionChanged: (Value) -> Void
    var onClose: ((Value) -> Void)? { didSet { configure() } }
    var canClose: ((Value) -> Bool)? { didSet { updateSelection() } }
    var onDrop: ((NSPasteboard, Int) -> Bool)? {
        didSet {
            control.onDrop = onDrop
            if onDrop != nil { control.registerForDraggedTypes(dropTypes) }
        }
    }
    var menuItems: ((Value) -> [PilotSegmentedMenuItem])? { didSet { configure() } }
    var options: [Value] { didSet { configure() } }
    var showsTitles: Bool { didSet { configure() } }
    private let optionTitle: (Value) -> String
    private let optionImage: (Value) -> String?
    private let dropTypes: [NSPasteboard.PasteboardType]
    private let actionTarget = PilotSegmentedActionTarget()
    private var menuTargets: [PilotSegmentedActionTarget] = []
    private var zoomObserver: NSObjectProtocol?

    init(
        _ accessibilityLabel: String,
        selection: Value,
        options: [Value],
        title: @escaping (Value) -> String,
        systemImage: @escaping (Value) -> String? = { _ in nil },
        showsTitles: Bool = true,
        controlSize: NSControl.ControlSize = .regular,
        liftsOnPress: Bool = true,
        dropTypes: [NSPasteboard.PasteboardType] = [.string],
        onSelectionChanged: @escaping (Value) -> Void
    ) {
        self.selection = selection
        self.options = options
        optionTitle = title
        optionImage = systemImage
        self.showsTitles = showsTitles
        self.dropTypes = dropTypes
        self.onSelectionChanged = onSelectionChanged
        super.init(frame: .zero)
        control.controlSize = controlSize
        control.liftsOnPress = liftsOnPress
        control.segmentStyle = .capsule
        control.segmentDistribution = .fillEqually
        control.trackingMode = .selectOne
        control.setAccessibilityLabel(accessibilityLabel)
        control.selectedSegmentBezelColor = LegibleAccent.nsColor
        if #available(macOS 26.0, *) { control.borderShape = .capsule }
        if #available(macOS 27.0, *) { control.role = .tabs }
        actionTarget.action = { [weak self] sender in
            guard let self, let segmented = sender as? NSSegmentedControl,
                  self.options.indices.contains(segmented.selectedSegment) else { return }
            let next = self.options[segmented.selectedSegment]
            self.selection = next
            self.onSelectionChanged(next)
        }
        actionTarget.closeAction = { [weak self] in
            guard let self else { return }
            self.onClose?(self.selection)
        }
        control.target = actionTarget
        control.action = #selector(PilotSegmentedActionTarget.invokeControlAction(_:))
        control.closeButton.target = actionTarget
        control.closeButton.action = #selector(PilotSegmentedActionTarget.invokeCloseAction(_:))
        control.addSubview(control.closeButton)
        addSubview(control)
        control.cockpitPinToEdges(of: self)
        refreshFont()
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .cockpitUIZoomDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFont() }
        }
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() { configure() }

    private func refreshFont() {
        control.font = CockpitTypography.font(size: NSFont.systemFontSize(for: control.controlSize))
        control.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
    }

    isolated deinit {
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }

    private func configure() {
        control.segmentCount = options.count
        control.showsCloseButton = onClose != nil
        menuTargets.removeAll()
        for (index, option) in options.enumerated() {
            let title = optionTitle(option)
            control.setLabel(showsTitles ? title : "", forSegment: index)
            control.setToolTip(title, forSegment: index)
            if let symbol = optionImage(option) {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                image?.isTemplate = true
                control.setImage(image, forSegment: index)
            } else if onClose != nil {
                let size = PilotNativeSegmentedControl.closeSlotSize
                control.setImage(NSImage(size: NSSize(width: size, height: size)), forSegment: index)
            } else {
                control.setImage(nil, forSegment: index)
            }
            control.setAlignment(onClose == nil ? .center : .left, forSegment: index)
            if let items = menuItems?(option), !items.isEmpty {
                let menu = NSMenu()
                for item in items {
                    let target = PilotSegmentedActionTarget()
                    target.action = { _ in item.action() }
                    menuTargets.append(target)
                    let entry = NSMenuItem(title: item.title, action: #selector(PilotSegmentedActionTarget.invokeControlAction(_:)), keyEquivalent: "")
                    entry.target = target
                    entry.isEnabled = item.isEnabled
                    if item.isDestructive {
                        entry.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed])
                    }
                    menu.addItem(entry)
                }
                control.setMenu(menu, forSegment: index)
            } else {
                control.setMenu(nil, forSegment: index)
            }
        }
        updateSelection()
    }

    private func updateSelection() {
        control.selectedSegment = options.firstIndex(of: selection) ?? -1
        control.isCloseEnabled = canClose?(selection) ?? true
        control.updateCloseButton()
    }
}

@MainActor
private final class PilotSegmentedActionTarget: NSObject {
    var action: ((Any?) -> Void)?
    var closeAction: (() -> Void)?
    @objc func invokeControlAction(_ sender: Any?) { action?(sender) }
    @objc func invokeCloseAction(_ sender: Any?) { closeAction?() }
}

/// Fixed appearance-resolved text levels for labels drawn directly over glass.
enum GlassLegibleText {
    case primary
    case secondary

    static let primaryColor = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    }
    static let secondaryColor = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 0.68, alpha: 1) : NSColor(white: 0.36, alpha: 1)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                    .accessibilityHighContrastAqua,
                                    .accessibilityHighContrastDarkAqua]).map {
            $0 == .darkAqua || $0 == .vibrantDark || $0 == .accessibilityHighContrastDarkAqua
        } ?? false
    }
}
