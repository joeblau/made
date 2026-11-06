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
        CockpitPaneModePicker(pane: pane).selectMode(at: 1)
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

        for refreshing in [true, false, true, false] {
            controller.refreshing = refreshing
            controller.updatePresentation(isActive: true, isSelected: false)
            controller.view.layoutSubtreeIfNeeded()
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
        try await Task.sleep(for: .milliseconds(100))
        controller.toolPicker.delegate?.markupToolbarViewController(controller.toolPicker, insertNewShape: .rectangle)
        try await waitForAnnotation(in: controller)
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
        try await Task.sleep(for: .milliseconds(100))
        controller.toolPicker.delegate?.markupToolbarViewController(controller.toolPicker, insertNewShape: .ellipse)
        try await waitForAnnotation(in: controller)
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

    private func waitForAnnotation(in controller: InkOverlayViewController) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.markupController.markup?.contentsRenderFrame.isEmpty != false,
              ContinuousClock.now < deadline {
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
