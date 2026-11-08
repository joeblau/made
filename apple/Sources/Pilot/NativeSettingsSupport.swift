import AppKit
import Observation

@MainActor
enum NativeSettingsUI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, selectable: Bool = false) -> CockpitLabel {
        let field = CockpitUI.label(text, size: size, weight: weight, color: color)
        field.isSelectable = selectable
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func column(_ views: [NSView] = [], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    static func fillWidth(_ child: NSView, in stack: NSStackView) {
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    static func scrolling(_ stack: NSStackView, inset: CGFloat = 24) -> NSScrollView {
        let scroll = NSScrollView()
        configure(scroll, stack: stack, insets: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset), maxWidth: nil)
        return scroll
    }

    /// Settings pages: a centered column no wider than `pageMaxWidth`, with
    /// the page title living in the window's toolbar instead of the content.
    static func page(_ stack: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        embedPage(stack, in: scroll)
        return scroll
    }

    /// `page(_:)` for a controller that already owns its scroll view.
    static func embedPage(_ stack: NSStackView, in scroll: NSScrollView) {
        stack.spacing = pageGroupSpacing
        configure(scroll, stack: stack, insets: NSEdgeInsets(top: 12, left: 32, bottom: 32, right: 32), maxWidth: pageMaxWidth)
    }

    static let pageMaxWidth: CGFloat = 640
    static let pageGroupSpacing: CGFloat = 26

    private static func configure(_ scroll: NSScrollView, stack: NSStackView, insets: NSEdgeInsets, maxWidth: CGFloat?) {
        scroll.hasVerticalScroller = true
        // No empty track or gutter on pages that fit, even with "Always" scroll bars.
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = NativeSettingsFlippedView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: insets.top),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: insets.bottom)
        ])
        if let maxWidth {
            // Fill the pane up to `maxWidth`, then stay centered with wider margins.
            let fill = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -(insets.left + insets.right))
            fill.priority = .defaultHigh
            NSLayoutConstraint.activate([
                fill,
                stack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
                stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: insets.left)
            ])
        } else {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: insets.left),
                stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -insets.right)
            ])
        }
    }

    static func section(_ title: String, _ views: [NSView]) -> NSView {
        let contents = column([CockpitUI.label(title, role: .sectionTitle)] + views, spacing: 10)
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 10
        box.contentViewMargins = NSSize(width: 14, height: 14)
        box.contentView = contents
        contents.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalTo: contents.widthAnchor, constant: 28),
            box.heightAnchor.constraint(equalTo: contents.heightAnchor, constant: 28)
        ])
        for item in views where !(item is NSButton) {
            item.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
        }
        return box
    }

    static func error(_ message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cockpit"
        alert.informativeText = message
        alert.addButton(withTitle: "Dismiss")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

/// Xcode Settings–style grouped form building blocks: a bold header above
/// each borderless rounded card, and rows with an optional accent icon, a
/// title with optional secondary line, and trailing status, actions or value.
/// The page title lives in the Settings toolbar. Explanations belong in
/// tooltips, not in paragraphs on the page.
@MainActor
extension NativeSettingsUI {
    static func pageTitle(_ text: String) -> CockpitLabel {
        label(text, size: 22, weight: .bold)
    }

    /// A headed group. Pass `rows` built with `formRow`/`valueRow`, or any view.
    static func group(_ title: String? = nil, _ rows: [NSView]) -> NSStackView {
        let box = NativeSettingsGroupView()
        box.setRows(rows)
        return group(title, box: box)
    }

    static func group(_ title: String?, box: NativeSettingsGroupView) -> NSStackView {
        group(title.map { label($0, weight: .bold) }, box: box)
    }

    /// A group whose header text changes after creation (for example a count).
    static func group(_ header: NSTextField?, box: NativeSettingsGroupView) -> NSStackView {
        let stack = column(spacing: 8)
        if let header { fillWidth(groupHeader(header), in: stack) }
        fillWidth(box, in: stack)
        return stack
    }

    /// Section headers sit slightly inside the card's leading edge.
    static func groupHeader(_ header: NSTextField) -> NSView {
        let container = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: NativeSettingsGroupView.rowInsets.left - 4),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    /// Optional accent `icon` (an SF Symbol or asset name) in a fixed column,
    /// the title (and optional secondary line) leading, then trailing
    /// `status` text and `accessories` (buttons, switches, values).
    static func formRow(_ title: String, subtitle: NSView? = nil, icon: String? = nil, iconTint: NSColor = .controlAccentColor,
                        status: NSTextField? = nil, accessories: [NSView] = []) -> NSStackView {
        formRow(label(title), subtitle: subtitle, icon: icon, iconTint: iconTint, status: status, accessories: accessories)
    }

    static func formRow(_ title: NSTextField, subtitle: NSView? = nil, icon: String? = nil, iconTint: NSColor = .controlAccentColor,
                        status: NSTextField? = nil, accessories: [NSView] = []) -> NSStackView {
        title.maximumNumberOfLines = 2
        let text = column([title] + (subtitle.map { [$0] } ?? []), spacing: 2)
        for field in [title, subtitle].compactMap({ $0 }) as [NSView] {
            field.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let status {
            status.alignment = .right
            status.maximumNumberOfLines = 1
            if status.textColor == .labelColor { status.textColor = .secondaryLabelColor }
        }
        let trailing = (status.map { [$0] } ?? []) + accessories
        for accessory in trailing {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        let leading: [NSView] = icon.map { [NativeSettingsIconView(icon: $0, tint: iconTint)] } ?? []
        let stack = row(leading + [text] + trailing, spacing: 10)
        stack.distribution = .fill
        return stack
    }

    /// A read-only setting: title leading, value trailing.
    static func valueRow(_ title: String, value: String, icon: String? = nil, monospaced: Bool = false, help: String? = nil) -> NSStackView {
        let field = label(value, color: .secondaryLabelColor, selectable: true)
        field.usesMonospacedFont = monospaced
        field.alignment = .right
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = help ?? value
        let stack = formRow(title, icon: icon, accessories: [field])
        // Long values truncate before the title does.
        field.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        return stack
    }

    /// A compact `NSSwitch` used as a row accessory.
    static func toggle(_ accessibilityLabel: String, help: String? = nil) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.setAccessibilityLabel(accessibilityLabel)
        control.toolTip = help
        return control
    }
}

/// A decorative row icon in a fixed-width column that follows Cockpit zoom.
/// Accepts an SF Symbol name or an asset-catalog symbol name.
@MainActor
final class NativeSettingsIconView: NSImageView {
    static let pointSize: CGFloat = 19
    static let columnWidth: CGFloat = 28
    private var widthConstraint: NSLayoutConstraint?
    private var zoomObserver: NSObjectProtocol?

    init(icon: String, tint: NSColor = .controlAccentColor) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) ?? NSImage(named: icon)
        contentTintColor = tint
        imageScaling = .scaleProportionallyDown
        setAccessibilityElement(false)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.columnWidth)
        widthConstraint?.isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshScale()
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .cockpitUIZoomDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScale() }
        }
    }
    required init?(coder: NSCoder) { nil }

    private func refreshScale() {
        let zoom = CGFloat(CockpitUIZoomController.shared.factor)
        symbolConfiguration = .init(pointSize: Self.pointSize * zoom, weight: .regular)
        widthConstraint?.constant = Self.columnWidth * zoom
    }

    isolated deinit {
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }
}

/// Borderless rounded card that draws inset hairline dividers between rows.
@MainActor
final class NativeSettingsGroupView: NSView {
    static let rowInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 14)
    static let minimumRowHeight: CGFloat = 48
    private let stack = NSStackView()
    private var contrastObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        NativeSettingsUI.pin(stack, to: self)
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { nil }

    func setRows(_ rows: [NSView]) {
        NativeSettingsUI.clear(stack)
        let insets = Self.rowInsets
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                let inset = NSView()
                inset.translatesAutoresizingMaskIntoConstraints = false
                divider.translatesAutoresizingMaskIntoConstraints = false
                inset.addSubview(divider)
                NSLayoutConstraint.activate([
                    divider.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: insets.left),
                    divider.trailingAnchor.constraint(equalTo: inset.trailingAnchor, constant: -insets.right),
                    divider.centerYAnchor.constraint(equalTo: inset.centerYAnchor),
                    inset.heightAnchor.constraint(equalToConstant: 1),
                ])
                stack.addArrangedSubview(inset)
                inset.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let cell = NSView()
            cell.translatesAutoresizingMaskIntoConstraints = false
            row.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(row)
            // Rows center vertically in at least the minimum height.
            let top = row.topAnchor.constraint(equalTo: cell.topAnchor, constant: insets.top)
            top.priority = .defaultHigh
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: insets.left),
                row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -insets.right),
                row.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: insets.top),
                row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                top,
                cell.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumRowHeight),
            ])
            stack.addArrangedSubview(cell)
            cell.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CockpitCardStyle.cornerRadius
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        CockpitCardStyle.fillColor.setFill()
        path.fill()
        // Increase Contrast restores an edge the quiet fill alone cannot give.
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            NSColor.separatorColor.setStroke()
            edge.lineWidth = 1
            edge.stroke()
        }
    }

    isolated deinit {
        if let contrastObserver { NSWorkspace.shared.notificationCenter.removeObserver(contrastObserver) }
    }
}

final class NativeSettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class NativeSettingsButton: NSButton {
    private let handler: (NativeSettingsButton) -> Void

    init(_ title: String, action: @escaping () -> Void) {
        handler = { _ in action() }
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(invoke)
        configureTypography()
    }

    init(checkbox title: String, checked: Bool, action: @escaping (Bool) -> Void) {
        handler = { action($0.state == .on) }
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        state = checked ? .on : .off
        target = self
        self.action = #selector(invoke)
        configureTypography()
    }

    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler(self) }

    private func configureTypography() {
        refreshFont()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFont), name: .cockpitUIZoomDidChange, object: nil)
    }

    @objc private func refreshFont() {
        font = CockpitTypography.font(size: NSFont.systemFontSize)
        invalidateIntrinsicContentSize()
    }
}

/// Keeps editable values and the field editor intact when the user's text size changes.
@MainActor
final class NativeSettingsTextField: NSTextField {
    private let baseFontSize: CGFloat
    private let monospaced: Bool

    init(_ value: String = "", size: CGFloat = NSFont.systemFontSize, monospaced: Bool = false) {
        baseFontSize = size
        self.monospaced = monospaced
        super.init(frame: .zero)
        stringValue = value
        refreshFont()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFont), name: .cockpitUIZoomDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func refreshFont() {
        font = CockpitTypography.font(size: baseFontSize, monospaced: monospaced)
        currentEditor()?.font = font
        invalidateIntrinsicContentSize()
    }
}

@MainActor
final class NativeSettingsTextView: NSTextView {
    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        refreshFont()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFont), name: .cockpitUIZoomDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func refreshFont() {
        font = CockpitTypography.font(size: 11, monospaced: true)
    }
}

/// Observation is scoped to a visible controller. A queued callback from an
/// earlier presentation cannot restart observation after that controller hides.
@MainActor
final class NativeSettingsObservation {
    private var generation = 0
    private var update: (() -> Void)?

    func start(_ update: @escaping () -> Void) {
        generation += 1
        self.update = update
        track(generation)
    }

    func stop() {
        generation += 1
        update = nil
    }

    private func track(_ expected: Int) {
        guard expected == generation, let update else { return }
        withObservationTracking(update) { [weak self] in
            Task { @MainActor [weak self] in
                self?.track(expected)
            }
        }
    }
}

/// One native form sheet. Validation returns an inline error and leaves the
/// values editable; successful submission and cancellation each finish once.
@MainActor
final class NativeSettingsFormController: NSViewController {
    struct Field {
        var title: String
        var value = ""
        var placeholder = ""
    }

    private let heading: String
    private let detail: String
    private let fields: [Field]
    private let confirmTitle: String
    private let submit: ([String]) -> String?
    private var textFields: [NSTextField] = []
    private let errorLabel = NativeSettingsUI.label("", color: .systemRed)
    private var finished = false

    init(title: String, detail: String = "", fields: [Field], confirmTitle: String,
         submit: @escaping ([String]) -> String?) {
        heading = title
        self.detail = detail
        self.fields = fields
        self.confirmTitle = confirmTitle
        self.submit = submit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = NativeSettingsUI.column(spacing: 12)
        content.addArrangedSubview(NativeSettingsUI.label(heading, size: 20, weight: .semibold))
        if !detail.isEmpty { NativeSettingsUI.fillWidth(NativeSettingsUI.label(detail, color: .secondaryLabelColor), in: content) }
        for field in fields {
            content.addArrangedSubview(NativeSettingsUI.label(field.title, weight: .medium))
            let input = NativeSettingsTextField(field.value)
            input.placeholderString = field.placeholder
            input.setAccessibilityLabel(field.title)
            NativeSettingsUI.fillWidth(input, in: content)
            textFields.append(input)
        }
        NativeSettingsUI.fillWidth(errorLabel, in: content)
        let cancel = NativeSettingsButton("Cancel") { [weak self] in self?.finish() }
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NativeSettingsButton(confirmTitle) { [weak self] in self?.confirm() }
        confirm.keyEquivalent = "\r"
        NativeSettingsUI.fillWidth(NativeSettingsUI.row([NativeSettingsUI.spacer(), cancel, confirm]), in: content)
        view = NSView()
        NativeSettingsUI.pin(content, to: view, inset: 24)
        view.widthAnchor.constraint(equalToConstant: 480).isActive = true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let first = textFields.first { view.window?.makeFirstResponder(first) }
    }

    private func confirm() {
        guard !finished else { return }
        if let error = submit(textFields.map(\.stringValue)) { errorLabel.stringValue = error } else { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        dismiss(self)
    }
}
