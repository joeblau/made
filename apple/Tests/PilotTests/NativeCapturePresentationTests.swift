import AppKit
import Observation
import PaperKit
import PencilKit
import XCTest
@testable import Pilot

@MainActor
final class NativeCapturePresentationTests: XCTestCase {
    func testAndroidDeviceChoiceUpdatesAnExistingSimulatorSession() {
        let pane = Pane(kind: .android)
        pane.isChoosingMode = true
        let registry = AndroidDeviceRegistry.shared
        registry.configure(target: .simulator, for: pane.id)
        let session = registry.session(for: pane.id)
        session.suspend()
        session.bootableAVDs = ["Medium_Phone_API_35"]
        defer { registry.remove(paneID: pane.id); pane.isChoosingMode = false }
        XCTAssertTrue(pane.applyOpeningChoice(.pane(.android, .device)))
        XCTAssertEqual(pane.androidTarget, .device)
        XCTAssertEqual(session.target, .device)
        XCTAssertTrue(session.bootableAVDs.isEmpty)
        XCTAssertFalse(pane.isChoosingMode)
    }

    func testInactivePresentationStopsObservingAndReattachmentPreservesNativeSurface() async throws {
        let model = CapturePresentationFixture()
        let controller = CapturePresentationFixtureController(model: model)
        controller.updatePresentation(isActive: true, isSelected: false)
        let firstSurface = try XCTUnwrap(controller.surface)
        XCTAssertEqual(controller.createdSurfaces, 1)

        model.revision = 1
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.displayedRevision, 1)

        controller.updatePresentation(isActive: false, isSelected: false)
        model.revision = 2
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.displayedRevision, 1)

        controller.updatePresentation(isActive: true, isSelected: true)
        XCTAssertEqual(controller.displayedRevision, 2)
        XCTAssertEqual(controller.createdSurfaces, 1)
        XCTAssertTrue(controller.surface === firstSurface)
        XCTAssertEqual(controller.activations, [true, false, true])
        controller.updatePresentation(isActive: false, isSelected: false)
    }

    func testToolbarFollowsObservedStateWithoutReplacingTheStreamView() async throws {
        let model = CapturePresentationFixture()
        let controller = CapturePresentationFixtureController(model: model)
        let toolbar = try XCTUnwrap(controller.makeCaptureToolbarView() as? NSStackView)
        controller.updatePresentation(isActive: true, isSelected: true)
        let recordButton = try XCTUnwrap(toolbar.arrangedSubviews.first as? NSButton)
        XCTAssertTrue(recordButton.isEnabled)

        model.canRecord = false
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(try XCTUnwrap(toolbar.arrangedSubviews.first as? NSButton).isEnabled)
        XCTAssertTrue(toolbar.arrangedSubviews.first === recordButton)
        XCTAssertEqual(controller.createdSurfaces, 1)
        controller.updatePresentation(isActive: false, isSelected: false)
    }

    func testRepeatedPresentationUpdatesPreserveTheCurrentResponderUntilSelectionChanges() throws {
        let controller = CapturePresentationFixtureController(model: CapturePresentationFixture())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer {
            controller.updatePresentation(isActive: false, isSelected: false)
            window.close()
        }
        controller.updatePresentation(isActive: true, isSelected: true)
        let surface = try XCTUnwrap(controller.surface)
        XCTAssertTrue(window.firstResponder === surface)

        let toolbarEditor = CaptureResponderFixture()
        controller.view.addSubview(toolbarEditor)
        XCTAssertTrue(window.makeFirstResponder(toolbarEditor))
        controller.updatePresentation(isActive: true, isSelected: true)
        XCTAssertTrue(window.firstResponder === toolbarEditor)

        controller.updatePresentation(isActive: true, isSelected: false)
        controller.updatePresentation(isActive: true, isSelected: true)
        XCTAssertTrue(window.firstResponder === surface)
    }

    func testRemoteCanvasPassesPointerEventsThroughToThePane() {
        let canvas = RemoteInkCanvasNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertNil(canvas.hitTest(NSPoint(x: 20, y: 20)))
    }

    func testPickerPollingPreservesRowsSelectionScrollAndFirstResponder() throws {
        let controller = CapturePickerFixtureController()
        controller.items = (0..<60).map { CapturePickerItem(id: "device-\($0)", title: "Device \($0)") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer {
            controller.updatePresentation(isActive: false, isSelected: false)
            window.close()
        }
        controller.updatePresentation(isActive: true, isSelected: false)
        controller.view.layoutSubtreeIfNeeded()
        let picker = try XCTUnwrap(descendant(CaptureDevicePicker.self, in: controller.view))
        let table = try XCTUnwrap(descendant(NSTableView.self, in: picker))
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        table.selectRowIndexes(IndexSet(integer: 30), byExtendingSelection: false)
        table.scrollRowToVisible(30)
        let row = try XCTUnwrap(table.view(atColumn: 0, row: 30, makeIfNecessary: true))
        let origin = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(origin.y, 0)
        XCTAssertTrue(window.makeFirstResponder(table))
        let refreshSlot = try XCTUnwrap(descendant(CockpitRefreshButton.self, in: picker))
        let slotFrame = refreshSlot.frame

        for refreshing in [true, false, true, false] {
            controller.refreshing = refreshing
            controller.updatePresentation(isActive: true, isSelected: false)
            controller.view.layoutSubtreeIfNeeded()
            // The spinner replaces the refresh circle in the same fixed slot.
            XCTAssertEqual(refreshSlot.isRefreshing, refreshing)
            XCTAssertEqual(refreshSlot.button.isHidden, refreshing)
            XCTAssertEqual(refreshSlot.spinner.isHidden, !refreshing)
            XCTAssertEqual(refreshSlot.frame, slotFrame)
            XCTAssertTrue(descendant(CaptureDevicePicker.self, in: controller.view) === picker)
            XCTAssertTrue(descendant(NSTableView.self, in: picker) === table)
            XCTAssertTrue(table.view(atColumn: 0, row: 30, makeIfNecessary: true) === row)
            XCTAssertEqual(table.selectedRow, 30)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 0.5)
            XCTAssertTrue(window.firstResponder === table)
        }
    }

    func testPickerRefreshPreservesSelectionByDeviceIDAndKeyboardOnlyActivatesExplicitly() throws {
        let controller = CapturePickerFixtureController()
        var selected: [String] = []
        controller.items = (0..<4).map { index in
            CapturePickerItem(id: "device-\(index)", title: "Device \(index)", select: { selected.append("device-\(index)") })
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.updatePresentation(isActive: true, isSelected: false)
        controller.view.layoutSubtreeIfNeeded()
        defer {
            controller.updatePresentation(isActive: false, isSelected: false)
            window.close()
        }
        let table = try XCTUnwrap(descendant(NSTableView.self, in: controller.view))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.items.swapAt(0, 1)
        controller.items.removeLast()
        controller.items.append(CapturePickerItem(id: "new", title: "New Device"))
        controller.updatePresentation(isActive: true, isSelected: false)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertTrue(selected.isEmpty)
        XCTAssertTrue(window.makeFirstResponder(table))

        table.keyDown(with: try pickerKey(code: 125, characters: "\u{F701}"))
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertTrue(selected.isEmpty, "Arrow navigation must not connect or boot a device")
        table.keyDown(with: try pickerKey(code: 36, characters: "\r"))
        XCTAssertEqual(selected, ["device-0"])
        table.keyDown(with: try pickerKey(code: 49, characters: " "))
        XCTAssertEqual(selected, ["device-0", "device-0"])

        let row = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(selected, ["device-0", "device-0", "device-0"])
    }

    func testCompactCaptureMessageExposesItsDescriptionAndActionToAccessibility() throws {
        var retries = 0
        let message = CapturePaneMessage("Camera Access Required", symbol: "video.slash", detail: "Enable camera access in Settings.", actions: [
            CapturePaneAction(title: "Retry", symbol: "arrow.clockwise", perform: { retries += 1 }),
        ])
        message.setFrameSize(NSSize(width: 60, height: 200))
        message.layout()
        XCTAssertTrue(message.isAccessibilityElement())
        XCTAssertEqual(message.accessibilityRole(), .group)
        XCTAssertEqual(message.accessibilityLabel(), "Camera Access Required. Enable camera access in Settings.")
        let retry = try XCTUnwrap(buttons(in: message).first)
        let action = try accessibleControl(for: retry)
        XCTAssertEqual(action.accessibilityRole(), .button)
        XCTAssertEqual(action.accessibilityLabel(), "Retry")
        XCTAssertTrue(message.accessibilityChildren()?.contains { ($0 as AnyObject) === (action as AnyObject) } == true)
        _ = action.accessibilityPerformPress()
        XCTAssertEqual(retries, 1)
    }

    func testCompactWirelessInstructionsExposeTheirDescriptionAndActionToAccessibility() throws {
        let instructions = WirelessInstructionsView(session: WirelessDeviceSession(paneID: UUID()))
        instructions.setFrameSize(NSSize(width: 60, height: 200))
        instructions.layout()
        XCTAssertTrue(instructions.isAccessibilityElement())
        XCTAssertEqual(instructions.accessibilityRole(), .group)
        XCTAssertEqual(instructions.accessibilityLabel(), "Wireless Sharing Is Off")
        let start = try XCTUnwrap(buttons(in: instructions).first)
        let action = try accessibleControl(for: start)
        XCTAssertEqual(action.accessibilityRole(), .button)
        XCTAssertEqual(action.accessibilityLabel(), "Start Sharing")
        XCTAssertTrue(instructions.accessibilityChildren()?.contains { ($0 as AnyObject) === (action as AnyObject) } == true)
    }

    func testNativeToolPickerRoutesInkAndSelectionToPaperKitCanvas() throws {
        let controller = InkOverlayViewController(onDismiss: {})
        _ = controller.view
        let picker = controller.toolPicker
        XCTAssertTrue(picker.delegate === controller.markupController)
        picker.selectedDrawingTool = PKInkingTool(.marker, color: .systemBlue, width: 12)
        picker.delegate?.markupToolbarViewControllerSelectedDrawingToolChanged(picker)
        let tool = try XCTUnwrap(controller.markupController.drawingTool as? PKInkingTool)
        let selectedTool = try XCTUnwrap(picker.selectedDrawingTool as? PKInkingTool)
        XCTAssertEqual(tool.inkType, .marker)
        XCTAssertEqual(tool.color, selectedTool.color)
        XCTAssertEqual(tool.width, 12)
        picker.selectedIndirectPointerTouchMode = .selection
        picker.delegate?.markupToolbarViewControllerSelectedIndirectPointerTouchModeChanged(picker)
        XCTAssertEqual(controller.markupController.indirectPointerTouchMode, .selection)
        XCTAssertFalse(buttons(in: controller.view).contains { $0.toolTip == "Red ink" })
    }

    func testNativeMarkupUndoStaysInsideTheAnnotationWindow() async throws {
        let controller = InkOverlayViewController(onDismiss: {})
        let window = annotationWindow(controller)
        defer { window.orderOut(nil); window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        try await waitUntil("the canvas to get its markup") {
            controller.markupController.markup.map { !$0.bounds.isEmpty } ?? false
        }
        controller.toolPicker.delegate?.markupToolbarViewController(controller.toolPicker, insertNewShape: .rectangle)
        // No failure on timeout here: an inactive host never gets the shape,
        // and the check below skips in exactly that state.
        try await poll(for: .seconds(15)) {
            controller.markupController.markup.map { !$0.contentsRenderFrame.isEmpty } ?? false
        }
        // PaperKit inserts shapes only into the key window of an active app. Some
        // CI runners start the test host inactive; skip only in that state.
        if controller.markupController.markup?.contentsRenderFrame.isEmpty != false, !NSApp.isActive, !window.isKeyWindow {
            throw XCTSkip("PaperKit shape insertion is unavailable: the test host is inactive with no key window.")
        }
        XCTAssertFalse(try XCTUnwrap(controller.markupController.markup).contentsRenderFrame.isEmpty)
        XCTAssertTrue(controller.undoManager?.canUndo == true)
        let undo = try XCTUnwrap(buttons(in: controller.view).first { $0.toolTip == "Undo annotation" })
        XCTAssertTrue(undo.isEnabled)
        undo.performClick(nil)
        XCTAssertTrue(try XCTUnwrap(controller.markupController.markup).contentsRenderFrame.isEmpty)
    }

    func testNativeMarkupSurvivesResizeAndDismissClearsItOnce() async throws {
        var dismissed = 0
        let controller = InkOverlayViewController { dismissed += 1 }
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.systemTeal.cgColor
        let window = annotationWindow(controller)
        defer { window.orderOut(nil); window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        // Insert only once the canvas has its markup and bounds, not after a
        // guessed delay that a loaded CI runner can outlast.
        try await waitUntil("the canvas to get its markup") {
            controller.markupController.markup.map { !$0.bounds.isEmpty } ?? false
        }
        // Build the shape on the markup model. Toolbar insertion needs the key
        // window of an active app, which CI test hosts don't reliably get
        // (testNativeMarkupUndoStaysInsideTheAnnotationWindow covers it); this
        // test is about resize and dismissal, so it must not depend on focus.
        var markup = try XCTUnwrap(controller.markupController.markup)
        markup.insertNewShape(
            configuration: ShapeConfiguration(type: .ellipse, fillColor: nil,
                                              strokeColor: NSColor.systemRed.cgColor, lineWidth: 3),
            frame: CGRect(x: 120, y: 120, width: 240, height: 160)
        )
        controller.markupController.markup = markup
        let original = try XCTUnwrap(controller.markupController.markup).contentsRenderFrame
        XCTAssertFalse(original.isEmpty)
        window.setContentSize(NSSize(width: 720, height: 520))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.markupController.markup?.contentsRenderFrame, original)
        XCTAssertEqual(controller.markupController.markup?.bounds.size, controller.view.bounds.size)
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "native-annotation-picker.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        let done = try XCTUnwrap(buttons(in: controller.view).first { $0.title == "Done" })
        done.performClick(nil)
        controller.cancelOperation(nil)
        XCTAssertEqual(dismissed, 1)
        XCTAssertTrue(try XCTUnwrap(controller.markupController.markup).contentsRenderFrame.isEmpty)
        XCTAssertFalse(controller.undoManager?.canUndo == true)
    }

    private func annotationWindow(_ controller: InkOverlayViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Polls `condition` until it holds or `timeout` passes, without failing.
    private func poll(for timeout: Duration, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Polls `condition` on the main actor. Returns as soon as it holds; the
    /// generous deadline only matters on a loaded runner, and running out of
    /// it fails with what was awaited rather than a bare assertion later.
    private func waitUntil(_ what: String, timeout: Duration = .seconds(15),
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out after \(timeout) waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testRemoteUndoControlForwardsOneEditToTheAuthoritativePeer() {
        let model = RemoteInkModel()
        model.handle(.addStroke(AnnotationStroke(
            color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 0.01,
            points: [AnnotationPoint(x: 0.1, y: 0.2), AnnotationPoint(x: 0.7, y: 0.8)]
        )))
        var edits: [AnnotationMessage] = []
        model.onLocalEdit = { edits.append($0) }
        let controller = RemoteInkOverlayViewController(model: model)
        let undo = buttons(in: controller.view).first { $0.toolTip == "Undo last Kneeboard stroke" }
        XCTAssertNotNil(undo)
        undo?.performClick(nil)
        XCTAssertEqual(edits, [.undo])
        XCTAssertFalse(model.hasInk)
    }

    func testRemoteInkRejectsAddStrokesBeyondTheProtocolTotals() {
        let color = AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1)
        func stroke(points: Int) -> AnnotationStroke {
            AnnotationStroke(color: color, width: 0.01,
                             points: Array(repeating: AnnotationPoint(x: 0.5, y: 0.5), count: points))
        }

        // Each message is individually valid, but the running point total must
        // stop at the protocol ceiling instead of growing without bound.
        let model = RemoteInkModel()
        let perStroke = FrameProtocol.maxAnnotationPoints / 4
        for _ in 0..<4 { XCTAssertTrue(model.handle(.addStroke(stroke(points: perStroke)))) }
        let changeID = model.changeID
        XCTAssertFalse(model.handle(.addStroke(stroke(points: 2))))
        XCTAssertEqual(model.strokes.count, 4)
        XCTAssertEqual(model.pointCount, 4 * perStroke)
        XCTAssertEqual(model.changeID, changeID)

        // The rejection quarantines incremental ops (issue #431); a full
        // replacement restores agreement, and undo then frees capacity again.
        XCTAssertFalse(model.handle(.undo))
        XCTAssertEqual(model.pointCount, 4 * perStroke)
        XCTAssertTrue(model.handle(.replaceDrawing(AnnotationDrawing(
            strokes: Array(repeating: stroke(points: perStroke), count: 4)
        ))))
        XCTAssertTrue(model.handle(.undo))
        XCTAssertEqual(model.pointCount, 3 * perStroke)
        XCTAssertTrue(model.handle(.addStroke(stroke(points: 2))))

        // The stroke count is capped as well.
        let strokes = RemoteInkModel()
        XCTAssertTrue(strokes.handle(.replaceDrawing(AnnotationDrawing(
            strokes: Array(repeating: stroke(points: 2), count: FrameProtocol.maxAnnotationStrokes)
        ))))
        XCTAssertFalse(strokes.handle(.addStroke(stroke(points: 2))))
        XCTAssertEqual(strokes.strokes.count, FrameProtocol.maxAnnotationStrokes)
        XCTAssertTrue(strokes.handle(.clear))
        XCTAssertEqual(strokes.pointCount, 0)
        XCTAssertTrue(strokes.handle(.addStroke(stroke(points: 2))))
    }

    /// Issue #431: once Pilot rejects a stroke, the iPad's later `.undo` of
    /// that stroke must not remove a different one, and later strokes must
    /// not land at shifted indices.
    func testRemoteInkRefusesIncrementalOpsAfterARejectionUntilAResync() {
        let color = AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1)
        func stroke(points: Int, x: Double = 0.5) -> AnnotationStroke {
            AnnotationStroke(color: color, width: 0.01,
                             points: Array(repeating: AnnotationPoint(x: x, y: 0.5), count: points))
        }
        let big = stroke(points: FrameProtocol.maxAnnotationPoints - 10)
        let small = stroke(points: 5, x: 0.2)
        let rejected = stroke(points: 20, x: 0.8)

        let model = RemoteInkModel()
        XCTAssertTrue(model.handle(.addStroke(big)))
        XCTAssertTrue(model.handle(.addStroke(small)))
        XCTAssertFalse(model.handle(.addStroke(rejected)))
        XCTAssertTrue(model.isAwaitingResync)

        // The iPad undoes the stroke Pilot never applied: Pilot must keep
        // `small` rather than drop it in the rejected stroke's place.
        XCTAssertFalse(model.handle(.undo))
        XCTAssertEqual(model.strokes.count, 2)
        XCTAssertEqual(model.strokes.last?.points.first?.x, 0.2)
        XCTAssertFalse(model.handle(.addStroke(stroke(points: 2))))
        XCTAssertEqual(model.strokes.count, 2)

        // A full replacement is authoritative and resumes incremental ops.
        XCTAssertTrue(model.handle(.replaceDrawing(AnnotationDrawing(strokes: [small]))))
        XCTAssertFalse(model.isAwaitingResync)
        XCTAssertTrue(model.handle(.addStroke(rejected)))
        XCTAssertEqual(model.strokes.count, 2)
        XCTAssertTrue(model.handle(.undo))
        XCTAssertEqual(model.strokes.count, 1)

        // `.clear` also resumes incremental ops.
        XCTAssertFalse(model.handle(.addStroke(stroke(points: FrameProtocol.maxAnnotationPoints))))
        XCTAssertFalse(model.handle(.undo))
        XCTAssertTrue(model.handle(.clear))
        XCTAssertTrue(model.handle(.addStroke(small)))
    }

    /// Issue #431, end to end: Plotter's ``AnnotationMirrorSync`` drives the
    /// real ``RemoteInkModel`` through the wire format, so every message is
    /// `FrameProtocol`-encoded (a refused encode is an undelivered send, as in
    /// `FrameReceiver.sendAnnotation`) and Pilot applies what it decodes.
    /// Plotter enforces Pilot's ceilings before sending, so Pilot never
    /// rejects. A drawing within the ceilings but over `maxAnnotationBytes`
    /// as one replacement is rebuilt as a clear plus one stroke per message;
    /// only past the ceilings, or for a single stroke too large to encode,
    /// does Pilot show no ink while Plotter reports out of sync.
    func testPlotterMirrorNeverSendsInkPilotRejects() {
        let color = AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1)
        // The width Plotter's normalization produces for a 4 pt pen on an
        // iPad-sized content rect.
        let width = AnnotationStroke.normalizedWidth(penWidth: 4, contentWidth: 1_024, contentHeight: 700)
        func stroke(_ id: Int, points: Int) -> AnnotationStroke {
            AnnotationStroke(color: color, width: width,
                             points: Array(repeating: AnnotationPoint(x: Double(id) / 10_000, y: 0.5),
                                           count: points))
        }
        let pilot = RemoteInkModel()
        var plotter = AnnotationMirrorSync()
        var seq: UInt32 = 0
        var rejections = 0
        var undecodable = 0
        let send: (AnnotationMessage) -> Bool = { message in
            seq &+= 1
            let payload = FrameProtocol.encode(.annotation(seq: seq, message: message))
            guard !payload.isEmpty else { return false }
            guard case .annotation(_, let decoded)? = FrameProtocol.decode(payload) else {
                undecodable += 1
                return true
            }
            if !pilot.handle(decoded) { rejections += 1 }
            return true
        }
        func tooLargeForOneMessage(_ message: AnnotationMessage) -> Bool {
            FrameProtocol.encode(.annotation(seq: 0, message: message)).isEmpty
        }
        func assertMirrors(_ canvas: [AnnotationStroke], line: UInt = #line) {
            if plotter.isOutOfSync {
                XCTAssertFalse(pilot.hasInk, line: line)
            } else {
                XCTAssertEqual(pilot.strokes.count, canvas.count, line: line)
                XCTAssertEqual(pilot.strokes.map(\.points.count), canvas.map(\.points.count), line: line)
                XCTAssertEqual(
                    pilot.strokes.map { Double($0.points.first?.x ?? -1) },
                    canvas.map { $0.points.first?.x ?? -1 },
                    line: line
                )
                XCTAssertEqual(pilot.strokes.map { Double($0.width) }, canvas.map(\.width), line: line)
            }
        }

        // The very first real stroke reaches Pilot: its normalized width is
        // accepted by the wire format.
        var canvas = [stroke(0, points: 2)]
        plotter.sync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        assertMirrors(canvas)

        // Stroke ceiling: every message here fits in `maxAnnotationBytes`.
        canvas = (0..<(FrameProtocol.maxAnnotationStrokes - 1)).map { stroke($0, points: 2) }
        plotter.sync(to: canvas, send: send)
        canvas.append(stroke(FrameProtocol.maxAnnotationStrokes - 1, points: 2))
        plotter.sync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        assertMirrors(canvas)

        // One stroke past Pilot's stroke ceiling: not sent as `.addStroke`.
        canvas.append(stroke(FrameProtocol.maxAnnotationStrokes, points: 2))
        plotter.sync(to: canvas, send: send)
        XCTAssertTrue(plotter.isOutOfSync)
        assertMirrors(canvas)

        // Undoing it is not sent as `.undo` (which would drop the previous
        // stroke on Pilot); the full drawing is replaced instead.
        canvas.removeLast()
        plotter.sync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        assertMirrors(canvas)

        // Eraser in the middle, then incremental ops again.
        canvas.remove(at: 1)
        plotter.sync(to: canvas, send: send)
        canvas.append(stroke(9_000, points: 2))
        plotter.sync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        assertMirrors(canvas)

        // Point ceiling, built from appends that each fit on the wire.
        canvas = []
        plotter.sync(to: canvas, send: send)
        let quarter = FrameProtocol.maxAnnotationPoints / 4
        for id in 0..<4 {
            canvas.append(stroke(id, points: quarter))
            plotter.sync(to: canvas, send: send)
            assertMirrors(canvas)
        }
        XCTAssertFalse(plotter.isOutOfSync)

        // One stroke past Pilot's point ceiling: not sent as `.addStroke`.
        canvas.append(stroke(4, points: 3))
        plotter.sync(to: canvas, send: send)
        XCTAssertTrue(plotter.isOutOfSync)
        assertMirrors(canvas)

        // Undoing it needs a 100k-point replacement over `maxAnnotationBytes`;
        // Pilot is rebuilt stroke by stroke rather than sent `.undo`.
        canvas.removeLast()
        XCTAssertTrue(tooLargeForOneMessage(.replaceDrawing(AnnotationDrawing(strokes: canvas))))
        plotter.sync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        assertMirrors(canvas)

        // The eraser removes a middle stroke: a 75k-point replacement, still
        // over `maxAnnotationBytes`, rebuilt the same way.
        canvas.remove(at: 1)
        XCTAssertTrue(tooLargeForOneMessage(.replaceDrawing(AnnotationDrawing(strokes: canvas))))
        plotter.sync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        assertMirrors(canvas)

        // A Pilot-originated undo is applied on the iPad, which then resyncs
        // (as it does after a rotation or a Pilot reconnect).
        pilot.undo()
        canvas.removeLast()
        plotter.resync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        assertMirrors(canvas)

        // Incremental ops resume after a rebuild.
        canvas.append(stroke(5, points: 3))
        plotter.sync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        assertMirrors(canvas)

        // A single stroke too large to encode on its own fails closed.
        canvas = []
        plotter.sync(to: canvas, send: send)
        let unencodable = stroke(7, points: FrameProtocol.maxAnnotationPoints)
        XCTAssertTrue(tooLargeForOneMessage(.addStroke(unencodable)))
        canvas = [unencodable]
        plotter.sync(to: canvas, send: send)
        XCTAssertTrue(plotter.isOutOfSync)
        assertMirrors(canvas)

        // Once it is gone, a full replacement restores sync.
        canvas = [stroke(8, points: 3)]
        plotter.sync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        assertMirrors(canvas)

        XCTAssertEqual(rejections, 0)
        XCTAssertEqual(undecodable, 0)
    }

    /// Issue #431, across a reconnect: strokes drawn while Pilot is away reach
    /// it through the authentication-triggered resync, not the disconnected
    /// queue. The link is modelled on `FrameReceiver`: `sendAnnotation`
    /// refuses what it cannot encode; while disconnected `enqueueOutboundLocked`
    /// queues the packet but keeps only the newest 16; on authentication
    /// `didAuthenticatePilot` flushes that queue and then
    /// `MirrorModel.onCockpitAuthenticated` makes the canvas call
    /// `AnnotationMirrorSync.resync`. Pilot is the real ``RemoteInkModel``
    /// fed through `FrameProtocol` encode/decode.
    func testReconnectResyncRestoresStrokesDrawnWhileDisconnected() {
        let pendingLimit = 16
        let color = AnnotationColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        let width = AnnotationStroke.normalizedWidth(penWidth: 4, contentWidth: 1_024, contentHeight: 700)
        func stroke(_ id: Int) -> AnnotationStroke {
            AnnotationStroke(color: color, width: width, points: [
                AnnotationPoint(x: Double(id) / 100, y: 0.1),
                AnnotationPoint(x: Double(id) / 100, y: 0.5),
                AnnotationPoint(x: Double(id) / 100 + 0.01, y: 0.9),
            ])
        }
        let pilot = RemoteInkModel()
        var plotter = AnnotationMirrorSync()
        var seq: UInt32 = 0
        var connected = true
        var linkRefuses = false
        var pending: [Data] = []
        var rejections = 0
        func apply(_ payload: Data) {
            guard case .annotation(_, let decoded)? = FrameProtocol.decode(payload) else {
                XCTFail("an annotation the link accepted must decode")
                return
            }
            if !pilot.handle(decoded) { rejections += 1 }
        }
        let send: (AnnotationMessage) -> Bool = { message in
            guard !linkRefuses else { return false }
            seq &+= 1
            let payload = FrameProtocol.encode(.annotation(seq: seq, message: message))
            guard !payload.isEmpty else { return false }
            if connected {
                apply(payload)
            } else {
                pending.append(payload)
                if pending.count > pendingLimit { pending.removeFirst(pending.count - pendingLimit) }
            }
            return true
        }
        func authenticate() {
            connected = true
            let flushed = pending
            pending.removeAll()
            flushed.forEach(apply)
        }
        func pilotMatches(_ canvas: [AnnotationStroke]) -> Bool {
            pilot.strokes.map(\.points) == canvas.map { $0.points.map { CGPoint(x: $0.x, y: $0.y) } }
                && pilot.strokes.map { Double($0.width) } == canvas.map(\.width)
        }

        var canvas: [AnnotationStroke] = []
        for id in 0..<3 {
            canvas.append(stroke(id))
            plotter.sync(to: canvas, send: send)
        }
        XCTAssertTrue(pilotMatches(canvas))

        // Pilot drops off; 20 strokes are drawn. Each was handed to the link,
        // so the mirror records them, but the queue keeps only the newest 16.
        connected = false
        for id in 3..<23 {
            canvas.append(stroke(id))
            plotter.sync(to: canvas, send: send)
        }
        XCTAssertFalse(plotter.isOutOfSync)
        XCTAssertEqual(plotter.mirrored, canvas)
        XCTAssertEqual(pending.count, pendingLimit)

        // The flush alone leaves Pilot four strokes short, with later strokes
        // at the wrong indices; the resync that follows authentication fixes it.
        authenticate()
        XCTAssertEqual(pilot.strokes.count, canvas.count - (20 - pendingLimit))
        XCTAssertFalse(pilotMatches(canvas))
        plotter.resync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        XCTAssertTrue(pilotMatches(canvas))

        // Incremental ops line up again: Pilot's undo drops the same stroke.
        canvas.removeLast()
        plotter.sync(to: canvas, send: send)
        XCTAssertTrue(pilotMatches(canvas))

        // Sends the link refuses outright never advance the mirror: 18 strokes
        // drawn while refused leave it at the last delivered drawing, out of
        // sync, and Pilot untouched.
        let delivered = canvas
        connected = false
        linkRefuses = true
        for id in 100..<118 {
            canvas.append(stroke(id))
            plotter.sync(to: canvas, send: send)
            XCTAssertEqual(plotter.mirrored, delivered)
            XCTAssertTrue(plotter.isOutOfSync)
        }
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(pilotMatches(delivered))

        // Reauthentication resyncs the whole drawing and resumes sync.
        linkRefuses = false
        authenticate()
        plotter.resync(to: canvas, send: send)
        XCTAssertFalse(plotter.isOutOfSync)
        XCTAssertEqual(plotter.mirrored, canvas)
        XCTAssertTrue(pilotMatches(canvas))
        canvas.append(stroke(200))
        plotter.sync(to: canvas, send: send)
        XCTAssertTrue(pilotMatches(canvas))

        XCTAssertEqual(rejections, 0)
    }

    private func buttons(in root: NSView) -> [NSButton] {
        (root as? NSButton).map { [$0] } ?? root.subviews.flatMap { buttons(in: $0) }
    }

    private func accessibleControl(for button: NSButton) throws -> NSAccessibilityProtocol {
        // Native AppKit buttons may delegate their accessible action and value
        // to an NSButtonCell. Inspect the element VoiceOver actually reaches.
        let control = try XCTUnwrap(NSAccessibility.unignoredDescendant(of: button) as? NSAccessibilityProtocol)
        XCTAssertTrue(control.isAccessibilityElement())
        return control
    }

    private func descendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func pickerKey(code: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}

@MainActor
private final class CapturePickerFixtureController: CapturePaneController {
    var items: [CapturePickerItem] = []
    var refreshing = false

    init() { super.init(pane: Pane(kind: .device)) }
    required init?(coder: NSCoder) { nil }

    override func renderPresentation() {
        presentPicker(title: "Devices", refreshing: refreshing, refresh: {}, items: items)
    }
}

@MainActor
@Observable
private final class CapturePresentationFixture {
    var revision = 0
    var canRecord = true
}

@MainActor
private final class CapturePresentationFixtureController: CapturePaneController {
    let model: CapturePresentationFixture
    var displayedRevision = -1
    var createdSurfaces = 0
    var surface: NSView?
    var activations: [Bool] = []

    init(model: CapturePresentationFixture) {
        self.model = model
        super.init(pane: Pane(kind: .device))
    }

    required init?(coder: NSCoder) { nil }

    override func presentationDidChange(isActive: Bool) { activations.append(isActive) }

    override func renderPresentation() {
        displayedRevision = model.revision
        present(key: "stream") {
            createdSurfaces += 1
            let surface = CaptureResponderFixture()
            self.surface = surface
            return surface
        }
    }

    override func toolbarActions() -> [CapturePaneAction] {
        [CapturePaneAction(title: "Record", symbol: "record.circle", enabled: model.canRecord, perform: {})]
    }
}

@MainActor
private final class CaptureResponderFixture: NSView {
    override var acceptsFirstResponder: Bool { true }
}
