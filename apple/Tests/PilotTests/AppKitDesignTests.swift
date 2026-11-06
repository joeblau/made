import AppKit
import Observation
import Testing
@testable import Pilot

@Suite("Native design and observation", .serialized)
@MainActor
struct AppKitDesignTests {
    @Observable
    final class Model {
        var value = 0
    }

    private final class Owner {
        let model: Model
        var renderedValues: [Int] = []
        init(model: Model) { self.model = model }
    }

    @Test("Detached observation ignores queued callbacks and reattaches to current state")
    func observationFencesDetachedGeneration() async throws {
        let model = Model()
        let owner = Owner(model: model)
        let observation = CockpitObservation(owner: owner) {
            $0.renderedValues.append($0.model.value)
        }
        observation.start()
        #expect(owner.renderedValues == [0])
        model.value = 1
        observation.stop()
        try await Task.sleep(for: .milliseconds(10))
        #expect(owner.renderedValues == [0])

        observation.start()
        #expect(owner.renderedValues == [0, 1])
        model.value = 2
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while owner.renderedValues.last != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.renderedValues == [0, 1, 2])
        observation.stop()
    }

    @Test("Observation does not retain its controller owner")
    func observationReleasesOwner() {
        let model = Model()
        var owner: Owner? = Owner(model: model)
        weak let releasedOwner = owner
        let observation = CockpitObservation(owner: owner!) {
            $0.renderedValues.append($0.model.value)
        }
        observation.start()
        owner = nil
        #expect(releasedOwner == nil)
        model.value = 1
        observation.stop()
    }

    @Test("Zoom normalizes stored values and preserves its preference key")
    func zoomPreferences() throws {
        let name = "app.blau.pilot.appkit-design-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1.29, forKey: "ui.zoom")
        let zoom = CockpitUIZoomController(defaults: defaults)
        #expect(zoom.factor == 1.3)
        zoom.increase()
        #expect(zoom.factor == 1.5)
        #expect(defaults.double(forKey: "ui.zoom") == 1.5)
        zoom.factor = .infinity
        #expect(zoom.factor == 1)
        zoom.decrease()
        #expect(zoom.factor == 0.85)
        zoom.decrease()
        #expect(zoom.factor == 0.85)
        zoom.reset()
        #expect(zoom.factor == UIZoomLadder.default)
        #expect(CockpitTypography.font(size: 12, zoom: 1.5).pointSize == 18)
    }

    @Test("Native segmented controls dispatch typed selection once")
    func segmentedSelection() {
        var selections: [String] = []
        let view = PilotSegmentedControl(
            "Inspector", selection: "files", options: ["files", "actions"],
            title: { $0.capitalized }, onSelectionChanged: { selections.append($0) }
        )
        #expect(view.control.selectedSegment == 0)
        view.control.selectedSegment = 1
        view.control.sendAction(view.control.action, to: view.control.target)
        #expect(view.selection == "actions")
        #expect(selections == ["actions"])
        view.selection = "files"
        #expect(view.control.selectedSegment == 0)
        #expect(selections.count == 1)
        #expect(view.control.accessibilityLabel() == "Inspector")
    }

    @Test("Appearance reporting follows connection and window override")
    func appearanceReporting() {
        var values: [Bool] = []
        let reporter = AppearanceReporter { values.append($0) }
        reporter.appearance = NSAppearance(named: .darkAqua)
        reporter.isConnected = true
        #expect(values.last == true)
        reporter.report()
        #expect(values.count == 1)
        reporter.isConnected = false
        reporter.appearance = NSAppearance(named: .aqua)
        reporter.report()
        #expect(values.count == 1)
        reporter.isConnected = true
        #expect(values == [true, false])
    }
}
