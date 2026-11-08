import AppKit

@MainActor
final class MockupTimelineView: NSView {
    private let document: MockupDocument
    private let trackView: MockupTimelineTrackView
    private lazy var playButton = RRButton("", symbol: "play.fill") { [weak self] in self?.document.togglePlayback() }
    private lazy var previousButton = RRButton("", symbol: "chevron.backward") { [weak self] in self?.document.stepKeyframe(-1) }
    private lazy var nextButton = RRButton("", symbol: "chevron.forward") { [weak self] in self?.document.stepKeyframe(1) }
    private lazy var addButton = RRButton("", symbol: "plus") { [weak self] in self?.document.addKeyframe() }
    private lazy var deleteButton = RRButton("", symbol: "trash") { [weak self] in self?.document.deleteSelectedKeyframe() }
    private let timeLabel = RRUI.label("0.00 / 0.00 s", size: 11, color: .secondaryLabelColor)
    private let motionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let easingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let durationSlider = NSSlider(value: 1, minValue: MockupTimeline.minimumDuration, maxValue: 30, target: nil, action: nil)
    private let durationLabel = RRUI.label("", size: 11, color: .secondaryLabelColor)

    init(document: MockupDocument) {
        self.document = document
        trackView = MockupTimelineTrackView(document: document)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        layer?.cornerRadius = 10
        setAccessibilityIdentifier("mockups.timeline")
        setAccessibilityLabel("Animation timeline")

        playButton.setAccessibilityLabel("Play or pause animation")
        previousButton.setAccessibilityLabel("Previous keyframe")
        nextButton.setAccessibilityLabel("Next keyframe")
        addButton.setAccessibilityLabel("Add keyframe at playhead")
        addButton.toolTip = "Capture the current device pose at the playhead"
        deleteButton.setAccessibilityLabel("Delete selected keyframe")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        configure(motionPopup, items: MockupMotion.allCases.map(\.rawValue), action: #selector(changeMotion))
        motionPopup.setAccessibilityLabel("Motion preset")
        configure(easingPopup, items: MockupEasing.allCases.map(\.rawValue), action: #selector(changeEasing))
        easingPopup.setAccessibilityLabel("Selected transition easing")
        durationSlider.target = self
        durationSlider.action = #selector(changeDuration)
        durationSlider.controlSize = .small
        durationSlider.setAccessibilityLabel("Selected transition duration")
        durationSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        durationLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let transport = RRUI.stack([
            playButton, previousButton, nextButton, addButton, deleteButton,
            timeLabel, RRUI.spacer(), RRUI.label("Preset", size: 11, color: .secondaryLabelColor), motionPopup,
        ], axis: .horizontal, spacing: 7)
        let transition = RRUI.stack([
            RRUI.label("Transition", size: 11, color: .secondaryLabelColor), easingPopup,
            RRUI.label("Duration", size: 11, color: .secondaryLabelColor), durationSlider, durationLabel,
            RRUI.spacer(),
        ], axis: .horizontal, spacing: 7)
        let stack = RRUI.stack([transport, transition, trackView], spacing: 6)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
        RRUI.pin(stack, to: self, inset: 0)
        trackView.heightAnchor.constraint(equalToConstant: 88).isActive = true
        heightAnchor.constraint(equalToConstant: 170).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func configure(_ popup: NSPopUpButton, items: [String], action: Selector) {
        popup.addItems(withTitles: items)
        popup.controlSize = .small
        popup.target = self
        popup.action = action
    }

    func refresh() {
        motionPopup.selectItem(withTitle: document.motion.rawValue)
        playButton.image = NSImage(systemSymbolName: document.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        deleteButton.isEnabled = document.selectedKeyframe != nil && document.timeline.keyframes.count > 1
        durationSlider.isEnabled = document.selectedKeyframe != nil
        if let keyframe = document.selectedKeyframe {
            easingPopup.selectItem(withTitle: keyframe.easing.rawValue)
            durationSlider.doubleValue = keyframe.duration
            durationLabel.stringValue = String(format: "%.1fs", keyframe.duration)
        } else {
            durationLabel.stringValue = "—"
        }
        let selectedIndex = document.timeline.keyframes.firstIndex { $0.id == document.selectedKeyframeID }
        easingPopup.isEnabled = selectedIndex.map { $0 < document.timeline.keyframes.count - 1 } == true
        trackView.needsDisplay = true
        updatePlayhead()
    }

    func updatePlayhead() {
        timeLabel.stringValue = String(format: "%.2f / %.2f s", document.playhead, document.timeline.duration)
        trackView.needsDisplay = true
    }

    @objc private func changeMotion() {
        guard let title = motionPopup.titleOfSelectedItem, let motion = MockupMotion(rawValue: title) else { return }
        document.applyMotion(motion)
    }

    @objc private func changeEasing() {
        guard let title = easingPopup.titleOfSelectedItem, let easing = MockupEasing(rawValue: title) else { return }
        document.setSelectedEasing(easing)
    }

    @objc private func changeDuration() {
        document.setSelectedDuration(durationSlider.doubleValue)
    }
}

@MainActor
final class MockupTimelineTrackView: NSView {
    private let document: MockupDocument
    private var draggedKeyframe: MockupKeyframe.ID?
    private let leading: CGFloat = 64
    private let trailing: CGFloat = 12
    private let rulerHeight: CGFloat = 26
    private let trackY: CGFloat = 39
    private let trackHeight: CGFloat = 39

    init(document: MockupDocument) {
        self.document = document
        super.init(frame: .zero)
        setAccessibilityIdentifier("mockups.timeline.track")
        setAccessibilityLabel("Device pose keyframes. Click to scrub; drag a diamond to retime it.")
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var timelineWidth: CGFloat { max(1, bounds.width - leading - trailing) }
    private var pixelsPerSecond: CGFloat { timelineWidth / CGFloat(max(document.timeline.duration, 0.001)) }
    private func x(for time: Double) -> CGFloat { leading + CGFloat(time) * pixelsPerSecond }
    private func time(for xPosition: CGFloat) -> Double { Double((xPosition - leading) / pixelsPerSecond) }
    private var diamondY: CGFloat { trackY + trackHeight / 2 }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawRuler()
        NSColor.secondaryLabelColor.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: leading, y: trackY, width: timelineWidth, height: trackHeight), xRadius: 5, yRadius: 5).fill()
        "DEVICE".draw(at: NSPoint(x: 8, y: trackY + 13), withAttributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        for (index, keyframe) in document.timeline.keyframes.enumerated() {
            let start = document.timeline.startTime(at: index)
            let rect = NSRect(x: x(for: start) + 1, y: trackY + 1,
                              width: max(1, CGFloat(keyframe.duration) * pixelsPerSecond - 2), height: trackHeight - 2)
            NSColor.controlAccentColor.withAlphaComponent(index.isMultiple(of: 2) ? 0.23 : 0.34).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let title = index == document.timeline.keyframes.count - 1 ? "Hold" : keyframe.easing.rawValue
            if rect.width > 64 {
                title.draw(in: rect.insetBy(dx: 8, dy: 12), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ])
            }
            drawDiamond(at: NSPoint(x: x(for: start), y: diamondY), selected: keyframe.id == document.selectedKeyframeID)
        }
        drawPlayhead()
    }

    private func drawRuler() {
        let intervals = [0.1, 0.25, 0.5, 1, 2, 5, 10]
        let interval = intervals.first { CGFloat($0) * pixelsPerSecond >= 62 } ?? 10
        NSColor.separatorColor.setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: leading, y: rulerHeight - 0.5))
        baseline.line(to: NSPoint(x: leading + timelineWidth, y: rulerHeight - 0.5))
        baseline.stroke()
        var value = 0.0
        while value <= document.timeline.duration + 0.001 {
            let position = x(for: value)
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: position, y: rulerHeight - 6))
            tick.line(to: NSPoint(x: position, y: rulerHeight))
            NSColor.separatorColor.setStroke()
            tick.stroke()
            String(format: value == 0 ? "%.0fs" : "%gs", value).draw(at: NSPoint(x: position + 3, y: 4), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            value += interval
        }
    }

    private func drawDiamond(at center: NSPoint, selected: Bool) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y - 8))
        path.line(to: NSPoint(x: center.x + 6, y: center.y))
        path.line(to: NSPoint(x: center.x, y: center.y + 8))
        path.line(to: NSPoint(x: center.x - 6, y: center.y))
        path.close()
        (selected ? NSColor.controlAccentColor : NSColor.white).setFill()
        path.fill()
        (selected ? NSColor.white : NSColor.controlAccentColor).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()
    }

    private func drawPlayhead() {
        let position = x(for: min(max(document.playhead, 0), document.timeline.duration))
        NSColor.systemRed.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: position, y: rulerHeight - 2))
        line.line(to: NSPoint(x: position, y: bounds.height - 2))
        line.lineWidth = 1.5
        line.stroke()
        NSColor.systemRed.setFill()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: position - 5, y: rulerHeight - 2))
        head.line(to: NSPoint(x: position + 5, y: rulerHeight - 2))
        head.line(to: NSPoint(x: position, y: rulerHeight + 6))
        head.close()
        head.fill()
    }

    private func keyframe(at point: NSPoint) -> MockupKeyframe? {
        guard let index = document.timeline.keyframes.indices.first(where: { index in
            let start = document.timeline.startTime(at: index)
            return abs(point.x - x(for: start)) <= 9 && abs(point.y - diamondY) <= 13
        }) else { return nil }
        return document.timeline.keyframes[index]
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let keyframe = keyframe(at: point) {
            document.selectKeyframe(keyframe.id)
            draggedKeyframe = keyframe.id
        } else {
            document.seek(to: time(for: point.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggedKeyframe != nil {
            document.moveSelectedKeyframe(to: time(for: point.x))
        } else {
            document.seek(to: time(for: point.x))
        }
    }

    override func mouseUp(with event: NSEvent) { draggedKeyframe = nil }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:
            document.togglePlayback()
        case 51, 117:
            document.deleteSelectedKeyframe()
        case 123:
            document.seek(to: document.playhead - (event.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        case 124:
            document.seek(to: document.playhead + (event.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        default:
            super.keyDown(with: event)
        }
    }
}
