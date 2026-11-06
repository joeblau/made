import AppKit

@MainActor
final class CockpitActionButton: NSButton {
    var onAction: () -> Void
    var baseFontSize: CGFloat = NSFont.systemFontSize { didSet { refreshFont() } }
    private var zoomObserver: NSObjectProtocol?

    init(title: String = "", systemImage: String? = nil, action: @escaping () -> Void) {
        onAction = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        if #available(macOS 26.0, *) { borderShape = .capsule }
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        if !title.isEmpty { setAccessibilityLabel(title) }
        target = self
        self.action = #selector(performAction(_:))
        refreshFont()
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .cockpitUIZoomDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFont() }
        }
    }

    required init?(coder: NSCoder) { nil }
    @objc private func performAction(_ sender: Any?) { onAction() }

    private func refreshFont() {
        font = CockpitTypography.font(size: baseFontSize)
        invalidateIntrinsicContentSize()
    }

    isolated deinit {
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }
}

@MainActor
final class CockpitLabel: NSTextField {
    var baseFontSize: CGFloat = NSFont.systemFontSize { didSet { refreshFont() } }
    var fontWeight: NSFont.Weight = .regular { didSet { refreshFont() } }
    var usesMonospacedFont = false { didSet { refreshFont() } }
    private var zoomObserver: NSObjectProtocol?

    init(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        super.init(frame: .zero)
        baseFontSize = size
        fontWeight = weight
        stringValue = text
        textColor = color
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        refreshFont()
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .cockpitUIZoomDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFont() }
        }
    }

    required init?(coder: NSCoder) { nil }
    private func refreshFont() {
        font = CockpitTypography.font(size: baseFontSize, weight: fontWeight, monospaced: usesMonospacedFont)
        invalidateIntrinsicContentSize()
    }

    isolated deinit {
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }
}

@MainActor
enum CockpitUI {
    static func label(
        _ text: String,
        size: CGFloat = NSFont.systemFontSize,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> CockpitLabel {
        CockpitLabel(text, size: size, weight: weight, color: color)
    }

    static func hStack(_ views: [NSView], spacing: CGFloat = LiquidGlassMetrics.Spacing.xSmall) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func vStack(_ views: [NSView], spacing: CGFloat = LiquidGlassMetrics.Spacing.xSmall) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func symbol(_ name: String, size: CGFloat = 16, color: NSColor = .secondaryLabelColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        view.contentTintColor = color
        view.setAccessibilityElement(false)
        return view
    }

    static func scrollView(documentView: NSView, horizontal: Bool = false) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = horizontal
        scroll.autohidesScrollers = true
        scroll.documentView = documentView
        return scroll
    }

    static func divider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        return divider
    }
}

extension NSView {
    /// Pins an already-added child, without retaining a controller or model.
    @MainActor
    func cockpitPinToEdges(of parent: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom)
        ])
    }
}

/// Opaque content surface; material belongs on navigation and controls.
@MainActor
final class CockpitCardView: NSView {
    let content: NSView
    var fillColor: NSColor = .controlBackgroundColor { didSet { refreshAppearance() } }
    var borderColor: NSColor = .separatorColor { didSet { refreshAppearance() } }
    var cornerRadius: CGFloat = LiquidGlassMetrics.Radius.card { didSet { refreshAppearance() } }

    init(content: NSView, padding: CGFloat = LiquidGlassMetrics.Spacing.small) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(content)
        content.cockpitPinToEdges(of: self, insets: NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding))
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillColor.cgColor
            layer?.borderColor = borderColor.cgColor
            layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
            layer?.cornerRadius = cornerRadius
        }
    }
}

/// Native glass with a legible opaque fallback for Reduce Transparency.
@MainActor
final class CockpitGlassView: NSView {
    let content: NSView
    var tintColor: NSColor? { didSet { configureSurface() } }
    var cornerRadius: CGFloat { didSet { configureSurface() } }
    var isInteractive: Bool { didSet { configureSurface() } }
    private var surface: NSView?
    private var accessibilityObserver: NSObjectProtocol?

    init(
        content: NSView,
        cornerRadius: CGFloat = LiquidGlassMetrics.Radius.panel,
        tintColor: NSColor? = nil,
        interactive: Bool = false
    ) {
        self.content = content
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        isInteractive = interactive
        super.init(frame: .zero)
        configureSurface()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureSurface() }
        }
    }

    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configureSurface()
    }

    private func configureSurface() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if #available(macOS 26.0, *), !reduceTransparency {
            let glass: NSGlassEffectView
            if let current = surface as? NSGlassEffectView {
                glass = current
            } else {
                content.removeFromSuperview()
                surface?.removeFromSuperview()
                glass = NSGlassEffectView()
                glass.contentView = content
                surface = glass
                addSubview(glass)
                glass.cockpitPinToEdges(of: self)
                content.cockpitPinToEdges(of: glass)
            }
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            if #available(macOS 27.0, *) { glass.effectIsInteractive = isInteractive }
        } else {
            let material: NSVisualEffectView
            if let current = surface as? NSVisualEffectView {
                material = current
            } else {
                content.removeFromSuperview()
                surface?.removeFromSuperview()
                material = NSVisualEffectView()
                surface = material
                addSubview(material)
                material.cockpitPinToEdges(of: self)
                material.addSubview(content)
                content.cockpitPinToEdges(of: material)
            }
            material.material = .popover
            material.blendingMode = .withinWindow
            material.state = reduceTransparency ? .inactive : .followsWindowActiveState
            material.wantsLayer = true
            material.layer?.cornerRadius = cornerRadius
            material.layer?.masksToBounds = true
            effectiveAppearance.performAsCurrentDrawingAppearance {
                material.layer?.backgroundColor = reduceTransparency
                    ? NSColor.windowBackgroundColor.cgColor
                    : tintColor?.cgColor
            }
        }
    }

    isolated deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }
}

/// Accessible empty/error/loading message with an optional native action.
@MainActor
final class CockpitStateView: NSView {
    let titleLabel: CockpitLabel
    let messageLabel: CockpitLabel
    let actionButton: CockpitActionButton?

    init(
        title: String,
        message: String,
        systemImage: String = "info.circle",
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        titleLabel = CockpitUI.label(title, size: 20, weight: .semibold)
        messageLabel = CockpitUI.label(message, size: 13, color: GlassLegibleText.secondaryColor)
        if let actionTitle, let action {
            actionButton = CockpitActionButton(title: actionTitle, action: action)
        } else {
            actionButton = nil
        }
        super.init(frame: .zero)
        let symbol = CockpitUI.symbol(systemImage, size: 36)
        titleLabel.alignment = .center
        messageLabel.alignment = .center
        var items: [NSView] = [symbol, titleLabel, messageLabel]
        if let actionButton { items.append(actionButton) }
        let stack = CockpitUI.vStack(items, spacing: LiquidGlassMetrics.Spacing.small)
        stack.alignment = .centerX
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 480)
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }
}
