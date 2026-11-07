import AppKit

/// Agent Chat color tokens (dynamic light/dark, contrast-tested). Never use
/// LegibleAccent as a foreground. Dot fills may use system colors.
enum AgentChatPalette {
    /// sRGB hex values, 0xRRGGBB, for each appearance.
    struct Token: Equatable, Sendable {
        var light: UInt32
        var dark: UInt32
    }

    static func color(_ token: Token) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? token.dark : token.light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

extension AgentChatPalette.Token {
    static let thread = Self(light: 0xFFFFFF, dark: 0x0E0F11)
    static let card = Self(light: 0xF3F4F6, dark: 0x1C1F23)
    static let cardBorder = Self(light: 0xD5D8DD, dark: 0x30343A)
    static let textPrimary = Self(light: 0x1D1F22, dark: 0xECEEF1)
    static let textMuted = Self(light: 0x5B6169, dark: 0xA4AAB2)
    static let live = Self(light: 0x0A5BC4, dark: 0x7CB4FF)
    static let failure = Self(light: 0xC4271D, dark: 0xFF7A70)
    static let success = Self(light: 0x1E7A3E, dark: 0x5FD38A)
}

/// Motion policy: 0.15–0.2 s ease-out, nothing under Reduce Motion.
@MainActor
enum AgentChatMotion {
    static let duration: TimeInterval = 0.18
    /// Injectable for tests; defaults to the system setting.
    static var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// 14 pt monochrome template glyphs for every `AgentToolVerb.Glyph`.
@MainActor
enum AgentChatGlyphs {
    static func image(for glyph: AgentToolVerb.Glyph, pointSize: CGFloat = 14) -> NSImage {
        // WP4: implement
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.isTemplate = true
        return image
    }
}

/// Callbacks every Agent Chat view uses instead of holding the session.
/// Copy callbacks receive already-redacted text; the owner writes the pasteboard.
@MainActor
struct AgentChatRowActions {
    var openInspector: (AgentInspectorSubject, AgentInspectorTab?) -> Void = { _, _ in }
    var copyText: (String) -> Void = { _ in }
    /// User disclosure toggle for a group or roster ID.
    var toggleExpanded: (String) -> Void = { _ in }
    /// "Show N more" in a settled group with > 15 steps.
    var showAll: (String) -> Void = { _ in }
    /// The settle animation for a group ID finished (or was skipped).
    var collapseFinished: (String) -> Void = { _ in }
    /// Step key.
    var askToRetry: (String) -> Void = { _ in }
    /// Child session ID.
    var askToContinue: (String) -> Void = { _ in }
    var sendAgain: () -> Void = {}
}

/// Status dot with a distinct shape per state: queued gray ring, running
/// filled accent with an opacity pulse (none under Reduce Motion), done green
/// check, failed red x, stopped hollow gray, background half ring.
final class AgentStatusDotView: NSView {
    enum Status: Equatable, Sendable {
        case queued, running, done, failed, stopped, background

        init(_ lifecycle: AgentChatItem.Subagent.Lifecycle) {
            switch lifecycle {
            case .queued: self = .queued
            case .running: self = .running
            case .done, .ended: self = .done
            case .failed: self = .failed
            case .cancelled: self = .stopped
            case .background: self = .background
            }
        }

        init(_ tool: AgentChatItem.ToolCall) {
            if tool.isRunning {
                self = .running
                return
            }
            switch tool.outcome {
            case .failed: self = .failed
            case .cancelled, .rejected, .interrupted, .notFinished: self = .stopped
            case .completed: self = .done
            case nil: self = tool.status == .failed ? .failed : .done
            }
        }
    }

    static let size: CGFloat = 10
    private(set) var status: Status = .queued

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
    }

    required init?(coder: NSCoder) { nil }

    func configure(status: Status) {
        // WP4: implement (shapes, pulse, accessibility value)
        self.status = status
    }
}
