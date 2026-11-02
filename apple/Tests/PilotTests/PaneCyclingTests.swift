import Foundation
import Testing
@testable import Pilot

@Suite("Pane cycling (⌘← / ⌘→)")
struct PaneCyclingTests {

    @Test
    func nextWrapsAround() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        let c = Pane(kind: .terminal, sortOrder: 2)
        attach(workspace: workspace, panes: [a, b, c], selectedPaneID: a.id)

        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == b.id)
        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == c.id)
        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == a.id) // wrapped
    }

    @Test
    func previousWrapsAround() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        attach(workspace: workspace, panes: [a, b], selectedPaneID: a.id)

        workspace.selectPreviousPane()
        #expect(workspace.selectedPaneID == b.id) // wrapped backward
    }

    @Test
    func collapsedPanesAreSkipped() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        let c = Pane(kind: .terminal, sortOrder: 2)
        b.isCollapsed = true
        attach(workspace: workspace, panes: [a, b, c], selectedPaneID: a.id)

        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == c.id) // skipped collapsed `b`
    }

    @Test
    func singleVisiblePaneIsNoOp() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        b.isCollapsed = true
        attach(workspace: workspace, panes: [a, b], selectedPaneID: a.id)

        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == a.id)
        workspace.selectPreviousPane()
        #expect(workspace.selectedPaneID == a.id)
    }

    @Test
    func focusModeCyclesFullScreenedPane() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        let c = Pane(kind: .terminal, sortOrder: 2)
        attach(workspace: workspace, panes: [a, b, c], selectedPaneID: a.id)
        workspace.focusPane(a)
        #expect(workspace.focusedPaneID == a.id)
        #expect(b.isCollapsed && c.isCollapsed)

        workspace.selectNextPane()
        #expect(workspace.focusedPaneID == b.id)
        #expect(workspace.selectedPaneID == b.id)
        #expect(!b.isCollapsed)
        #expect(a.isCollapsed && c.isCollapsed)

        workspace.selectNextPane()
        #expect(workspace.focusedPaneID == c.id)

        workspace.selectNextPane()
        #expect(workspace.focusedPaneID == a.id) // wrapped
    }

    @Test
    func focusModePreviousWraps() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        attach(workspace: workspace, panes: [a, b], selectedPaneID: a.id)
        workspace.focusPane(a)

        workspace.selectPreviousPane()
        #expect(workspace.focusedPaneID == b.id) // wrapped backward
    }

    @Test
    func cyclingOntoTerminalUpdatesFrontmostTerminalID() {
        let workspace = Workspace(name: "Test")
        let browser = Pane(kind: .browser, sortOrder: 0)
        let terminal = Pane(kind: .terminal, sortOrder: 1)
        attach(workspace: workspace, panes: [browser, terminal], selectedPaneID: browser.id)
        workspace.frontmostTerminalPaneID = nil

        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == terminal.id)
        #expect(workspace.frontmostTerminalPaneID == terminal.id)
    }

    private func attach(workspace: Workspace, panes: [Pane], selectedPaneID: UUID) {
        workspace.panes = panes
        for pane in panes { pane.workspace = workspace }
        workspace.selectedPaneID = selectedPaneID
    }
}

/// Divider drags and narrow windows used to squeeze a pane to 37–65pt, where
/// its header clipped and picker titles broke a letter per line. These pin the
/// point floor and its fallback when the window can't hold every pane at it.
@Suite("Pane resize floor")
struct PaneResizeFloorTests {
    private let tolerance = 1e-9

    @Test("A drag stops at the point floor when every pane fits at it")
    func dragStopsAtPointFloor() {
        let (workspace, a, b, c) = makeWorkspace(fractions: [0.5, 0.25, 0.25])
        // 1000pt shared by three panes: the floor is 160pt, i.e. 0.16.
        workspace.resizePanes(leadingID: a.id, trailingID: b.id, delta: 0.5, expandedSize: 1000)

        #expect(abs(b.sizeFraction - 0.16) < tolerance)
        #expect(abs(a.sizeFraction - 0.59) < tolerance)
        #expect(abs(c.sizeFraction - 0.25) < tolerance)
        #expect(abs(a.sizeFraction + b.sizeFraction + c.sizeFraction - 1) < tolerance)
    }

    @Test("A window too narrow for the point floor keeps the relative floor")
    func narrowWindowKeepsRelativeFloor() {
        let (workspace, a, b, _) = makeWorkspace(fractions: [0.5, 0.25, 0.25])
        // 300pt can't hold three 160pt panes, so the old 0.1 floor applies.
        workspace.resizePanes(leadingID: a.id, trailingID: b.id, delta: 0.5, expandedSize: 300)

        #expect(abs(b.sizeFraction - 0.1) < tolerance)
        #expect(abs(a.sizeFraction - 0.65) < tolerance)
    }

    @Test("Without a size the resize keeps the legacy relative floor")
    func missingSizeKeepsRelativeFloor() {
        let (workspace, a, b, _) = makeWorkspace(fractions: [0.5, 0.25, 0.25])
        workspace.resizePanes(leadingID: a.id, trailingID: b.id, delta: -0.9)

        #expect(abs(a.sizeFraction - 0.1) < tolerance)
        #expect(abs(b.sizeFraction - 0.65) < tolerance)
    }

    @Test("Dragging one divider leaves unrelated panes' share alone")
    func unrelatedPanesKeepTheirShare() {
        // Raw weights that don't sum to 1 (e.g. after a sibling collapsed).
        let (workspace, a, b, c) = makeWorkspace(fractions: [0.2, 0.2, 0.2])
        workspace.resizePanes(leadingID: a.id, trailingID: b.id, delta: 0.05, expandedSize: 1200)

        let total = a.sizeFraction + b.sizeFraction + c.sizeFraction
        #expect(abs(total - 1) < tolerance)
        #expect(abs(c.sizeFraction / total - 1.0 / 3.0) < tolerance)
    }

    @Test("A pane already under the floor can grow but is never snapped or shrunk")
    func undersizedPaneOnlyGrows() {
        let squeezed = PaneSizing.resizedPair(leading: 0.05, trailing: 0.5, delta: -0.02, minimumFraction: 0.16)
        #expect(abs(squeezed.leading - 0.05) < tolerance)
        #expect(abs(squeezed.trailing - 0.5) < tolerance)

        let grown = PaneSizing.resizedPair(leading: 0.05, trailing: 0.5, delta: 0.01, minimumFraction: 0.16)
        #expect(abs(grown.leading - 0.06) < tolerance)
        #expect(abs(grown.trailing - 0.49) < tolerance)
    }

    @Test("Resized pairs never go negative or overflow their total")
    func resizedPairStaysInBounds() {
        for delta in [-5.0, -0.3, 0, 0.3, 5.0] {
            for minimum in [0.0, 0.1, 0.4, 0.9] {
                let pair = PaneSizing.resizedPair(leading: 0.2, trailing: 0.1, delta: delta, minimumFraction: minimum)
                #expect(pair.leading >= 0 && pair.trailing >= 0)
                #expect(abs(pair.leading + pair.trailing - 0.3) < tolerance)
            }
        }
    }

    @Test("Layout lifts a squeezed pane to the floor and keeps the total")
    func layoutLiftsSqueezedPane() {
        let ids = (0..<3).map { _ in UUID() }
        let fractions = Dictionary(uniqueKeysWithValues: zip(ids, [0.05, 0.15, 0.8]))
        let floored = PaneSizing.flooredFractions(fractions, expandedSize: 1000)

        #expect(abs((floored[ids[0]] ?? 0) - 0.16) < tolerance)
        #expect(abs((floored[ids[1]] ?? 0) - 0.16) < tolerance)
        #expect(abs((floored[ids[2]] ?? 0) - 0.68) < tolerance)
        #expect(abs(floored.values.reduce(0, +) - 1) < tolerance)
    }

    @Test("Layout falls back to relative sizes when the floor can't fit")
    func layoutFallsBackWhenFloorDoesNotFit() {
        let ids = (0..<3).map { _ in UUID() }
        let fractions = Dictionary(uniqueKeysWithValues: zip(ids, [0.05, 0.15, 0.8]))
        #expect(PaneSizing.flooredFractions(fractions, expandedSize: 400) == fractions)
        #expect(PaneSizing.flooredFractions(fractions, expandedSize: 0) == fractions)
        #expect(PaneSizing.minimumFraction(expandedSize: 400, expandedCount: 3) == 0.1)
        #expect(abs(PaneSizing.minimumFraction(expandedSize: 480, expandedCount: 3) - 1.0 / 3.0) < tolerance)
    }

    private func makeWorkspace(fractions: [Double]) -> (Workspace, Pane, Pane, Pane) {
        let workspace = Workspace(name: "Test")
        let panes = fractions.enumerated().map { index, fraction in
            let pane = Pane(kind: .terminal, sortOrder: index)
            pane.sizeFraction = fraction
            return pane
        }
        workspace.panes = panes
        for pane in panes { pane.workspace = workspace }
        workspace.selectedPaneID = panes[0].id
        return (workspace, panes[0], panes[1], panes[2])
    }
}
