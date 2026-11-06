import AppKit

final class NativeCodeSuggestionLabelView: NSTableCellView {
    init(suggestion: any CodeSuggestionEntry, labelColor: NSColor, secondaryLabelColor: NSColor, font: NSFont) {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = suggestion.nativeImage
        icon.contentTintColor = suggestion.deprecated ? .secondaryLabelColor : suggestion.nativeImageColor
        let label = NSTextField(labelWithString: suggestion.label)
        label.font = font
        label.textColor = suggestion.deprecated ? secondaryLabelColor : labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: suggestion.detail ?? "")
        detail.font = font
        detail.textColor = secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let warning = NSImageView()
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Deprecated")
        warning.isHidden = !suggestion.deprecated
        let row = NSStackView(views: [icon, label, detail, NSView(), warning])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            icon.widthAnchor.constraint(equalToConstant: font.pointSize + 2),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel([suggestion.label, suggestion.detail, suggestion.deprecated ? "Deprecated" : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { nil }
}
