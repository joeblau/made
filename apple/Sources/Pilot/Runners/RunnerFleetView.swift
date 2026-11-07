import AppKit
import SceneKit

struct RunnerFleetHover: Equatable {
    let id: Int
    let point: CGPoint
    let isClick: Bool
}

@MainActor
final class RunnerFleetViewController: NSViewController {
    private lazy var fleet = RunnerFleetScene()
    private var sceneView: FleetSCNView?
    private var runners: [GitHubRunner] = []
    private var displayNames: [Int: String] = [:]
    private var hardware: [Int: RunnerHardware] = [:]
    private var scopeName = ""
    var onEdit: (GitHubRunner) -> Void = { _ in }
    private var hoverTask: Task<Void, Never>?
    private var popover: NSPopover?
    private var active = false
    private var accessibilityObserver: NSObjectProtocol?

    isolated deinit {
        hoverTask?.cancel()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override func loadView() {
        let container = NSView()
        let scene = FleetSCNView(frame: .zero, options: nil)
        scene.fleet = fleet
        scene.scene = fleet.scene
        scene.pointOfView = fleet.cameraNode
        scene.backgroundColor = RunnerFleetScene.background
        scene.antialiasingMode = .multisampling4X
        scene.preferredFramesPerSecond = 120
        scene.onHover = { [weak self] hover in self?.showDetails(hover) }
        scene.onEdit = { [weak self] id in
            guard let self, let runner = self.runners.first(where: { $0.id == id }) else { return }
            self.hideDetails()
            self.onEdit(runner)
        }
        scene.setAccessibilityLabel("Runner fleet connected to GitHub. Use arrow keys to select a runner and Return to edit.")
        sceneView = scene
        RRUI.pin(scene, to: container)
        let legend = RRUI.stack([
            RRUI.label("● Running a job", size: 11, color: GitHubRunner.State.busy.fleetColor),
            RRUI.label("● Idle", size: 11, color: GitHubRunner.State.idle.fleetColor),
            RRUI.label("○ Offline", size: 11, color: .lightGray),
        ], axis: .horizontal, spacing: 14)
        // Apple Maps–style: related actions share one tall glass capsule.
        let motion = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        let controls = RRUI.stack([
            RunnerMapControls.capsule([
                .init(symbol: "plus", name: "Zoom in") { [weak self] in self?.fleet.zoom(by: 1.3, animated: motion()) },
                .init(symbol: "minus", name: "Zoom out") { [weak self] in self?.fleet.zoom(by: 1 / 1.3, animated: motion()) },
            ]),
            RunnerMapControls.capsule([
                .init(symbol: "arrow.up.left.and.arrow.down.right", name: "Fit the whole fleet") { [weak self] in
                    self?.fleet.fitAll(animated: motion())
                },
                .init(symbol: "arrow.up.to.line", name: "Back to top") { [weak self] in self?.fleet.frameTop(animated: motion()) },
            ]),
        ], spacing: RunnerMapControls.groupSpacing)
        controls.setAccessibilityElement(false)
        for child in [legend, controls] { child.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(child) }
        NSLayoutConstraint.activate([
            legend.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            legend.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        view = container
        applyContent()
    }

    func configure(runners: [GitHubRunner], scopeName: String,
                   name: (GitHubRunner) -> String, hardware: (GitHubRunner) -> RunnerHardware) {
        self.runners = runners
        self.scopeName = scopeName
        displayNames = Dictionary(uniqueKeysWithValues: runners.map { ($0.id, name($0)) })
        self.hardware = Dictionary(uniqueKeysWithValues: runners.map { ($0.id, hardware($0)) })
        if isViewLoaded { applyContent() }
    }

    func setPresentationActive(_ active: Bool) {
        self.active = active
        sceneView?.presentationActive = active
        if active, accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.applyContent() } }
        } else if !active {
            hideDetails()
            if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
            accessibilityObserver = nil
        }
    }

    override func viewDidAppear() { super.viewDidAppear(); setPresentationActive(true) }
    override func viewDidDisappear() { super.viewDidDisappear(); setPresentationActive(false) }

    private func applyContent() {
        sceneView?.content = (runners.map {
            RunnerFleetItem(id: $0.id, name: displayNames[$0.id] ?? $0.name, state: $0.state,
                            hardware: hardware[$0.id] ?? .inferred(for: $0))
        }, scopeName, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        sceneView?.presentationActive = active
    }

    private func hideDetails() {
        hoverTask?.cancel()
        hoverTask = nil
        popover?.close()
        popover = nil
    }

    private func showDetails(_ hover: RunnerFleetHover?) {
        hideDetails()
        guard active, let hover else { return }
        hoverTask = Task { @MainActor [weak self] in
            if !hover.isClick { try? await Task.sleep(for: .milliseconds(450)) }
            guard !Task.isCancelled, let self, self.active, let scene = self.sceneView,
                  let runner = self.runners.first(where: { $0.id == hover.id }) else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.contentViewController = RunnerDetailsViewController(
                runner: runner, name: self.displayNames[runner.id] ?? runner.name,
                hardware: self.hardware[runner.id] ?? .inferred(for: runner))
            self.popover = popover
            popover.show(relativeTo: NSRect(x: hover.point.x, y: scene.bounds.height - hover.point.y, width: 1, height: 1),
                         of: scene, preferredEdge: .maxY)
        }
    }
}

@MainActor
private final class FleetRunnerAccessibilityElement: NSAccessibilityElement {
    nonisolated let perform: @MainActor @Sendable () -> Void
    init(perform: @escaping @MainActor @Sendable () -> Void) {
        self.perform = perform
        super.init()
    }
    override nonisolated func accessibilityPerformPress() -> Bool {
        let action = perform
        return MainActor.assumeIsolated { action(); return true }
    }
}

@MainActor
private final class FleetSCNView: SCNView {
    var presentationActive = false {
        didSet { updatePlayback() }
    }
    var fleet: RunnerFleetScene?
    var onHover: ((RunnerFleetHover?) -> Void)?
    var onEdit: ((Int) -> Void)?
    var content: ([RunnerFleetItem], String, Bool) = ([], "", true) {
        didSet {
            guard content.0 != oldValue.0 || content.1 != oldValue.1 || content.2 != oldValue.2 else {
                return
            }
            applyContent()
        }
    }
    private var columns = 0
    private var hoveredID: Int?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        fleet?.resize(bounds.size)
        let columns = RunnerFleetLayout.columns(forWidth: bounds.width)
        if columns != self.columns {
            self.columns = columns
            applyContent()
        }
    }

    private func applyContent() {
        guard columns > 0 else { return }
        fleet?.update(content.0, columns: columns, hubTitle: content.1, animatesData: content.2)
        // Render continuously only while packets flow; otherwise SceneKit draws on change.
        updatePlayback()
    }

    private func updatePlayback() {
        isPlaying = presentationActive && window != nil && content.2 && content.0.contains { $0.state == .busy }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePlayback()
    }

    override func keyDown(with event: NSEvent) {
        let items = content.0
        guard !items.isEmpty else { super.keyDown(with: event); return }
        let current = items.firstIndex { $0.id == hoveredID } ?? 0
        switch event.keyCode {
        case 123, 126: setHover(items[max(0, current - 1)].id, isClick: true)
        case 124, 125: setHover(items[min(items.count - 1, current + 1)].id, isClick: true)
        case 36: onEdit?(items[current].id)
        case 49: setHover(items[current].id, isClick: true)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        content.0.map { item in
            let element = FleetRunnerAccessibilityElement { [weak self] in self?.onEdit?(item.id) }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("\(item.name), \(item.state.rawValue)")
            element.setAccessibilityParent(self)
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(bounds, to: nil)))
            }
            return element
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func scrollWheel(with event: NSEvent) {
        // Precise deltas are points; wheel deltas are lines.
        let scale: Float = event.hasPreciseScrollingDeltas ? 0.0016 : 0.03
        fleet?.pan(dx: -Float(event.scrollingDeltaX) * scale, dz: -Float(event.scrollingDeltaY) * scale)
        setHover(nil)
    }

    override func magnify(with event: NSEvent) {
        fleet?.zoom(by: Float(1 + event.magnification))
        setHover(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(runner(at: event), isClick: false)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, let id = runner(at: event) {
            onEdit?(id)
        } else {
            setHover(runner(at: event), isClick: true)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = runner(at: event) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Edit Device…", action: #selector(editFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.tag = id
        menu.addItem(item)
        return menu
    }

    @objc private func editFromMenu(_ item: NSMenuItem) {
        onEdit?(item.tag)
    }

    private func runner(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .boundingBoxOnly: true,
            .categoryBitMask: RunnerFleetScene.pickableCategory,
            .ignoreHiddenNodes: true,
        ])
        return hits.lazy.compactMap { [fleet] hit in fleet?.runnerID(for: hit.node) }.first
    }

    private func setHover(_ id: Int?, isClick: Bool = false) {
        guard id != hoveredID || isClick else { return }
        hoveredID = id
        guard let id, let anchor = fleet?.anchor(for: id) else {
            onHover?(nil)
            return
        }
        let projected = projectPoint(anchor)
        onHover?(RunnerFleetHover(
            id: id, point: CGPoint(x: CGFloat(projected.x), y: bounds.height - CGFloat(projected.y)), isClick: isClick
        ))
    }
}

/// Map controls drawn like Apple Maps: square hit targets stacked inside a
/// Liquid Glass capsule, with no dividers between related actions.
@MainActor
enum RunnerMapControls {
    static let side: CGFloat = 44
    static let groupSpacing: CGFloat = 10

    struct Item {
        let symbol: String
        let name: String
        let action: () -> Void
    }

    static func capsule(_ items: [Item]) -> CockpitGlassView {
        let stack = NSStackView(views: items.map(button))
        stack.orientation = .vertical
        stack.spacing = 0
        let capsule = CockpitGlassView(content: stack, cornerRadius: side / 2, interactive: true)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            capsule.widthAnchor.constraint(equalToConstant: side),
            capsule.heightAnchor.constraint(equalToConstant: side * CGFloat(items.count)),
        ])
        return capsule
    }

    private static func button(_ item: Item) -> NSView {
        let button = RunnerMapControlButton(action: item.action)
        button.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.name)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        button.toolTip = item.name
        button.setAccessibilityLabel(item.name)
        button.setAccessibilityIdentifier("runners.map." + item.symbol)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: side),
            button.heightAnchor.constraint(equalToConstant: side),
        ])
        return button
    }
}

/// A borderless glyph button; the capsule behind it supplies the glass.
@MainActor
final class RunnerMapControlButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .labelColor
        target = self
        self.action = #selector(runHandler)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func runHandler() { handler() }
}
