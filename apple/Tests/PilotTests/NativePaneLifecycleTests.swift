import AppKit
import SwiftData
import XCTest
@testable import Pilot

final class NativePaneLifecycleTests: XCTestCase {
    private enum SaveFailure: Error { case rejected }

    @MainActor
    func testMainWorkspaceKeepsFinalPaneWhileExtendoCanRemoveIt() throws {
        let (container, workspace, pane) = try singlePaneFixture()
        XCTAssertFalse(workspace.removePane(pane))
        XCTAssertEqual(workspace.panes.map(\.id), [pane.id])
        XCTAssertEqual(workspace.selectedPaneID, pane.id)
        XCTAssertTrue(workspace.removePane(pane, allowEmpty: true))
        XCTAssertTrue(workspace.panes.isEmpty)
        XCTAssertNil(workspace.selectedPaneID)
        XCTAssertNil(workspace.frontmostTerminalPaneID)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    @MainActor
    func testFailedFinalPaneRemovalRestoresMembershipAndSelection() throws {
        let (container, workspace, pane) = try singlePaneFixture()
        XCTAssertFalse(workspace.removePane(pane, allowEmpty: true, performSave: { _ in
            throw SaveFailure.rejected
        }))
        XCTAssertEqual(workspace.panes.map(\.id), [pane.id])
        XCTAssertEqual(workspace.selectedPaneID, pane.id)
        XCTAssertEqual(workspace.frontmostTerminalPaneID, pane.id)
        XCTAssertTrue(pane.workspace === workspace)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    @MainActor
    func testCacheRetainsIdentityAndUpdatesContextWithoutRecreatingPane() {
        let cache = CockpitPaneControllerCache()
        let pane = Pane(kind: .editor, sortOrder: 0)
        let controller = LifecyclePaneController()
        var creations = 0
        let first = cache.controller(for: pane, rootPath: "/fixture/first") { _, _ in
            creations += 1
            return controller
        }
        let second = cache.controller(for: pane, rootPath: "/fixture/second") { _, _ in
            creations += 1
            return LifecyclePaneController()
        }
        XCTAssertTrue(first === second)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(controller.roots, ["/fixture/first", "/fixture/second"])
        XCTAssertEqual(controller.closeCount, 0)
        cache.closeAll()
    }

    @MainActor
    func testWorkspaceDetachAndCollapseKeepTheSessionUntilMembershipEviction() {
        let cache = CockpitPaneControllerCache()
        let pane = Pane(kind: .editor, sortOrder: 0)
        let workspace = Workspace(name: "Fixture")
        workspace.panes = [pane]
        pane.workspace = workspace
        workspace.selectedPaneID = pane.id
        let controller = LifecyclePaneController()
        var creations = 0
        let presentation = CockpitWorkspaceViewController(
            workspace: workspace, projectID: workspace.id, surface: .main,
            cache: cache, factory: { _, _ in
                creations += 1
                return controller
            }, onDrop: { _, _ in false }
        )
        presentation.refresh(isActive: true)
        XCTAssertTrue(controller.parent === presentation)
        XCTAssertEqual(controller.presentations.last, .init(active: true, selected: true))

        presentation.deactivate()
        XCTAssertNil(controller.parent)
        XCTAssertNil(controller.view.superview)
        XCTAssertEqual(controller.presentations.last, .init(active: false, selected: false))
        XCTAssertEqual(controller.closeCount, 0)
        XCTAssertTrue(cache.existingController(for: pane.id) === controller)

        presentation.refresh(isActive: true)
        pane.isCollapsed = true
        presentation.refresh(isActive: true)
        XCTAssertNil(controller.view.superview)
        XCTAssertEqual(controller.closeCount, 0)
        pane.isCollapsed = false
        presentation.refresh(isActive: true)
        XCTAssertTrue(controller.parent === presentation)
        XCTAssertEqual(creations, 1)

        cache.retainOnly([])
        XCTAssertNil(controller.parent)
        XCTAssertNil(controller.view.superview)
        XCTAssertEqual(controller.closeCount, 1)
        XCTAssertNil(cache.existingController(for: pane.id))
    }

    @MainActor
    func testSourceDetachDoesNotDeactivateControllerAlreadyTransferredToTarget() {
        let cache = CockpitPaneControllerCache()
        let pane = Pane(kind: .editor, sortOrder: 0)
        let source = Workspace(name: "Source")
        let target = Workspace(name: "Target")
        source.panes = [pane]
        source.selectedPaneID = pane.id
        target.panes = []
        pane.workspace = source
        let controller = LifecyclePaneController()
        let makePane: (Pane, String?) -> NSViewController = { _, _ in controller }
        let sourceView = CockpitWorkspaceViewController(
            workspace: source, projectID: source.id, surface: .main,
            cache: cache, factory: makePane, onDrop: { _, _ in false }
        )
        let targetView = CockpitWorkspaceViewController(
            workspace: target, projectID: source.id, surface: .extension,
            cache: cache, factory: makePane, onDrop: { _, _ in false }
        )
        sourceView.refresh(isActive: true)
        source.panes = []
        target.panes = [pane]
        target.selectedPaneID = pane.id
        pane.workspace = target
        // Observation may refresh the destination before the source.
        targetView.refresh(isActive: true)
        sourceView.refresh(isActive: true)
        XCTAssertTrue(controller.parent === targetView)
        XCTAssertNotNil(controller.view.superview)
        XCTAssertEqual(controller.presentations.last, .init(active: true, selected: true))
        XCTAssertEqual(controller.closeCount, 0)
        XCTAssertTrue(cache.existingController(for: pane.id) === controller)
        cache.closeAll()
    }

    @MainActor
    func testEvictionClosesOnlyRemovedPaneAndDoesNotRepeatClose() {
        let cache = CockpitPaneControllerCache()
        let first = Pane(kind: .editor, sortOrder: 0)
        let second = Pane(kind: .editor, sortOrder: 1)
        let removed = LifecyclePaneController()
        let retained = LifecyclePaneController()
        _ = cache.controller(for: first, rootPath: nil) { _, _ in removed }
        _ = cache.controller(for: second, rootPath: nil) { _, _ in retained }
        cache.retainOnly([second.id])
        cache.retainOnly([second.id])
        XCTAssertEqual(removed.closeCount, 1)
        XCTAssertEqual(removed.presentations, [.init(active: false, selected: false)])
        XCTAssertEqual(retained.closeCount, 0)
        XCTAssertTrue(cache.existingController(for: second.id) === retained)
        cache.closeAll()
        cache.closeAll()
        XCTAssertEqual(removed.closeCount, 1)
        XCTAssertEqual(retained.closeCount, 1)
    }

    @MainActor
    func testAsyncCloseRejectionStopsValidationWithoutClosingAnyPane() async {
        let first = LifecyclePaneController()
        let second = LifecyclePaneController()
        var outcomes: [Bool] = []
        CockpitPaneControllerCache.validate([first, second]) { outcomes.append($0) }
        XCTAssertEqual(first.validationCount, 1)
        XCTAssertEqual(second.validationCount, 0)
        XCTAssertTrue(outcomes.isEmpty)
        await Task.yield()
        first.resolveClose(false)
        XCTAssertEqual(outcomes, [false])
        XCTAssertEqual(second.validationCount, 0)
        XCTAssertEqual(first.closeCount, 0)
        XCTAssertEqual(second.closeCount, 0)
    }

    @MainActor
    func testAggregateCloseRejectsNewEditsToAnEarlierValidatedPane() {
        let first = LifecyclePaneController()
        let second = LifecyclePaneController()
        var outcomes: [Bool] = []
        var rejected: NSViewController?
        CockpitPaneControllerCache.validate([first, second], onFailure: { rejected = $0 }) { outcomes.append($0) }
        first.resolveClose(true)
        XCTAssertEqual(second.validationCount, 1)
        first.isReadyToClose = false
        second.resolveClose(true)
        XCTAssertEqual(outcomes, [false])
        XCTAssertTrue(rejected === first)
        XCTAssertEqual(first.closeCount, 0)
        XCTAssertEqual(second.closeCount, 0)
    }

    @MainActor
    func testFinalReadinessRevealsEditsMadeAfterAsyncPreflight() {
        let cache = CockpitPaneControllerCache()
        let pane = Pane(kind: .editor, sortOrder: 0)
        let controller = LifecyclePaneController()
        _ = cache.controller(for: pane, rootPath: nil) { _, _ in controller }
        defer { cache.closeAll() }
        var rejectedID: UUID?
        cache.onCloseValidationFailure = { rejectedID = $0 }
        XCTAssertTrue(cache.validateCloseReadiness())
        controller.isReadyToClose = false
        XCTAssertFalse(cache.validateCloseReadiness())
        XCTAssertEqual(rejectedID, pane.id)
        controller.isReadyToClose = true
        XCTAssertTrue(cache.validateCloseReadiness())
    }

    @MainActor
    func testDeferredPaneRemovalRechecksReadinessBeforeDeleting() async throws {
        let (container, workspace, pane) = try singlePaneFixture()
        let cache = CockpitPaneControllerCache()
        let controller = LifecyclePaneController()
        _ = cache.controller(for: pane, rootPath: nil) { _, _ in controller }
        defer { cache.closeAll() }
        var rejectedID: UUID?
        cache.onCloseValidationFailure = { rejectedID = $0 }
        XCTAssertTrue(cache.validateCloseReadiness(ids: [pane.id]))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            workspace.requestRemovePane(pane, allowEmpty: true) {
                defer { continuation.resume() }
                return cache.validateCloseReadiness(ids: [pane.id])
            }
            controller.isReadyToClose = false
        }
        XCTAssertEqual(workspace.panes.map(\.id), [pane.id])
        XCTAssertEqual(rejectedID, pane.id)
        XCTAssertEqual(controller.closeCount, 0)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    @MainActor
    func testDeferredWorkspaceDeletionRechecksReadinessBeforeDeleting() async throws {
        let (container, workspace, pane) = try singlePaneFixture()
        let defaultsName = "app.blau.pilot.deferred-close-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = WorkspaceStore(modelContext: container.mainContext,
                                   workspaceGroups: WorkspaceGroups(defaults: defaults), defaults: defaults)
        let cache = CockpitPaneControllerCache()
        let controller = LifecyclePaneController()
        _ = cache.controller(for: pane, rootPath: nil) { _, _ in controller }
        defer { cache.closeAll() }
        var rejectedID: UUID?
        cache.onCloseValidationFailure = { rejectedID = $0 }
        XCTAssertTrue(cache.validateCloseReadiness(ids: [pane.id]))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.requestDeleteWorkspace(workspace) {
                defer { continuation.resume() }
                return cache.validateCloseReadiness(ids: [pane.id])
            }
            controller.isReadyToClose = false
        }
        XCTAssertTrue(store.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(workspace.panes.map(\.id), [pane.id])
        XCTAssertEqual(rejectedID, pane.id)
        XCTAssertEqual(controller.closeCount, 0)
    }

    @MainActor
    func testTargetedValidationWaitsForConsentAndDoesNotEvict() async {
        let cache = CockpitPaneControllerCache()
        let first = Pane(kind: .editor, sortOrder: 0)
        let second = Pane(kind: .editor, sortOrder: 1)
        let selected = LifecyclePaneController()
        let unrelated = LifecyclePaneController()
        _ = cache.controller(for: first, rootPath: nil) { _, _ in selected }
        _ = cache.controller(for: second, rootPath: nil) { _, _ in unrelated }
        var outcomes: [Bool] = []
        cache.prepareToClose(ids: [first.id]) { outcomes.append($0) }
        XCTAssertEqual(selected.validationCount, 1)
        XCTAssertEqual(unrelated.validationCount, 0)
        XCTAssertTrue(outcomes.isEmpty)
        await Task.yield()
        selected.resolveClose(true)
        XCTAssertEqual(outcomes, [true])
        XCTAssertEqual(cache.allControllers.count, 2)
        XCTAssertEqual(selected.closeCount, 0)
        cache.closeAll()
    }

    @MainActor
    private func singlePaneFixture() throws -> (ModelContainer, Workspace, Pane) {
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self, EditorState.self,
                             Note.self, RemoteDesktopConnection.self, ExtensionWorkspaceLink.self])
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let workspace = Workspace(name: "Final pane fixture")
        let pane = Pane(kind: .editor, sortOrder: 0)
        workspace.panes = [pane]
        pane.workspace = workspace
        workspace.selectedPaneID = pane.id
        // A remembered focus ID must be cleared even if its kind changed;
        // using an editor keeps this persistence test free of terminal engines.
        workspace.frontmostTerminalPaneID = pane.id
        container.mainContext.insert(workspace)
        try container.mainContext.save()
        return (container, workspace, pane)
    }
}

@MainActor
private final class LifecyclePaneController: NSViewController,
    CockpitPanePresenting, CockpitPaneClosing, CockpitPaneContextUpdating, CockpitPaneCloseValidating {
    struct Presentation: Equatable {
        let active: Bool
        let selected: Bool
    }

    var roots: [String?] = []
    var presentations: [Presentation] = []
    var closeCount = 0
    var validationCount = 0
    var isReadyToClose = true
    private var pendingClose: (@MainActor (Bool) -> Void)?

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = NSView() }
    func updateContext(rootPath: String?) { roots.append(rootPath) }
    func updatePresentation(isActive: Bool, isSelected: Bool) {
        presentations.append(.init(active: isActive, selected: isSelected))
    }
    func closePane() { closeCount += 1 }
    func prepareToClose(_ completion: @escaping @MainActor (Bool) -> Void) {
        validationCount += 1
        pendingClose = completion
    }
    func resolveClose(_ allowed: Bool) {
        let completion = pendingClose
        pendingClose = nil
        completion?(allowed)
    }
}
