import AppKit
import SwiftUI

/// A native chat pane driving a coding agent over ACP, in place of its TUI.
struct AgentChatPaneView: View {
    let paneID: UUID
    let workingDirectory: String?
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let session = AgentChatRegistry.shared.session(for: paneID, workingDirectory: workingDirectory)
        AgentChatContent(session: session, isSelected: isSelected, onSelect: onSelect)
            // Restored panes in background workspaces stay idle until shown,
            // so launching Cockpit doesn't start every saved agent at once.
            .task(id: AgentChatStartKey(isActive: isActive, workingDirectory: workingDirectory)) {
                session.setWorkingDirectory(workingDirectory)
                if isActive { session.startIfNeeded() }
            }
    }
}

private struct AgentChatStartKey: Hashable {
    var isActive: Bool
    var workingDirectory: String?
}

private struct AgentChatContent: View {
    @Bindable var session: AgentChatSession
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AgentChatHeader(session: session)
            Divider()
            Group {
                if case .needsSetup(let issue) = session.phase {
                    AgentChatSetupView(issue: issue, agent: session.agent) { session.restart() }
                } else {
                    AgentChatTranscriptView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if case .failed(let message) = session.phase {
                AgentChatFailureBanner(message: message) { session.restart() }
            }
            if let request = session.pendingPermission {
                AgentPermissionCard(
                    agent: session.agent,
                    request: request,
                    queuedCount: session.permissionQueue.count - 1
                ) { optionID in
                    session.answerPermission(request, optionID: optionID)
                }
            }
            AgentChatComposer(session: session, isSelected: isSelected)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.control, style: .continuous))
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }
}

// MARK: - Header

private struct AgentChatHeader: View {
    let session: AgentChatSession

    var body: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Menu {
                Section("Agent") {
                    ForEach(ChatAgent.allCases) { agent in
                        Button {
                            session.switchAgent(to: agent)
                        } label: {
                            if agent == session.agent {
                                Label(agent.displayName, systemImage: "checkmark")
                            } else {
                                Text(agent.displayName)
                            }
                        }
                    }
                }
                Divider()
                Button("New Conversation") { session.startNewConversation() }
                Button("Restart Agent") { session.restart() }
            } label: {
                HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    Circle()
                        .fill(AgenticUseModelPalette.providerColor(for: session.agent.provider))
                        .frame(width: 8, height: 8)
                    Text(session.agent.displayName)
                        .scaledFont(size: 13, weight: .semibold)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Switch agent or start a new conversation")

            if let model = session.modelName {
                Text(model)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)

            AgentUsageChips(session: session)

            if session.phase == .starting || session.phase == .prompting {
                ProgressView()
                    .controlSize(.small)
                    .help(session.phase == .starting ? "Starting \(session.agent.displayName)…" : "Working…")
            }
        }
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
    }
}

/// Context-window and cache figures. Cache hit rate is the share of the
/// last turn's prompt served from the agent's prompt cache, normalized
/// across agents (see `NormalizedTurnUsage`).
private struct AgentUsageChips: View {
    let session: AgentChatSession

    var body: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
            if let context = session.context {
                chip("\(AgentChatFormat.tokens(context.usedTokens)) / \(AgentChatFormat.tokens(context.windowTokens))")
                    .help(contextHelp(context))
            }
            if let rate = session.lastTurnUsage?.cacheHitRate {
                chip("Cache \(AgentChatFormat.percent(rate))")
                    .help(cacheHelp)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 10, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: Capsule())
    }

    private func contextHelp(_ context: ACPContextUsage) -> String {
        var text = "Context window: \(context.usedTokens.formatted()) of \(context.windowTokens.formatted()) tokens used"
        if let amount = context.costAmount {
            text += "\nSession cost: \(amount.formatted(.currency(code: context.costCurrency ?? "USD")))"
        }
        return text
    }

    private var cacheHelp: String {
        guard let total = session.sessionUsage else { return "" }
        return "Last turn's prompt served from the agent's cache.\nThis session: "
            + "\(total.cacheReadTokens.formatted()) cached, \(total.uncachedInputTokens.formatted()) uncached, "
            + "\(total.cacheWriteTokens.formatted()) written to cache, \(total.outputTokens.formatted()) output tokens."
    }
}

// MARK: - Transcript

private struct AgentChatTranscriptView: View {
    let session: AgentChatSession

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
                if session.transcript.items.isEmpty, session.phase == .ready {
                    emptyState
                }
                ForEach(session.transcript.items) { item in
                    AgentChatItemView(item: item, transcript: session.transcript)
                }
                if session.phase == .starting {
                    statusLine("Starting \(session.agent.displayName)…")
                }
            }
            .padding(LiquidGlassMetrics.Spacing.medium)
        }
        // Follow streaming output while the user is at the bottom.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
    }

    private var emptyState: some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .scaledFont(size: 28)
                .foregroundStyle(.tertiary)
            Text("Ask \(session.agent.displayName) about \(directoryName)")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LiquidGlassMetrics.Spacing.xxLarge)
    }

    private var directoryName: String {
        session.workingDirectory.map { ($0 as NSString).lastPathComponent } ?? "this workspace"
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct AgentChatItemView: View {
    let item: AgentChatItem
    let transcript: AgentTranscript

    var body: some View {
        switch item.content {
        case .user(let text):
            HStack {
                Spacer(minLength: LiquidGlassMetrics.Spacing.xxLarge * 2)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
                    .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
                    .background(
                        Color.accentColor.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.field, style: .continuous)
                    )
            }
        case .assistant(let text):
            AgentMarkdownView(text: text)
        case .thought(let text):
            AgentThoughtView(text: text)
        case .tool(let tool):
            AgentToolCallRow(tool: tool)
        case .plan(let entries):
            AgentPlanView(entries: entries)
        case .subagent(let subagent):
            AgentSubagentCard(subagent: subagent, transcript: transcript)
        case .notice(let text):
            Label(text, systemImage: "info.circle")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AgentMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            ForEach(Array(AgentChatMarkdown.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(AgentChatMarkdown.inline(prose))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let code):
                    ScrollView(.horizontal) {
                        Text(code)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(LiquidGlassMetrics.Spacing.xSmall)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        .fill.quaternary,
                        in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.control, style: .continuous)
                    )
                }
            }
        }
    }
}

private struct AgentThoughtView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Thinking", systemImage: "brain")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AgentToolCallRow: View {
    let tool: AgentChatItem.ToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
            Button {
                withAnimation(LiquidGlassMetrics.stateChange) { isExpanded.toggle() }
            } label: {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Image(systemName: Self.symbol(for: tool.kind))
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text(tool.title)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
                    statusIcon
                    if !tool.content.isEmpty {
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 9, weight: .bold)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tool.content.isEmpty)
            .accessibilityLabel("\(tool.title), \(statusDescription)")

            if isExpanded, !tool.content.isEmpty {
                ScrollView {
                    Text(tool.content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(LiquidGlassMetrics.Spacing.xSmall)
                }
                .frame(maxHeight: 200)
                .background(
                    .fill.quaternary,
                    in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.control, style: .continuous)
                )
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tool.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending, .inProgress, nil:
            ProgressView().controlSize(.mini)
        }
    }

    private var statusDescription: String {
        switch tool.status {
        case .completed: "completed"
        case .failed: "failed"
        case .pending, .inProgress, nil: "running"
        }
    }

    static func symbol(for kind: ACPToolKind?) -> String {
        switch kind {
        case .read: "doc.text"
        case .edit: "pencil"
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        case .search: "magnifyingglass"
        case .execute: "terminal"
        case .think: "brain"
        case .fetch: "globe"
        case .switchMode: "arrow.triangle.swap"
        case .other, nil: "wrench.and.screwdriver"
        }
    }
}

private struct AgentPlanView: View {
    let entries: [ACPPlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
            Label("Plan", systemImage: "list.bullet.clipboard")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Image(systemName: Self.symbol(for: entry.status))
                        .foregroundStyle(entry.status == "completed" ? Color.green : Color.secondary)
                    Text(entry.content)
                        .strikethrough(entry.status == "completed")
                        .foregroundStyle(entry.status == "completed" ? .secondary : .primary)
                }
                .scaledFont(size: 12)
            }
        }
        .padding(LiquidGlassMetrics.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.card, style: .continuous))
    }

    private static func symbol(for status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted.circle"
        default: "circle"
        }
    }
}

private struct AgentSubagentCard: View {
    let subagent: AgentChatItem.Subagent
    let transcript: AgentTranscript
    @State private var isExpanded = false

    var body: some View {
        let children = transcript.children(of: subagent.childSessionID)
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Button {
                withAnimation(LiquidGlassMetrics.stateChange) { isExpanded.toggle() }
            } label: {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(subagent.title)
                            .scaledFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                        if let detail = subagent.detail, !detail.isEmpty {
                            Text(detail)
                                .scaledFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
                    if subagent.error != nil {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    } else if subagent.isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text("\(children.count) step\(children.count == 1 ? "" : "s")")
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 9, weight: .bold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Subagent \(subagent.title), \(subagent.isRunning ? "running" : "finished")")

            if let error = subagent.error {
                Text(error)
                    .scaledFont(size: 11)
                    .foregroundStyle(.red)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    ForEach(children) { child in
                        AgentChatItemView(item: child, transcript: transcript)
                    }
                }
                .padding(.leading, LiquidGlassMetrics.Spacing.small)
            }
        }
        .padding(LiquidGlassMetrics.Spacing.small)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.card, style: .continuous))
    }
}

// MARK: - Permission, setup, failure

private struct AgentPermissionCard: View {
    let agent: ChatAgent
    let request: ACPPermissionRequest
    let queuedCount: Int
    let answer: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(agent.displayName) is asking for permission")
                    .scaledFont(size: 12, weight: .semibold)
                Spacer()
                if queuedCount > 0 {
                    Text("+\(queuedCount) more")
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Image(systemName: AgentToolCallRow.symbol(for: request.toolKind))
                    .foregroundStyle(.secondary)
                Text(request.title)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                ForEach(orderedOptions) { option in
                    if option.kind == .allowOnce {
                        Button(option.name) { answer(option.id) }
                            .compatGlassProminentButtonStyle()
                            .buttonBorderShape(.capsule)
                    } else {
                        Button(option.name) { answer(option.id) }
                            .compatGlassButtonStyle()
                            .buttonBorderShape(.capsule)
                    }
                }
            }
        }
        .padding(LiquidGlassMetrics.Spacing.small)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.card, style: .continuous))
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
        .padding(.top, LiquidGlassMetrics.Spacing.xSmall)
    }

    /// Allow choices first, in the agent's order, then rejections.
    private var orderedOptions: [ACPPermissionRequest.Option] {
        request.options.filter { $0.kind?.allows == true } + request.options.filter { $0.kind?.allows != true }
    }
}

private struct AgentChatSetupView: View {
    let issue: ChatAgentSetupIssue
    let agent: ChatAgent
    let retry: () -> Void

    var body: some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.small) {
            Image(systemName: "wrench.and.screwdriver")
                .scaledFont(size: 28)
                .foregroundStyle(.tertiary)
            Text(issue.message)
                .multilineTextAlignment(.center)
            if let command = issue.command {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
                        .background(
                            .fill.quaternary,
                            in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.control, style: .continuous)
                        )
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy command")
                }
            }
            if issue != .noWorkingDirectory {
                Button("Try Again", action: retry)
                    .compatGlassButtonStyle()
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(LiquidGlassMetrics.Spacing.xLarge)
    }
}

private struct AgentChatFailureBanner: View {
    let message: String
    let restart: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .scaledFont(size: 12)
                .lineLimit(6)
                .textSelection(.enabled)
            Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
            Button("Restart", action: restart)
                .compatGlassButtonStyle()
                .buttonBorderShape(.capsule)
        }
        .padding(LiquidGlassMetrics.Spacing.small)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.card, style: .continuous))
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
        .padding(.top, LiquidGlassMetrics.Spacing.xSmall)
    }
}

// MARK: - Composer

private struct AgentChatComposer: View {
    @Bindable var session: AgentChatSession
    let isSelected: Bool
    @FocusState private var isFocused: Bool

    private var acceptsInput: Bool { session.phase == .ready || session.phase == .prompting }

    var body: some View {
        HStack(alignment: .bottom, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            TextField("Message \(session.agent.displayName)", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($isFocused)
                .disabled(!acceptsInput)
                // Return sends; Option-Return inserts a newline.
                .onSubmit { session.send() }
                .onKeyPress(.escape) {
                    guard session.phase == .prompting else { return .ignored }
                    session.cancelTurn()
                    return .handled
                }
                .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
                .padding(.vertical, LiquidGlassMetrics.fieldVerticalPadding)
                .background(
                    .fill.quaternary,
                    in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.field, style: .continuous)
                )

            if session.phase == .prompting {
                Button {
                    session.cancelTurn()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .compatGlassButtonStyle()
                .buttonBorderShape(.circle)
                .help("Stop (Esc)")
                .accessibilityLabel("Stop")
            } else {
                Button {
                    session.send()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .compatGlassProminentButtonStyle()
                .buttonBorderShape(.circle)
                .disabled(!session.canSend)
                .help("Send (Return)")
                .accessibilityLabel("Send")
            }
        }
        .padding(LiquidGlassMetrics.Spacing.small)
        .onChange(of: isSelected, initial: true) { _, selected in
            if selected { isFocused = true }
        }
    }
}

// MARK: - Tab badge

/// Names the pane's agent in its tab, with a spinner while a turn runs.
struct AgentChatTabBadge: View {
    let paneID: UUID

    var body: some View {
        let session = AgentChatRegistry.shared.existingSession(for: paneID)
        let agent = session?.agent ?? AgentChatPaneStore.agent(for: paneID)
        HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
            Text(agent.displayName)
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    AgenticUseModelPalette.providerColor(for: agent.provider).opacity(0.15),
                    in: Capsule()
                )
            if session?.phase == .prompting {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

// MARK: - Formatting

enum AgentChatFormat {
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return (value / 1_000).formatted(style) + "k"
        default: return (value / 1_000_000).formatted(style) + "M"
        }
    }

    static func percent(_ rate: Double) -> String {
        "\(Int((rate * 100).rounded()))%"
    }
}

/// Minimal Markdown for agent replies: fenced code blocks render as
/// monospaced blocks, everything else as inline Markdown. An unterminated
/// fence (mid-stream) renders as code so text doesn't jump when it closes.
enum AgentChatMarkdown {
    enum Segment: Equatable {
        case prose(String)
        case code(String)
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    segments.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                } else if !prose.isEmpty {
                    let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    if !joined.isEmpty { segments.append(.prose(joined)) }
                    prose.removeAll()
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode {
            segments.append(.code(code.joined(separator: "\n")))
        } else {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
        }
        return segments
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }
}
