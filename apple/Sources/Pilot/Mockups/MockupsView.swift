import AppKit
import Observation
import UniformTypeIdentifiers

/// Mock-ups studio: layout rail, shared 3D artboard, and backdrop inspector.
@MainActor
final class MockupsViewController: NSViewController, CockpitPanePresenting, CockpitPageToolbarProviding {
    let document = MockupDocument()
    private let defaults: UserDefaults
    private let observation = RRObservation()
    private let filters = CockpitToolbarGroups()
    var pageToolbarView: NSView { loadViewIfNeeded(); return filters }

    private let kindPicker = NSSegmentedControl(labels: MockupKind.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let aspectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var exportButton = RRButton("Export", symbol: "square.and.arrow.up") { [weak self] in self?.export() }

    private lazy var stage = MockupStageView(document: document)
    private let exporter = MockupVideoExporter()
    private var exportTask: Task<Void, Never>?
    private let center = MockupCenterView()
    private let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gallery = NSStackView()
    private var layoutButtons: [MockupLayoutButton] = []
    private let screenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let finishRow = NSStackView()
    private let styleControl = NSSegmentedControl(labels: MockupBackground.Style.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let swatches = MockupSwatchGrid()
    private lazy var chooseBackground = RRButton("Choose Image…", symbol: "photo") { [weak self] in self?.chooseBackgroundImage() }
    private let rotation = NSSlider(value: 0, minValue: -45, maxValue: 45, target: nil, action: nil)
    private let scale = NSSlider(value: 0.82, minValue: 0.3, maxValue: 1.1, target: nil, action: nil)
    private let tiltX = NSSlider(value: 0, minValue: -60, maxValue: 60, target: nil, action: nil)
    private let tiltY = NSSlider(value: 0, minValue: -90, maxValue: 90, target: nil, action: nil)
    private let positionX = NSSlider(value: 0, minValue: -0.5, maxValue: 0.5, target: nil, action: nil)
    private let positionY = NSSlider(value: 0, minValue: -0.5, maxValue: 0.5, target: nil, action: nil)
    private let openSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private lazy var openRow = Self.labeled("Open", openSlider)
    private lazy var chooseScreenshot = RRButton("Choose Screenshot…", symbol: "iphone") { [weak self] in self?.chooseScreenshotImage() }
    private lazy var timeline = MockupTimelineView(document: document)
    private let status = RRUI.label("", size: 11, color: .secondaryLabelColor)
    private var lastSolid = MockupColor(hex: 0x7CF866, space: .displayP3)
    private let colorFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorField = NSTextField()
    private let displayP3Toggle = NSSwitch()
    private lazy var colorRow = RRUI.stack([
        RRUI.stack([colorFormatPopup, colorField], axis: .horizontal),
        RRUI.stack([RRUI.label("Display P3", size: 12, color: .secondaryLabelColor), RRUI.spacer(), displayP3Toggle],
                   axis: .horizontal),
    ], spacing: 8)
    private var colorFormat: MockupColorFormat = .hex
    private var backdropSpace: MockupColor.Space = .displayP3
    private var lastGradient = MockupGradient.presets[0]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
        if let kind = defaults.string(forKey: "mockups.kind").flatMap(MockupKind.init(rawValue:)) { document.kind = kind }
        if let aspect = defaults.string(forKey: "mockups.aspect").flatMap(MockupAspectRatio.preset(id:)) { document.aspect = aspect }
        if let device = defaults.string(forKey: "mockups.device").flatMap(MockupDevice.init(rawValue:)) { document.device = device }
        if let layout = defaults.string(forKey: "mockups.layout").flatMap(MockupLayout.init(rawValue:)) { document.layout = layout }
        if let motion = defaults.string(forKey: "mockups.motion").flatMap(MockupMotion.init(rawValue:)) { document.motion = motion }
        if let data = defaults.data(forKey: "mockups.timeline"),
           let saved = try? JSONDecoder().decode(MockupTimeline.self, from: data), saved.isValid {
            document.timeline = saved
        } else {
            document.timeline = MockupTimeline.preset(document.motion, base: document.basePose)
        }
        if let format = defaults.string(forKey: MockupColorFormat.defaultsKey).flatMap(MockupColorFormat.init(rawValue:)) {
            colorFormat = format
        }
        if defaults.object(forKey: MockupColorFormat.displayP3DefaultsKey) != nil,
           !defaults.bool(forKey: MockupColorFormat.displayP3DefaultsKey) {
            backdropSpace = .sRGB
            lastSolid = lastSolid.interpreted(in: .sRGB)
            if case .solid(let color) = document.background { document.background = .solid(color.interpreted(in: .sRGB)) }
        }
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = RRBackgroundView()
        root.fillColor = NSColor(white: 0.07, alpha: 1)
        view = root
        view.setAccessibilityIdentifier("mockups.root")

        kindPicker.segmentStyle = .capsule
        kindPicker.controlSize = .small
        kindPicker.target = self
        kindPicker.action = #selector(changeKind)
        kindPicker.setAccessibilityLabel("Mock-up type")
        for preset in MockupAspectRatio.presets {
            aspectPopup.addItem(withTitle: "\(preset.group == "General" ? "" : preset.group + " · ")\(preset.name)  \(preset.label)")
            aspectPopup.lastItem?.representedObject = preset.id
        }
        aspectPopup.controlSize = .small
        aspectPopup.isBordered = false
        aspectPopup.target = self
        aspectPopup.action = #selector(changeAspect)
        aspectPopup.setAccessibilityLabel("Aspect ratio")
        filters.setAccessibilityIdentifier("mockups.toolbar-controls")
        // The toolbar group's glass capsule is the button's chrome; a bezel
        // inside it drew a second button within the first.
        exportButton.isBordered = false
        filters.setGroups([[kindPicker], [aspectPopup], [exportButton]])

        center.stage = stage
        center.document = document
        stage.onImportFailure = { [weak self] in self?.report($0) }
        stage.onLoadFailure = { [weak self] in self?.status.stringValue = $0 }
        stage.onTimeUpdate = { [weak self] _ in self?.timeline.updatePlayhead() }

        let rail = buildRail()
        let inspector = buildInspector()
        let centerColumn = RRUI.stack([center, timeline], spacing: 8)
        centerColumn.alignment = .centerX
        for item in [center, timeline] { item.widthAnchor.constraint(equalTo: centerColumn.widthAnchor).isActive = true }
        center.setContentHuggingPriority(.defaultLow, for: .vertical)

        let columns = RRUI.stack([rail, centerColumn, inspector], axis: .horizontal, spacing: 0)
        columns.alignment = .top
        columns.distribution = .fill
        for column in [rail, centerColumn, inspector] {
            column.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        }
        rail.widthAnchor.constraint(equalToConstant: 220).isActive = true
        inspector.widthAnchor.constraint(equalToConstant: 280).isActive = true
        RRUI.pin(columns, to: view)
        refreshControls()
    }

    override func viewWillAppear() { super.viewWillAppear(); updatePresentation(isActive: true, isSelected: true) }
    override func viewDidDisappear() { super.viewDidDisappear(); updatePresentation(isActive: false, isSelected: false) }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        if isActive {
            observation.start(tracking: { [document] in
                _ = document.kind; _ = document.aspect; _ = document.background; _ = document.device
                _ = document.finishIndex; _ = document.screenshot; _ = document.rotation; _ = document.scale
                _ = document.tiltX; _ = document.tiltY; _ = document.openAmount; _ = document.motion; _ = document.isPlaying
                _ = document.positionX; _ = document.positionY; _ = document.timeline; _ = document.selectedKeyframeID
                _ = document.layout; _ = document.selectedScreen
                for index in 0..<3 { _ = document.screenshot(at: index) }
            }, changed: { [weak self] in self?.documentChanged() })
            documentChanged()
        } else {
            observation.stop()
            if document.isPlaying { document.togglePlayback() }
            stage.update()
        }
    }

    private func documentChanged() {
        defaults.set(document.kind.rawValue, forKey: "mockups.kind")
        defaults.set(document.aspect.id, forKey: "mockups.aspect")
        defaults.set(document.device.rawValue, forKey: "mockups.device")
        defaults.set(document.layout.rawValue, forKey: "mockups.layout")
        defaults.set(document.motion.rawValue, forKey: "mockups.motion")
        defaults.set(try? JSONEncoder().encode(document.timeline), forKey: "mockups.timeline")
        center.needsLayout = true
        stage.update()
        refreshControls()
    }

    // MARK: - Columns

    private func buildRail() -> NSView {
        for device in MockupDevice.allCases {
            devicePopup.addItem(withTitle: device.name)
            devicePopup.lastItem?.representedObject = device.rawValue
        }
        devicePopup.controlSize = .small
        devicePopup.target = self
        devicePopup.action = #selector(changeDevice)
        devicePopup.setAccessibilityLabel("Device model")
        devicePopup.setAccessibilityIdentifier("mockups.device-picker")
        finishRow.orientation = .horizontal
        finishRow.spacing = 6
        gallery.orientation = .vertical
        gallery.alignment = .centerX
        gallery.spacing = 6
        let scroll = Self.scrolling(gallery)
        scroll.setAccessibilityIdentifier("mockups.layouts")
        let stack = RRUI.stack([
            RRUI.label("Device", size: 15, weight: .semibold), devicePopup, finishRow,
            RRUI.label("Layouts", size: 15, weight: .semibold), scroll,
        ], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 12, right: 12)
        for child in [devicePopup, scroll] { child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        return stack
    }

    private static func scrolling(_ content: NSView) -> NSScrollView {
        let scroll = CockpitUI.scrollView(documentView: content)
        // A flipped clip view anchors short and tall columns at the top;
        // AppKit's default clip view starts a scroll view at the bottom.
        let clip = MockupFlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = content
        scroll.automaticallyAdjustsContentInsets = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func buildInspector() -> NSView {
        styleControl.segmentStyle = .capsule
        styleControl.controlSize = .small
        styleControl.target = self
        styleControl.action = #selector(changeStyle)
        styleControl.setAccessibilityLabel("Background style")
        swatches.onSelect = { [weak self] index in self?.selectSwatch(index) }
        for format in MockupColorFormat.allCases { colorFormatPopup.addItem(withTitle: format.rawValue) }
        colorFormatPopup.controlSize = .small
        colorFormatPopup.target = self
        colorFormatPopup.action = #selector(changeColorFormat)
        colorFormatPopup.setAccessibilityLabel("Color format")
        colorFormatPopup.setContentHuggingPriority(.required, for: .horizontal)
        colorField.controlSize = .small
        colorField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        colorField.target = self
        colorField.action = #selector(colorFieldCommitted)
        colorField.setAccessibilityLabel("Backdrop color value")
        colorField.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        for row in colorRow.arrangedSubviews { row.widthAnchor.constraint(equalTo: colorRow.widthAnchor).isActive = true }
        displayP3Toggle.controlSize = .small
        displayP3Toggle.target = self
        displayP3Toggle.action = #selector(toggleDisplayP3)
        displayP3Toggle.setAccessibilityLabel("Display P3")
        displayP3Toggle.toolTip = "Pick backdrop colors in the wide Display P3 gamut instead of sRGB"
        for slider in [rotation, scale, tiltX, tiltY, positionX, positionY, openSlider] {
            slider.target = self
            slider.action = #selector(slidersChanged)
            slider.controlSize = .small
        }
        rotation.setAccessibilityLabel("Rotation")
        scale.setAccessibilityLabel("Device size")
        tiltX.setAccessibilityLabel("Tilt")
        tiltY.setAccessibilityLabel("Turn")
        positionX.setAccessibilityLabel("Horizontal position")
        positionY.setAccessibilityLabel("Vertical position")
        openSlider.setAccessibilityLabel("Open amount")
        screenPopup.controlSize = .small
        screenPopup.target = self
        screenPopup.action = #selector(changeScreen)
        screenPopup.setAccessibilityLabel("Screen to edit")
        screenPopup.setAccessibilityIdentifier("mockups.screen-picker")
        let clear = RRButton("Clear", symbol: "xmark") { [weak self] in self?.document.screenshot = nil }
        let stack = RRUI.stack([
            RRUI.label("Backdrop", size: 15, weight: .semibold),
            styleControl,
            swatches,
            colorRow,
            chooseBackground,
            RRUI.label("Device", size: 15, weight: .semibold),
            Self.labeled("Turn", tiltY),
            Self.labeled("Tilt", tiltX),
            Self.labeled("Rotation", rotation),
            Self.labeled("Move X", positionX),
            Self.labeled("Move Y", positionY),
            Self.labeled("Size", scale),
            openRow,
            RRUI.label("Screen", size: 15, weight: .semibold),
            screenPopup,
            RRUI.stack([chooseScreenshot, clear], axis: .horizontal),
            RRUI.label("Choose a screen, then drop or paste its image onto the canvas.", size: 11, color: .secondaryLabelColor),
            status,
            RRUI.spacer(),
        ], spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        RRUI.fillWidth(stack)
        return Self.scrolling(stack)
    }

    private static func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = RRUI.label(title, size: 12, color: .secondaryLabelColor)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return RRUI.stack([label, control], axis: .horizontal)
    }

    // MARK: - State → controls

    private func refreshLayouts() {
        guard layoutButtons.map(\.layout) != document.availableLayouts else { return }
        RRUI.clear(gallery)
        layoutButtons.removeAll()
        for layout in document.availableLayouts {
            if layout == .responsive {
                gallery.addArrangedSubview(RRUI.label("More layouts", size: 11, color: .secondaryLabelColor))
            }
            let button = MockupLayoutButton(layout: layout, document: document) { [weak self] in
                self?.document.selectLayout(layout)
            }
            gallery.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: gallery.widthAnchor).isActive = true
            layoutButtons.append(button)
        }
        gallery.layoutSubtreeIfNeeded()
        gallery.enclosingScrollView?.contentView.scroll(to: .zero)
    }

    private func refreshControls() {
        kindPicker.selectedSegment = MockupKind.allCases.firstIndex(of: document.kind) ?? 0
        if let index = MockupAspectRatio.presets.firstIndex(of: document.aspect) { aspectPopup.selectItem(at: index) }
        devicePopup.selectItem(withTitle: document.device.name)
        refreshLayouts()
        for button in layoutButtons {
            button.state = button.layout == document.layout ? .on : .off
            button.needsDisplay = true
        }
        let screenTitles = document.devices.enumerated().map { "\($0.offset + 1) · \($0.element.name)" }
        if screenPopup.itemTitles != screenTitles {
            screenPopup.removeAllItems()
            screenPopup.addItems(withTitles: screenTitles)
        }
        screenPopup.selectItem(at: document.selectedScreen)
        screenPopup.isHidden = document.devices.count == 1
        RRUI.clear(finishRow)
        for (index, finish) in document.device.finishes.enumerated() {
            let dot = MockupSwatchGrid.Dot(color: finish.swatch.nsColor, selected: index == document.finishIndex) { [weak self] in
                self?.document.finishIndex = index
            }
            dot.toolTip = finish.name
            dot.setAccessibilityLabel(finish.name)
            finishRow.addArrangedSubview(dot)
        }
        let style = document.background.style
        styleControl.selectedSegment = MockupBackground.Style.allCases.firstIndex(of: style) ?? 0
        switch document.background {
        case .solid(let color):
            let palette = MockupColor.palette(in: backdropSpace)
            swatches.items = palette.map { .solid($0.nsColor) }
            swatches.selectedIndex = palette.firstIndex(of: color)
        case .gradient(let gradient):
            swatches.items = MockupGradient.presets.map { .gradient($0.start.nsColor, $0.end.nsColor, $0.angle) }
            swatches.selectedIndex = MockupGradient.presets.firstIndex(of: gradient)
        case .none, .image:
            swatches.items = []
        }
        swatches.isHidden = swatches.items.isEmpty
        colorRow.isHidden = style != .solid
        colorFormatPopup.selectItem(withTitle: colorFormat.rawValue)
        displayP3Toggle.state = backdropSpace == .displayP3 ? .on : .off
        colorField.placeholderString = colorFormat.placeholder
        if case .solid(let color) = document.background, colorField.currentEditor() == nil {
            colorField.stringValue = colorFormat.string(for: color)
        }
        chooseBackground.isHidden = style != .image
        rotation.doubleValue = document.rotation
        scale.doubleValue = document.scale
        tiltX.doubleValue = document.tiltX * 180 / .pi
        tiltY.doubleValue = document.tiltY * 180 / .pi
        positionX.doubleValue = document.positionX
        positionY.doubleValue = document.positionY
        openSlider.doubleValue = document.openAmount
        openRow.isHidden = !stage.models.contains(where: \.hasHinge)
        timeline.isHidden = document.kind != .video
        timeline.refresh()
        if exportTask == nil { exportButton.title = document.kind == .photo ? "Export PNG" : "Export MP4" }
    }

    // MARK: - Actions

    @objc private func changeDevice() {
        guard let id = devicePopup.selectedItem?.representedObject as? String, let device = MockupDevice(rawValue: id) else { return }
        document.device = device
    }

    @objc private func changeScreen() {
        document.selectedScreen = max(screenPopup.indexOfSelectedItem, 0)
    }

    @objc private func changeKind() {
        if document.isPlaying { document.togglePlayback() }
        document.kind = MockupKind.allCases[max(kindPicker.selectedSegment, 0)]
        if document.kind == .video {
            document.seek(to: 0)
            document.isPlaying = true
        } else {
            document.selectedKeyframeID = nil
        }
    }

    @objc private func changeAspect() {
        guard let id = aspectPopup.selectedItem?.representedObject as? String, let preset = MockupAspectRatio.preset(id: id) else { return }
        document.aspect = preset
    }

    @objc private func changeStyle() {
        switch MockupBackground.Style.allCases[max(styleControl.selectedSegment, 0)] {
        case .none: document.background = .none
        case .solid: document.background = .solid(lastSolid)
        case .gradient: document.background = .gradient(lastGradient)
        case .image: chooseBackgroundImage()
        }
    }

    private func selectSwatch(_ index: Int) {
        switch document.background {
        case .solid where MockupColor.palette.indices.contains(index):
            lastSolid = MockupColor.palette(in: backdropSpace)[index]
            document.background = .solid(lastSolid)
        case .gradient where MockupGradient.presets.indices.contains(index):
            lastGradient = MockupGradient.presets[index]
            document.background = .gradient(lastGradient)
        default: break
        }
    }

    @objc private func changeColorFormat() {
        guard let title = colorFormatPopup.titleOfSelectedItem, let format = MockupColorFormat(rawValue: title) else { return }
        colorFormat = format
        defaults.set(format.rawValue, forKey: MockupColorFormat.defaultsKey)
        refreshControls()
    }

    /// Reinterprets the backdrop's values in the other space and remembers it.
    @objc private func toggleDisplayP3() {
        backdropSpace = displayP3Toggle.state == .on ? .displayP3 : .sRGB
        defaults.set(backdropSpace == .displayP3, forKey: MockupColorFormat.displayP3DefaultsKey)
        lastSolid = lastSolid.interpreted(in: backdropSpace)
        if case .solid(let color) = document.background { document.background = .solid(color.interpreted(in: backdropSpace)) }
        refreshControls()
    }

    /// Applies a typed value in the chosen format; invalid text reverts.
    @objc private func colorFieldCommitted() {
        guard case .solid(let current) = document.background else { return }
        guard let color = colorFormat.color(from: colorField.stringValue, space: backdropSpace) else {
            NSSound.beep()
            colorField.stringValue = colorFormat.string(for: current)
            return
        }
        lastSolid = color
        document.background = .solid(color)
        colorField.stringValue = colorFormat.string(for: color)
    }

    @objc private func slidersChanged() {
        document.rotation = rotation.doubleValue.rounded()
        document.scale = scale.doubleValue
        document.tiltX = tiltX.doubleValue * .pi / 180
        document.tiltY = tiltY.doubleValue * .pi / 180
        document.positionX = positionX.doubleValue
        document.positionY = positionY.doubleValue
        document.openAmount = openSlider.doubleValue
        document.updateSelectedPose()
    }

    private func chooseScreenshotImage() {
        let index = document.selectedScreen
        pickImage { [weak self] image in self?.document.setScreenshot(image, at: index) }
    }

    private func chooseBackgroundImage() {
        pickImage { [weak self] image in self?.document.background = .image(image) }
        refreshControls()
    }

    private func pickImage(_ completion: @escaping @MainActor (NSImage) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                switch MockupImageLoader.load(contentsOf: url) {
                case .success(let image): completion(image)
                case .failure(let failure): self?.report(failure)
                }
            }
        }
    }

    private func report(_ failure: MockupImageLoader.Failure) {
        status.stringValue = switch failure {
        case .tooLarge: "That image is larger than 64 MB."
        case .dimensions: "Images must be at most 12,000 px on each side."
        case .unreadable: "That file isn't a readable image."
        }
    }

    private func export() {
        if let exportTask {
            exporter.cancel()
            exportTask.cancel()
            return
        }
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        let isPhoto = document.kind == .photo
        panel.allowedContentTypes = [isPhoto ? .png : .mpeg4Movie]
        panel.nameFieldStringValue = "\(document.device.name) Mock-up.\(isPhoto ? "png" : "mp4")"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                if isPhoto { self.exportPhoto(to: url) } else { self.exportVideo(to: url) }
            }
        }
    }

    /// 3000 px on the long side; transparent when the backdrop is None.
    private func exportPhoto(to url: URL) {
        let ratio = document.aspect.ratio
        let size = ratio >= 1 ? CGSize(width: 3000, height: (3000 / ratio).rounded()) : CGSize(width: (3000 * ratio).rounded(), height: 3000)
        guard let image = stage.render(size: size, time: nil),
              let data = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
        else { status.stringValue = "Export failed."; return }
        do {
            try data.write(to: url, options: .atomic)
            status.stringValue = "Saved \(url.lastPathComponent)"
        } catch {
            status.stringValue = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Exports the exact keyframe timeline, including its final hold.
    private func exportVideo(to url: URL) {
        let settings = MockupVideoExporter.Settings.social(ratio: document.aspect.ratio, duration: document.timeline.duration)
        let wasPlaying = document.isPlaying
        if wasPlaying { document.togglePlayback() }
        exportButton.title = "Cancel"
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.exporter.export(to: url, settings: settings, progress: { [weak self] fraction in
                    self?.status.stringValue = "Exporting MP4… \(Int(fraction * 100))%"
                }, render: { [weak self] time in
                    self?.stage.render(size: settings.size, time: time)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                })
                self.status.stringValue = "Saved \(url.lastPathComponent) · \(Int(settings.size.width))×\(Int(settings.size.height)) H.264"
            } catch MockupVideoExporter.Failure.cancelled {
                self.status.stringValue = "Export cancelled."
            } catch {
                self.status.stringValue = "Export failed: \(error)"
            }
            self.exportTask = nil
            if wasPlaying { self.document.togglePlayback() }
            self.refreshControls()
        }
    }
}

/// Sizes the stage to the artboard so both modes share one aspect frame.
@MainActor
final class MockupCenterView: NSView {
    var stage: MockupStageView? { didSet { oldValue?.removeFromSuperview(); stage.map(addSubview) } }
    weak var document: MockupDocument?

    override func layout() {
        super.layout()
        guard let document else { return }
        stage?.frame = MockupAspectRatio.fit(ratio: document.aspect.ratio, in: bounds, inset: 24)
    }
}

/// Grid of round swatches (solid colors or gradients).
@MainActor
final class MockupSwatchGrid: NSView {
    enum Item: Equatable {
        case solid(NSColor)
        case gradient(NSColor, NSColor, CGFloat)
    }

    var items: [Item] = [] { didSet { if oldValue != items { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    private let columns = 6
    private let spacing: CGFloat = 8

    override var isFlipped: Bool { true }
    private var cell: CGFloat { max(16, (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)) }
    override var intrinsicContentSize: NSSize {
        let rows = (items.count + columns - 1) / columns
        let side: CGFloat = bounds.width > 0 ? cell : 36
        return NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows) * (side + spacing))
    }
    override func layout() { super.layout(); invalidateIntrinsicContentSize() }

    private func rect(_ index: Int) -> CGRect {
        CGRect(x: CGFloat(index % columns) * (cell + spacing), y: CGFloat(index / columns) * (cell + spacing), width: cell, height: cell)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, item) in items.enumerated() {
            let frame = rect(index).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(ovalIn: frame)
            switch item {
            case .solid(let color): color.setFill(); path.fill()
            case .gradient(let start, let end, let angle): NSGradient(starting: start, ending: end)?.draw(in: path, angle: angle)
            }
            if index == selectedIndex {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect(index).insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = items.indices.first(where: { rect($0).contains(point) }) { onSelect?(index) }
    }

    /// Single finish dot for the device rail.
    @MainActor
    final class Dot: NSControl {
        private let color: NSColor
        private let selected: Bool
        private let perform: () -> Void

        init(color: NSColor, selected: Bool, action: @escaping () -> Void) {
            self.color = color
            self.selected = selected
            perform = action
            super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            setAccessibilityRole(.button)
            widthAnchor.constraint(equalToConstant: 22).isActive = true
            heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).stroke()
            if selected {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                ring.stroke()
            }
        }
        override func mouseDown(with event: NSEvent) { perform() }
        override func accessibilityPerformPress() -> Bool { perform(); return true }
    }
}

private final class MockupFlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
