import AppKit
import SwiftData
import XCTest
@testable import Pilot

final class NativePaneLifecycleTests: XCTestCase {
    private enum SaveFailure: Error { case rejected }

    @MainActor
    func testRetiredWorkspaceCanFinishLayoutAfterItsModelIsDeleted() throws {
        let (container, workspace, _) = try singlePaneFixture()
        let cache = CockpitPaneControllerCache()
        let presentation = CockpitWorkspaceViewController(
            workspace: workspace, projectID: workspace.id, surface: .main, cache: cache,
            factory: { _, _ in LifecyclePaneController() }, onDrop: { _, _ in false })
        presentation.refresh(isActive: true)
        let root = presentation.view
        presentation.deactivate()
        cache.closeAll()
        container.mainContext.delete(workspace)
        try container.mainContext.save()
        // An in-flight native split animation can retain this detached view.
        // Its final layout must use the last geometry, not deleted SwiftData.
        for width in [900.0, 700.0, 1000.0] {
            root.frame.size = NSSize(width: width, height: 700)
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.bounds.width, width)
        }
    }

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
    func testHiddenTerminalStripListsFastCommandControlsVertically() throws {
        let terminal = Pane(kind: .terminal, sortOrder: 0)
        let editor = Pane(kind: .editor, sortOrder: 1)
        let workspace = Workspace(name: "Strip")
        workspace.panes = [terminal, editor]
        terminal.workspace = workspace
        editor.workspace = workspace
        workspace.selectedPaneID = editor.id
        let cache = CockpitPaneControllerCache()
        defer { cache.closeAll() }
        let presentation = CockpitWorkspaceViewController(
            workspace: workspace, projectID: workspace.id, surface: .main, cache: cache,
            factory: { _, _ in LifecyclePaneController() }, onDrop: { _, _ in false })
        workspace.collapsePane(terminal)
        presentation.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        presentation.refresh(isActive: true)
        presentation.view.layoutSubtreeIfNeeded()

        func control(_ id: String) throws -> NSView {
            var stack: [NSView] = [presentation.view]
            while let view = stack.popLast() {
                if view.accessibilityIdentifier() == id, !view.isHiddenOrHasHiddenAncestor { return view }
                stack.append(contentsOf: view.subviews)
            }
            return try XCTUnwrap(NSView?.none, "\(id) not found in the hidden strip")
        }
        let play = try control("terminal.fast-command.play")
        let stop = try control("terminal.fast-command.stop")
        let playFrame = play.convert(play.bounds, to: presentation.view)
        let stopFrame = stop.convert(stop.bounds, to: presentation.view)
        XCTAssertEqual(playFrame.midX, stopFrame.midX, accuracy: 1, "Controls share one column")
        XCTAssertGreaterThan(abs(playFrame.midY - stopFrame.midY), 20, "Play and Stop are stacked vertically")
        XCTAssertLessThan(playFrame.maxX, 80, "Controls live in the hidden pane's narrow strip")
    }

    @MainActor
    func testClosingTheLastPaneLeavesTheNewTabPage() async throws {
        let (container, workspace, pane) = try singlePaneFixture()
        defer { withExtendedLifetime(container) {} }
        XCTAssertTrue(workspace.canClosePane(pane))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            workspace.requestClosePane(pane) {
                defer { continuation.resume() }
                return true
            }
        }
        // The removal runs right after the readiness check on the main actor.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while workspace.panes.contains(where: { $0 === pane }), ContinuousClock.now < deadline { await Task.yield() }
        let opening = try XCTUnwrap(workspace.panes.first)
        defer { opening.isChoosingMode = false }
        XCTAssertEqual(workspace.panes.count, 1)
        XCTAssertNotEqual(opening.id, pane.id)
        XCTAssertTrue(opening.isChoosingMode)
        XCTAssertEqual(workspace.selectedPaneID, opening.id)
        XCTAssertFalse(workspace.canClosePane(opening), "Closing the last New Tab would only bring it back")
    }

    @MainActor
    func testEmptyWorkspaceShowsNewTab() throws {
        let (container, workspace, pane) = try singlePaneFixture()
        defer { withExtendedLifetime(container) {} }
        XCTAssertNil(workspace.ensureNewTabWhenEmpty(), "A workspace with panes is left alone")
        XCTAssertTrue(workspace.removePane(pane, allowEmpty: true))
        let opening = try XCTUnwrap(workspace.ensureNewTabWhenEmpty())
        defer { opening.isChoosingMode = false }
        XCTAssertTrue(opening.isChoosingMode)
        XCTAssertEqual(workspace.panes.map(\.id), [opening.id])
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
    func testFailedPaneRemovalKeepsEarlierUnsavedEdit() throws {
        // #437: an edit whose save already failed stays pending for retry. A
        // later failed removal must not roll it back along with itself.
        let (container, workspace, pane) = try singlePaneFixture()
        workspace.name = "Renamed while disk full"
        XCTAssertTrue(container.mainContext.hasChanges)

        XCTAssertFalse(workspace.removePane(pane, allowEmpty: true, performSave: { _ in
            throw SaveFailure.rejected
        }))
        XCTAssertEqual(workspace.name, "Renamed while disk full")
        XCTAssertTrue(container.mainContext.hasChanges, "The unsaved edit stays available for Retry")
        XCTAssertEqual(workspace.panes.map(\.id), [pane.id])
        XCTAssertEqual(workspace.selectedPaneID, pane.id)
    }

    @MainActor
    func testFailedPaneRemovalRollsBackOnlyItsOwnChanges() throws {
        // #437: when earlier work can be saved first, the failing removal's
        // rollback discards only the removal.
        let (container, workspace, pane) = try singlePaneFixture()
        workspace.name = "Renamed before close"
        var saveAttempts = 0
        XCTAssertFalse(workspace.removePane(pane, allowEmpty: true, performSave: { context in
            saveAttempts += 1
            guard saveAttempts == 1 else { throw SaveFailure.rejected }
            try context.save()
        }))
        XCTAssertEqual(saveAttempts, 2)
        XCTAssertEqual(workspace.name, "Renamed before close")
        XCTAssertEqual(workspace.panes.map(\.id), [pane.id])
        XCTAssertEqual(workspace.selectedPaneID, pane.id)
        XCTAssertFalse(container.mainContext.hasChanges)
        let persisted = try ModelContext(container).fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(persisted.first { $0.id == workspace.id }?.name, "Renamed before close")
    }

    @MainActor
    func testClosingLastPaneWithBlockedEarlierEditCreatesNoPlaceholder() throws {
        // #437: while an earlier edit can't be saved the removal is refused,
        // so the New Tab placeholder must not be created and stranded.
        let (container, workspace, pane) = try singlePaneFixture()
        workspace.name = "Renamed while disk full"
        XCTAssertFalse(workspace.replaceLastPaneWithNewTab(pane, performSave: { _ in
            throw SaveFailure.rejected
        }))
        XCTAssertEqual(workspace.panes.map(\.id), [pane.id])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Pane>()).map(\.id), [pane.id])
        XCTAssertEqual(workspace.selectedPaneID, pane.id)
        XCTAssertEqual(workspace.frontmostTerminalPaneID, pane.id)
        XCTAssertEqual(workspace.name, "Renamed while disk full")
        XCTAssertTrue(container.mainContext.hasChanges, "The unsaved edit stays available for Retry")
    }

    @MainActor
    func testClosingLastPaneWhileSavesFailKeepsOnlyTheOriginal() throws {
        // #437: the placeholder's own insert fails to save and stays pending,
        // so removePane refuses; the placeholder must still be dropped.
        let (container, workspace, pane) = try singlePaneFixture()
        XCTAssertFalse(workspace.replaceLastPaneWithNewTab(pane, performSave: { _ in
            throw SaveFailure.rejected
        }))
        XCTAssertEqual(workspace.panes.map(\.id), [pane.id])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Pane>()).map(\.id), [pane.id])
        XCTAssertEqual(workspace.selectedPaneID, pane.id)
        XCTAssertEqual(workspace.frontmostTerminalPaneID, pane.id)
        XCTAssertTrue(pane.workspace === workspace)
    }

    @MainActor
    func testClosingLastPaneWhoseRemovalFailsDropsTheSavedPlaceholder() throws {
        // The placeholder saves, the removal itself fails and rolls back; the
        // saved placeholder is then deleted so only the original remains.
        let (container, workspace, pane) = try singlePaneFixture()
        var saveAttempts = 0
        XCTAssertFalse(workspace.replaceLastPaneWithNewTab(pane, performSave: { context in
            saveAttempts += 1
            if saveAttempts == 2 { throw SaveFailure.rejected }
            try context.save()
        }))
        XCTAssertEqual(workspace.panes.map(\.id), [pane.id])
        XCTAssertEqual(workspace.selectedPaneID, pane.id)
        XCTAssertEqual(workspace.frontmostTerminalPaneID, pane.id)
        let persisted = try ModelContext(container).fetch(FetchDescriptor<Pane>())
        XCTAssertEqual(persisted.map(\.id), [pane.id])
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
    func testModeSwitchRetainsBothControllersAndClosesEveryModeOnEviction() throws {
        let cache = CockpitPaneControllerCache()
        let pane = Pane(kind: .terminal)
        let workspace = Workspace(name: "Modes")
        workspace.panes = [pane]
        pane.workspace = workspace
        workspace.selectedPaneID = pane.id
        var controllers: [PaneKind: LifecyclePaneController] = [:]
        let presentation = CockpitWorkspaceViewController(
            workspace: workspace, projectID: workspace.id, surface: .main, cache: cache,
            factory: { pane, _ in
                let controller = LifecyclePaneController()
                controllers[pane.kind] = controller
                return controller
            }, onDrop: { _, _ in false })
        presentation.refresh(isActive: true)
        let raw = try XCTUnwrap(controllers[.terminal])
        pane.kind = .agentChat
        presentation.refresh(isActive: true)
        let agent = try XCTUnwrap(controllers[.agentChat])
        XCTAssertNil(raw.parent)
        XCTAssertEqual(raw.presentations.last, .init(active: false, selected: false))
        XCTAssertTrue(agent.parent === presentation)
        pane.kind = .terminal
        presentation.refresh(isActive: true)
        XCTAssertTrue(cache.existingController(for: pane.id) === raw)
        XCTAssertTrue(raw.parent === presentation)
        XCTAssertNil(agent.parent)
        XCTAssertEqual(raw.closeCount, 0)
        XCTAssertEqual(agent.closeCount, 0)
        XCTAssertEqual(workspace.panes.count, 1)
        XCTAssertEqual(cache.allControllers.count, 2)
        cache.closeAll()
        XCTAssertEqual(raw.closeCount, 1)
        XCTAssertEqual(agent.closeCount, 1)
    }

    @MainActor
    func testOpeningChoiceStartsOnlyTheSelectedModeAndReclaimsItsSpace() throws {
        // Each case types a key path through the placeholder.
        let cases: [(start: PaneKind, keys: [String], expected: PaneKind)] = [
            (.terminal, ["t", "a"], .agentChat),
            (.terminal, ["t", "r"], .terminal),
            (.terminal, ["b", "s", "0"], .browser),
            (.simulator, ["\u{1b}", "t", "r"], .terminal),
        ]
        for (start, keys, expected) in cases {
            let cache = CockpitPaneControllerCache()
            defer { cache.closeAll() }
            let workspace = Workspace(name: "Opening choice")
            workspace.rootPath = "/tmp"
            let pane = Pane(kind: start)
            pane.isChoosingMode = true
            if start == .simulator { pane.openingPath = [.root, .simulator] }
            pane.workspace = workspace
            workspace.panes = [pane]
            workspace.selectedPaneID = pane.id
            var created: [PaneKind] = []
            let child = LifecyclePaneController()
            let presentation = CockpitWorkspaceViewController(
                workspace: workspace, projectID: workspace.id, surface: .main, cache: cache,
                factory: { pane, _ in created.append(pane.kind); return child }, onDrop: { _, _ in false })
            presentation.refresh(isActive: true)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let placeholder = try XCTUnwrap(descendants(presentation.view).compactMap { $0 as? CockpitNewTabView }.first)
            XCTAssertTrue(created.isEmpty, "No session should start before the opening choice")
            for key in keys {
                if key == "\u{1b}" { XCTAssertTrue(placeholder.pop()) } else { XCTAssertTrue(placeholder.press(key), "\(keys)") }
            }
            XCTAssertEqual(created, [expected])
            XCTAssertFalse(pane.isChoosingMode)
            XCTAssertNil(placeholder.superview)
            XCTAssertFalse(descendants(presentation.view).contains { $0 is CockpitNewTabView })
            let host = try XCTUnwrap(child.view.superview)
            XCTAssertEqual(host.bounds.height,
                           presentation.view.bounds.height - CockpitPaneTab.preferredHeight - LiquidGlassMetrics.Spacing.xSmall,
                           accuracy: 1, "Only the pane header and its top inset should consume vertical space")
            XCTAssertFalse(placeholder.press("t"))
            presentation.deactivate()
            presentation.refresh(isActive: true)
            XCTAssertEqual(created, [expected])
            XCTAssertEqual(pane.kind, expected)
            if expected == .browser { XCTAssertEqual(pane.browserState?.engine, .webKit) }
            if expected.isTerminalTool { XCTAssertEqual(pane.currentDirectory, workspace.effectiveRootPath) }
        }
    }

    @MainActor
    func testCollapsedPaneRevealStaysAtTheTopInBothOrientations() throws {
        let cache = CockpitPaneControllerCache()
        defer { cache.closeAll() }
        let workspace = Workspace(name: "Reveal")
        let pane = Pane(kind: .editor)
        pane.workspace = workspace
        workspace.panes = [pane]
        workspace.selectedPaneID = pane.id
        let child = LifecyclePaneController()
        let presentation = CockpitWorkspaceViewController(
            workspace: workspace, projectID: workspace.id, surface: .main, cache: cache,
            factory: { _, _ in child }, onDrop: { _, _ in false })
        presentation.refresh(isActive: true)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for horizontal in [false, true] {
            workspace.axis = horizontal ? .horizontal : .vertical
            pane.isCollapsed = true
            presentation.refresh(isActive: true)
            presentation.view.layoutSubtreeIfNeeded()
            let reveal = try XCTUnwrap(descendants(presentation.view).compactMap { $0 as? NSButton }.first {
                $0.toolTip?.hasPrefix("Show ") == true && !$0.isHiddenOrHasHiddenAncestor
            })
            let host = try XCTUnwrap(reveal.superview)
            XCTAssertTrue(host.isFlipped)
            XCTAssertEqual(reveal.frame.minX, 8, accuracy: 0.1)
            XCTAssertEqual(reveal.frame.minY, 8, accuracy: 0.1)
            XCTAssertTrue(host.bounds.contains(reveal.frame))
            XCTAssertEqual(reveal.frame.height, CockpitPaneTab.preferredHeight, accuracy: 0.1)
            XCTAssertEqual(reveal.imagePosition, .imageOnly)
            reveal.performClick(nil)
            presentation.view.layoutSubtreeIfNeeded()
            XCTAssertFalse(pane.isCollapsed)
            XCTAssertTrue(child.parent === presentation)
            XCTAssertEqual(child.closeCount, 0)
            let header = try XCTUnwrap(descendants(presentation.view).compactMap { $0 as? CockpitPaneTab }.first)
            XCTAssertEqual(header.frame.minY, reveal.frame.minY, accuracy: 0.1)
        }
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
