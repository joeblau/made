import AppKit

@MainActor
final class AgenticUseInsightsView: AgenticUseCardView {
    private var entries: [AgenticUseInsightRow] = []
    init(insights: [AgenticUseInsight]) {
        super.init(title: "Insights")
        update(insights: insights)
    }
    required init?(coder: NSCoder) { nil }
    func update(insights: [AgenticUseInsight]) {
        entries.forEach { $0.removeFromSuperview() }
        entries = insights.map(AgenticUseInsightRow.init)
        entries.forEach(addSubview)
        needsLayout = true
    }
    private func columns(for width: CGFloat) -> Int {
        max(1, min(entries.count, Int(max(0, width - 32) / (208 * AgenticUseLayout.zoom))))
    }
    override func preferredHeight(for width: CGFloat) -> CGFloat {
        let columns = columns(for: width)
        let cellWidth = max(1, (width - 32 - CGFloat(columns - 1) * 16) / CGFloat(columns))
        let rows = stride(from: 0, to: entries.count, by: columns)
        return 48 * AgenticUseLayout.zoom + rows.reduce(CGFloat(0)) { height, start in
            height + (entries[start..<min(entries.count, start + columns)].map { $0.height(for: cellWidth) }.max() ?? 0) + 12
        }
    }
    override func layout() {
        super.layout()
        let columns = columns(for: bounds.width)
        let width = max(1, (bounds.width - 32 - CGFloat(columns - 1) * 16) / CGFloat(columns))
        var y = 44 * AgenticUseLayout.zoom
        for start in stride(from: 0, to: entries.count, by: columns) {
            let end = min(entries.count, start + columns)
            let height = entries[start..<end].map { $0.height(for: width) }.max() ?? 0
            for index in start..<end {
                entries[index].frame = NSRect(x: 16 + CGFloat(index - start) * (width + 16), y: y, width: width, height: height)
            }
            y += height + 12
        }
    }
    static func symbol(for kind: AgenticUseInsight.Kind) -> String {
        switch kind {
        case .cacheHitRate: "arrow.triangle.2.circlepath"
        case .spike: "waveform.path.ecg"
        case .costChange: "dollarsign"
        case .topModel: "crown.fill"
        }
    }
    static func tint(for kind: AgenticUseInsight.Kind) -> NSColor {
        switch kind {
        case .cacheHitRate: .systemGreen
        case .spike: .systemOrange
        case .costChange: .systemBlue
        case .topModel: .systemPurple
        }
    }
}

@MainActor
private final class AgenticUseInsightRow: AgenticUseFlippedView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let tint: NSColor
    init(_ insight: AgenticUseInsight) {
        tint = AgenticUseInsightsView.tint(for: insight.kind)
        super.init(frame: .zero)
        title.stringValue = insight.title
        detail.stringValue = insight.detail
        detail.textColor = .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: AgenticUseInsightsView.symbol(for: insight.kind), accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.setAccessibilityElement(false)
        [title, detail, icon].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(insight.title). \(insight.detail)")
    }
    required init?(coder: NSCoder) { nil }
    private func textHeight(_ label: NSTextField, width: CGFloat, font: NSFont) -> CGFloat {
        label.font = font
        return ceil((label.stringValue as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 4
    }
    func height(for width: CGFloat) -> CGFloat {
        let width = width - 40 * AgenticUseLayout.zoom
        return max(36 * AgenticUseLayout.zoom, textHeight(title, width: width, font: AgenticUseLayout.font(.body, weight: .semibold)) + textHeight(detail, width: width, font: AgenticUseLayout.font(.meta)) + 4)
    }
    override func layout() {
        super.layout()
        let z = AgenticUseLayout.zoom
        icon.frame = NSRect(x: 7 * z, y: 7 * z, width: 18 * z, height: 18 * z)
        let x = 40 * z
        let width = max(1, bounds.width - x)
        let titleHeight = textHeight(title, width: width, font: AgenticUseLayout.font(.body, weight: .semibold))
        title.frame = NSRect(x: x, y: 0, width: width, height: titleHeight)
        detail.frame = NSRect(x: x, y: titleHeight + 4, width: width, height: max(0, bounds.height - titleHeight - 4))
    }
    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.16).setFill()
        let size = 32 * AgenticUseLayout.zoom
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 8, yRadius: 8).fill()
    }
}
