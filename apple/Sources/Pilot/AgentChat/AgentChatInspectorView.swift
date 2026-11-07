import AppKit

/// What the Inspector shows. Keys are namespaced "<session>/<item>".
enum AgentInspectorSubject: Equatable, Hashable, Sendable {
    case step(key: String)
    case thought(key: String)
    case agent(childSessionID: String)
    case group(id: String)
    case plan(key: String)
    case run
}

/// Reasoning appears only for subjects that have it.
enum AgentInspectorTab: String, Equatable, Sendable, CaseIterable {
    case input, output, reasoning, meta
}

/// Everything the Inspector renders for one subject, gathered by the pane.
/// The Inspector redacts every string before display, copy, or export.
struct AgentInspectorContent: Equatable, Sendable {
    var subject: AgentInspectorSubject
    var title: String
    /// Names the reporter: "No input reported by <agent>", "tokens reported by <agent>".
    var agentName: String
    /// The step, thought, plan, or subagent card item.
    var item: AgentChatItem?
    /// nil: no raw payload was reported; `evicted`: "Detail evicted".
    var detail: AgentStepDetail?
    /// Group subject, or the child's projected card for an agent subject.
    var group: AgentActivityGroup?
    /// An agent subject's final prose.
    var finalProse: String?
    var model: String?
    /// Per turn or per agent; never per step.
    var turnUsage: NormalizedTurnUsage?
    var context: ACPContextUsage?
}

/// Run-trace and step export documents. Always redacted; reasoning is
/// excluded unless `includeReasoning`.
enum AgentRunTrace {
    static let schema = "cockpit.agent-chat.trace/1"

    static func json(transcript: AgentTranscript, agentName: String, includeReasoning: Bool) -> JSONValue {
        // WP5: implement
        ["schema": .string(schema), "redacted": true]
    }

    static func stepJSON(item: AgentChatItem, detail: AgentStepDetail?) -> JSONValue {
        // WP5: implement
        ["schema": .string(schema), "redacted": true]
    }
}

/// Trailing overlay drawer over the transcript (no table reflow), resizable
/// via a drag handle between `minimumWidth` and min(`maximumWidth`, 85% of
/// the pane), closable, focus-trapped; Esc closes; a click outside dismisses
/// below 560 pt. Tabs: Input / Output / Reasoning / Meta. Actions: Copy input,
/// Copy output (redacted), Copy unredacted (concealed pasteboard type), Export
/// step JSON, Export run trace JSON, and Export reasoning (only when
/// `allowsReasoningExport()`). Reasoning text is selectable only when allowed.
final class AgentInspectorViewController: NSViewController {
    static let accessibilityIdentifierValue = "agent-chat.inspector"
    static let allowReasoningExportKey = "agentChat.allowReasoningExport"
    static let minimumWidth: CGFloat = 240
    static let maximumWidth: CGFloat = 520

    /// Called after the drawer closes (Esc, close button, outside click).
    var onClose: () -> Void = {}
    /// Builds the run trace for export; the argument is whether reasoning is included.
    var makeRunTrace: (Bool) -> JSONValue = { _ in .null }
    private(set) var subject: AgentInspectorSubject?
    var isPresented: Bool { subject != nil }

    private let allowsReasoningExport: () -> Bool

    init(allowsReasoningExport: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: AgentInspectorViewController.allowReasoningExportKey)
    }) {
        self.allowsReasoningExport = allowsReasoningExport
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
    }

    /// Opens (or retargets) the drawer. `tab` nil picks the subject's default.
    func present(_ content: AgentInspectorContent, tab: AgentInspectorTab?) {
        // WP5: implement
        subject = content.subject
    }

    /// Refreshes the open subject in place (streaming output, settled times).
    func update(_ content: AgentInspectorContent) {
        // WP5: implement
    }

    func dismiss() {
        // WP5: implement
        subject = nil
        onClose()
    }
}
