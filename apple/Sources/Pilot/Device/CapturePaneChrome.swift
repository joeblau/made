import AppKit
import Observation

@MainActor
protocol CapturePaneToolbarProviding: AnyObject {
    func makeCaptureToolbarView() -> NSView
}

@MainActor
struct CapturePaneAction {
    let title: String
    let symbol: String
    var enabled = true
    var selected = false
    let perform: () -> Void
}

typealias CaptureActionButton = CockpitActionButton

extension CockpitActionButton {
    convenience init(_ captureAction: CapturePaneAction, iconOnly: Bool = false) {
        self.init(title: iconOnly ? "" : captureAction.title, systemImage: captureAction.symbol, action: captureAction.perform)
        controlSize = .small
        update(captureAction, iconOnly: iconOnly)
    }

    func update(_ captureAction: CapturePaneAction, iconOnly: Bool = false) {
        title = iconOnly ? "" : captureAction.title
        image = NSImage(systemSymbolName: captureAction.symbol, accessibilityDescription: captureAction.title)
        imagePosition = iconOnly ? .imageOnly : .imageLeading
        onAction = captureAction.perform
        isEnabled = captureAction.enabled
        state = captureAction.selected ? .on : .off
        toolTip = captureAction.title
        setAccessibilityLabel(captureAction.title)
        // AppKit may expose the cell rather than the button as the unignored
        // accessibility element. Icon-only actions still need a spoken name.
        cell?.setAccessibilityLabel(captureAction.title)
    }
}

@MainActor
final class CaptureToolbarView: NSStackView {
    private static let slotSize = NSSize(width: 32, height: 28)
    private static let slotIdentifier = NSUserInterfaceItemIdentifier("capture.toolbar.slot")

    func update(_ actions: [CapturePaneAction]) {
        orientation = .horizontal
        alignment = .centerY
        // Icon-only buttons size to their glyphs, so wide symbols (AirPlay,
        // hammer) would get wider gaps. Equal slots keep the rhythm even.
        distribution = .fillEqually
        spacing = 2
        edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        updateCaptureActions(actions, iconOnly: true)
        for case let button as CaptureActionButton in arrangedSubviews {
            button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            button.imageScaling = .scaleProportionallyDown
            guard !button.constraints.contains(where: { $0.identifier == Self.slotIdentifier.rawValue }) else { continue }
            button.translatesAutoresizingMaskIntoConstraints = false
            let width = button.widthAnchor.constraint(equalToConstant: Self.slotSize.width)
            let height = button.heightAnchor.constraint(equalToConstant: Self.slotSize.height)
            width.identifier = Self.slotIdentifier.rawValue
            height.identifier = Self.slotIdentifier.rawValue
            NSLayoutConstraint.activate([width, height])
        }
    }
}

private extension NSStackView {
    func updateCaptureActions(_ actions: [CapturePaneAction], iconOnly: Bool = false) {
        while arrangedSubviews.count > actions.count {
            guard let last = arrangedSubviews.last else { break }
            removeArrangedSubview(last)
            last.removeFromSuperview()
        }
        for (index, action) in actions.enumerated() {
            if index < arrangedSubviews.count, let button = arrangedSubviews[index] as? CaptureActionButton {
                button.update(action, iconOnly: iconOnly)
            } else {
                addArrangedSubview(CaptureActionButton(action, iconOnly: iconOnly))
            }
        }
    }
}

/// Shared ownership for native capture presentation. The registry owns the
/// stream; this controller owns only attached views, observation and UI tasks.
@MainActor
class CapturePaneController: NSViewController, CockpitPanePresenting, CapturePaneToolbarProviding {
    let paneID: UUID
    private(set) var isPresentationActive = false
    private(set) var isPaneSelected = false
    private var observationGeneration = 0
    private var presentedKey: String?
    private var presentedView: NSView?
    private var toastTask: Task<Void, Never>?
    private var toastView: NSView?
    private var toolbarViews: [WeakCaptureToolbar] = []
    var onSelect: (() -> Void)?

    init(pane: Pane) {
        paneID = pane.id
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit { toastTask?.cancel() }

    override func loadView() {
        let canvas = NSView()
        let background = PreviewCanvasBackground()
        background.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            background.topAnchor.constraint(equalTo: canvas.topAnchor),
            background.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
        ])
        view = canvas
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        let changed = isPresentationActive != isActive
        let shouldFocus = isSelected && (!isPaneSelected || changed)
        isPresentationActive = isActive
        isPaneSelected = isSelected
        observationGeneration &+= 1
        if changed { presentationDidChange(isActive: isActive) }
        if isActive {
            _ = view
            observePresentation()
            if shouldFocus, let presentedView, presentedView.acceptsFirstResponder {
                view.window?.makeFirstResponder(presentedView)
            }
        } else {
            toastTask?.cancel()
            toastTask = nil
            toastView?.removeFromSuperview()
            toastView = nil
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        updatePresentation(isActive: false, isSelected: false)
    }

    func presentationDidChange(isActive: Bool) {}
    func renderPresentation() {}
    func toolbarActions() -> [CapturePaneAction] { [] }

    func observePresentation() {
        guard isPresentationActive else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            renderPresentation()
            toolbarViews.removeAll { $0.view == nil }
            let actions = toolbarActions()
            for toolbar in toolbarViews { toolbar.view?.update(actions) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isPresentationActive,
                      self.observationGeneration == generation else { return }
                self.observePresentation()
            }
        }
    }

    func makeCaptureToolbarView() -> NSView {
        let toolbar = CaptureToolbarView()
        toolbar.update(toolbarActions())
        toolbarViews.append(WeakCaptureToolbar(toolbar))
        return toolbar
    }

    func present(key: String, makeView: () -> NSView) {
        guard key != presentedKey else { return }
        presentedView?.removeFromSuperview()
        let next = makeView()
        next.translatesAutoresizingMaskIntoConstraints = false
        if let toastView {
            view.addSubview(next, positioned: .below, relativeTo: toastView)
        } else {
            view.addSubview(next)
        }
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.topAnchor.constraint(equalTo: view.topAnchor),
            next.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        presentedView = next
        presentedKey = key
        if isPaneSelected, next.acceptsFirstResponder { view.window?.makeFirstResponder(next) }
    }

    func presentPicker(title: String, refreshing: Bool, refresh: @escaping () -> Void, actions: [CapturePaneAction] = [], items: [CapturePickerItem], message: NSView? = nil, detail: String? = nil) {
        let picker: CaptureDevicePicker
        if presentedKey == "picker", let current = presentedView as? CaptureDevicePicker {
            picker = current
        } else {
            picker = CaptureDevicePicker()
            present(key: "picker") { picker }
        }
        picker.update(title: title, refreshing: refreshing, refresh: refresh, actions: actions, items: items, message: message, detail: detail)
    }

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill", duration: Duration = .seconds(1), color: NSColor = .white) {
        toastTask?.cancel()
        toastView?.removeFromSuperview()
        let toast = DevicePaneToast(text: text, symbol: symbol, tint: color)
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 6),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -6),
        ])
        toastView = toast
        toastTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.toastView?.removeFromSuperview()
            self?.toastView = nil
        }
    }
}

@MainActor
private final class WeakCaptureToolbar {
    weak var view: CaptureToolbarView?
    init(_ view: CaptureToolbarView) { self.view = view }
}

@MainActor
struct CapturePickerItem {
    let id: String
    let title: String
    var detail: String? = nil
    var symbol = "iphone"
    var enabled = true
    var group = false
    var select: (() -> Void)? = nil

    func hasSameContent(as other: Self) -> Bool {
        id == other.id && title == other.title && detail == other.detail && symbol == other.symbol
            && enabled == other.enabled && group == other.group
    }
}

@MainActor
final class CaptureDevicePicker: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private var items: [CapturePickerItem] = []
    private let table = CapturePickerTable()
    private let scroll = NSScrollView()
    private let content = NSView()
    private let titleLabel = CockpitUI.label("", size: 12, weight: .semibold)
    private let detailLabel = CockpitUI.label("", size: 12, color: .secondaryLabelColor)
    private let progress = NSProgressIndicator()
    private let refreshButton = CaptureActionButton(CapturePaneAction(title: "Refresh", symbol: "arrow.clockwise", perform: {}), iconOnly: true)
    private let actions = NSStackView()
    private var message: NSView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, NSView()])
        header.distribution = .fill
        header.spacing = 8
        progress.style = .spinning
        progress.controlSize = .small
        header.addArrangedSubview(progress)
        header.addArrangedSubview(refreshButton)
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.controlSize = .small
        refreshButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        actions.orientation = .horizontal
        actions.spacing = 4
        header.insertArrangedSubview(actions, at: 2)
        let column = NSStackView(views: [header, detailLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.activateSelection = { [weak self] in self?.activateSelection() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Polling changes the existing picker rather than replacing its table and
    /// responders. Unchanged rows retain their view and accessibility identity.
    func update(title: String, refreshing: Bool, refresh: @escaping () -> Void, actions: [CapturePaneAction] = [], items next: [CapturePickerItem], message: NSView? = nil, detail: String? = nil) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        progress.isHidden = !refreshing
        if refreshing { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        refreshButton.onAction = refresh
        refreshButton.isEnabled = !refreshing
        self.actions.updateCaptureActions(actions, iconOnly: true)
        for button in self.actions.arrangedSubviews.compactMap({ $0 as? NSButton }) {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
        }
        self.actions.isHidden = actions.isEmpty
        updateRows(next)
        self.message?.removeFromSuperview()
        self.message = nil
        scroll.isHidden = next.isEmpty && message != nil
        if next.isEmpty, let message {
            message.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(message)
            NSLayoutConstraint.activate([
                message.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                message.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                message.topAnchor.constraint(equalTo: content.topAnchor),
                message.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            self.message = message
        }
    }

    private func updateRows(_ next: [CapturePickerItem]) {
        let previous = items
        let selectedIDs = Set(table.selectedRowIndexes.compactMap { previous.indices.contains($0) ? previous[$0].id : nil })
        let scrollOrigin = scroll.contentView.bounds.origin
        items = next
        if previous.map(\.id) == next.map(\.id) {
            let changed = IndexSet(next.indices.filter { !previous[$0].hasSameContent(as: next[$0]) })
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        } else {
            // Apply insertions/removals/moves by identity so a refreshed USB/adb
            // list can change without discarding the surviving row views.
            var ids = previous.map(\.id)
            let nextIDs = Set(next.map(\.id))
            table.beginUpdates()
            for row in ids.indices.reversed() where !nextIDs.contains(ids[row]) {
                ids.remove(at: row)
                table.removeRows(at: IndexSet(integer: row), withAnimation: [])
            }
            for (row, item) in next.enumerated() {
                if let oldRow = ids.firstIndex(of: item.id) {
                    if row != oldRow {
                        ids.insert(ids.remove(at: oldRow), at: row)
                        table.moveRow(at: oldRow, to: row)
                    }
                } else {
                    ids.insert(item.id, at: row)
                    table.insertRows(at: IndexSet(integer: row), withAnimation: [])
                }
            }
            table.endUpdates()
            let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let changed = IndexSet(next.indices.filter { row in
                previousByID[next[row].id].map { !$0.hasSameContent(as: next[row]) } ?? false
            })
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        }
        let selection = IndexSet(next.indices.filter { selectedIDs.contains(next[$0].id) && next[$0].enabled && !next[$0].group })
        if selection != table.selectedRowIndexes { table.selectRowIndexes(selection, byExtendingSelection: false) }
        scroll.contentView.scroll(to: scrollOrigin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items.indices.contains(row) && items[row].enabled && !items[row].group }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { items.indices.contains(row) && items[row].group }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { items.indices.contains(row) && items[row].group ? 26 : 48 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        items.indices.contains(row) && !items[row].group ? CockpitCardRowView() : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let title = CockpitUI.label(item.title, size: item.group ? 11 : 13, weight: item.group ? .semibold : .regular)
        title.textColor = item.enabled ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        if item.group { return title }
        let icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let labels = NSStackView(views: [title])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        if let detail = item.detail {
            let subtitle = CockpitUI.label(detail, size: 11, color: .secondaryLabelColor)
            subtitle.lineBreakMode = .byTruncatingTail
            subtitle.maximumNumberOfLines = 1
            labels.addArrangedSubview(subtitle)
        }
        let cell = CapturePickerRow(views: [icon, labels])
        cell.spacing = 10
        cell.alignment = .centerY
        cell.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        cell.toolTip = [item.title, item.detail].compactMap { $0 }.joined(separator: ", ")
        cell.setAccessibilityLabel(cell.toolTip)
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.button)
        cell.setAccessibilityEnabled(item.enabled)
        cell.activate = { [weak self] in self?.activateItem(id: item.id) ?? false }
        return cell
    }

    private func activateSelection() {
        guard items.indices.contains(table.selectedRow) else { return }
        _ = activateItem(id: items[table.selectedRow].id)
    }

    private func activateItem(id: String) -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.enabled, !item.group else { return false }
        item.select?()
        return true
    }
}

@MainActor
private final class CapturePickerRow: NSStackView {
    var activate: (() -> Bool)?
    override func accessibilityPerformPress() -> Bool { activate?() ?? false }
}

@MainActor
private final class CapturePickerTable: NSTableView {
    var activateSelection: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if clicked >= 0, clicked == selectedRow { activateSelection?() }
    }

    override func keyDown(with event: NSEvent) {
        let activates = [36, 76, 49].contains(event.keyCode)
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if activates {
            if !event.isARepeat { activateSelection?() }
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class CapturePaneMessage: NSView {
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let stack: NSStackView
    private var wordFloor: CGFloat {
        [titleLabel, detailLabel].map { label in
            label.stringValue.split(whereSeparator: { $0.isWhitespace }).map {
                (String($0) as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13)]).width
            }.max() ?? 0
        }.max().map { max(100, $0 + 24) } ?? 100
    }

    init(_ title: String, symbol: String, detail: String? = nil, loading: Bool = false, dark: Bool = false, actions: [CapturePaneAction] = []) {
        titleLabel = CockpitUI.label(title, size: 17, weight: .semibold)
        detailLabel = CockpitUI.label(detail ?? "", size: 12, color: .secondaryLabelColor)
        titleLabel.alignment = .center
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        stack = NSStackView(views: [icon, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        super.init(frame: .zero)
        if dark { appearance = NSAppearance(named: .darkAqua) }
        if loading {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.startAnimation(nil)
            stack.addArrangedSubview(spinner)
        }
        for action in actions { stack.addArrangedSubview(CaptureActionButton(action)) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        toolTip = [title, detail].compactMap { $0 }.joined(separator: ". ")
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let compact = bounds.width < wordFloor
        titleLabel.isHidden = compact
        detailLabel.isHidden = compact
        setAccessibilityElement(compact)
        setAccessibilityLabel(compact ? toolTip : nil)
    }
}

enum WordFloorText {
    static func oneWordPerLine(_ string: String, probing: Bool) -> String {
        probing ? string.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: "\n") : string
    }
}

@MainActor
final class DevicePaneToast: NSView {
    nonisolated static let scrimOpacity = 0.75

    init(text: String, symbol: String, tint: NSColor = .white) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.scrimOpacity).cgColor
        layer?.cornerRadius = 18
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = tint
        let label = CockpitUI.label(text, size: 13, weight: .semibold, color: tint)
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [icon, label])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
