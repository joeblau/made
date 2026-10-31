import SceneKit
import SwiftUI

/// The fleet as Mac minis wired to GitHub. Busy runners light their cable and
/// stream packets, idle runners keep a dim connection, and offline runners go
/// dark with their status light off. Scroll moves down the rows; pinch zooms.
struct RunnerFleetView: View {
    let runners: [GitHubRunner]
    let scopeName: String
    let name: (GitHubRunner) -> String
    let hardware: (GitHubRunner) -> RunnerHardware
    let edit: (GitHubRunner) -> Void
    @State private var holder = FleetHolder()
    @State private var hover: RunnerFleetHover?
    @State private var showsDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fleet: RunnerFleetScene { holder.fleet }

    private var items: [RunnerFleetItem] {
        runners.map { RunnerFleetItem(id: $0.id, name: name($0), state: $0.state, hardware: hardware($0)) }
    }

    var body: some View {
        RunnerFleetSceneView(
            fleet: fleet,
            items: items,
            scopeName: scopeName,
            animatesData: !reduceMotion,
            hover: { hover = $0 },
            edit: { id in
                showsDetails = false
                if let runner = runners.first(where: { $0.id == id }) { edit(runner) }
            }
        )
        .overlay(alignment: .topLeading) { legend.padding(16) }
        .overlay(alignment: .topTrailing) { cameraControls.padding(16) }
        .overlay(alignment: .topLeading) { detailsAnchor }
        .environment(\.colorScheme, .dark)
        .task(id: hover) {
            guard let hover else {
                showsDetails = false
                return
            }
            // Clicks open immediately; hovering waits so crossing the fleet doesn't flash popovers.
            if !hover.isClick { try? await Task.sleep(for: .milliseconds(450)) }
            if !Task.isCancelled { showsDetails = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Runner fleet connected to GitHub")
        .accessibilityChildren {
            ForEach(runners) { runner in
                Text("\(name(runner)), \(runner.state.rawValue)")
                    .accessibilityAction(named: "Edit Device") { edit(runner) }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("Running a job", color: Color(red: 0.3, green: 0.75, blue: 1), opacity: 1)
            legendItem("Idle", color: Color(white: 0.24), opacity: 1)
            legendItem("Offline", color: Color(white: 0.12), opacity: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func legendItem(_ title: String, color: Color, opacity: Double) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color.opacity(opacity)).frame(width: 14, height: 4)
            Text(title)
        }
    }

    private var cameraControls: some View {
        VStack(spacing: 0) {
            controlButton("plus", help: "Zoom in") { fleet.zoom(by: 1.3, animated: true) }
            Divider().frame(width: 20)
            controlButton("minus", help: "Zoom out") { fleet.zoom(by: 1 / 1.3, animated: true) }
            Divider().frame(width: 20)
            controlButton("arrow.up.left.and.arrow.down.right", help: "Fit the whole fleet") { fleet.fitAll() }
            Divider().frame(width: 20)
            controlButton("arrow.up.to.line", help: "Back to GitHub") { fleet.frameTop() }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func controlButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    /// A 1-point anchor under the pointer so the details popover points at the runner.
    @ViewBuilder
    private var detailsAnchor: some View {
        if let hover, let runner = runners.first(where: { $0.id == hover.id }) {
            // Padding, not offset: popovers anchor to the layout frame.
            Color.clear
                .frame(width: 1, height: 1)
                .padding(.leading, hover.point.x)
                .padding(.top, hover.point.y)
                .popover(isPresented: $showsDetails, arrowEdge: .top) {
                    RunnerDetailsPopover(runner: runner, name: name(runner), hardware: hardware(runner))
                        .environment(\.colorScheme, .dark)
                }
        }
    }
}

/// Keeps one scene per view identity; `@State` evaluates its initial value on
/// every parent render, so the expensive scene is created lazily.
@MainActor
private final class FleetHolder {
    lazy var fleet = RunnerFleetScene()
}

struct RunnerFleetHover: Equatable {
    let id: Int
    /// Top-left-origin point in the view, where the popover arrow should land.
    let point: CGPoint
    let isClick: Bool
}

private struct RunnerFleetSceneView: NSViewRepresentable {
    let fleet: RunnerFleetScene
    let items: [RunnerFleetItem]
    let scopeName: String
    let animatesData: Bool
    let hover: (RunnerFleetHover?) -> Void
    let edit: (Int) -> Void

    func makeNSView(context: Context) -> FleetSCNView {
        let view = FleetSCNView(frame: .zero, options: nil)
        view.fleet = fleet
        view.scene = fleet.scene
        view.pointOfView = fleet.cameraNode
        view.backgroundColor = RunnerFleetScene.background
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateNSView(_ view: FleetSCNView, context: Context) {
        view.onHover = hover
        view.onEdit = edit
        view.content = (items, scopeName, animatesData)
    }
}

private final class FleetSCNView: SCNView {
    var fleet: RunnerFleetScene?
    var onHover: ((RunnerFleetHover?) -> Void)?
    var onEdit: ((Int) -> Void)?
    var content: ([RunnerFleetItem], String, Bool) = ([], "", true) {
        didSet { applyContent() }
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
        isPlaying = content.2 && content.0.contains { $0.state == .busy }
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
