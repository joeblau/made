# Agent Chat pane

Cockpit's **Agent Chat** pane drives a coding agent — Claude Code, Codex, Kimi
Code, or Grok Build — through a native chat UI instead of the agent's terminal
UI. It speaks the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP, v1): JSON-RPC 2.0, one message per line, over the agent's stdin/stdout.

Source: `apple/Sources/Pilot/AgentChat/`. Tests: `AgentChatTests`.

## How each agent is launched

| Agent  | Command                | Notes |
|--------|------------------------|-------|
| Claude | `claude-agent-acp`     | ACP adapter around the Claude Agent SDK. `CLAUDE_CODE_EXECUTABLE` points it at the user's installed `claude`. |
| Codex  | `codex-acp`            | ACP adapter around `codex app-server`. `CODEX_PATH` points it at the user's installed `codex`. |
| Kimi   | `kimi acp`             | Native ACP. |
| Grok   | `grok agent stdio`     | Native ACP. |

Cockpit never downloads or bundles the adapters. When one is missing, the pane
shows the exact pinned install command (`@agentclientprotocol/claude-agent-acp@0.101.0`,
`@agentclientprotocol/codex-acp@2.5.0`, the versions Cockpit was verified
against). Pointing each adapter at the installed CLI keeps the chat on the same
CLI version, configuration, and login as the user's terminal.

The executable and environment come from the user's login shell
(`$SHELL -l -i -c 'env -0'`, captured once per launch, delimited by random
markers so shell start-up output is ignored). A GUI app otherwise inherits
launchd's minimal environment and would not find the CLIs or their runtimes.
Variables a parent Claude Code session exports (`CLAUDECODE`,
`CLAUDE_CODE_SESSION_ID`, …) are removed so a nested `claude` does not think it
is a subprocess of that session; user configuration such as
`CLAUDE_CODE_USE_BEDROCK` is kept. Environment values are never logged.

## Trust boundary

Agent stdout and stderr are untrusted input:

- Lines longer than 16 MiB close the connection before they are parsed, and the
  framer rescans only new bytes, so a long line costs linear time.
- JSON nesting deeper than 64 levels is rejected.
- Non-JSON stdout lines are ignored (some agents print diagnostics there).
- Only the last 16 KiB of stderr is retained, for error messages.
- At most 32 permission requests queue; more are answered `cancelled`.
- Each pane keeps at most 2,000 transcript items per session; the agent keeps
  the full history.
- Writes to stdin use `F_SETNOSIGPIPE`, so an exited agent surfaces as a write
  error rather than a `SIGPIPE` that terminates Cockpit.

Cockpit advertises **no** `fs` or `terminal` client capabilities. Agents use
their own built-in file and shell tools under their own permission rules,
exactly as in their TUI; Cockpit never reads or writes files on an agent's
behalf. Requests for those methods are answered `Method not found`.

Permission requests are shown to the user and never auto-approved. Cancelling a
turn first answers every open request `cancelled`, as ACP requires.

Sign-in is never initiated from Cockpit. If an agent reports `auth_required`,
Cockpit completes only a silent method the agent itself marks as cached (Grok's
`cached_token`); otherwise the pane shows the CLI's login command to run in a
terminal. Cockpit never opens a browser or selects API-key auth, which could
change how the user is billed.

## Context, prompt caching, and subagents

The agent owns the conversation. Cockpit sends only each new prompt
(`session/prompt`), so the agent builds every model request with its own prompt
caching, compaction, and context management. To keep caching intact, a pane
keeps one long-lived agent process per session, passes no extra MCP servers
(the agent keeps its configured ones, and with them its cacheable prompt
prefix), and adds nothing to the system prompt.

Usage shown in the pane is normalized because agents disagree on what
`inputTokens` means: Grok's includes cache reads, Claude's and Codex's do not,
Codex reports no cache writes, and Kimi reports no per-turn usage over ACP
(only context size). These semantics were measured against Claude Code
2.1.318, Codex 0.166.0, Kimi Code 2.5.0, and Grok Build 1.0.70; re-verify
`ChatAgent.inputTokensIncludeCacheReads` when an agent changes its reporting.

Cockpit opts into ACP's subagents RFD (`clientCapabilities.subagents`):

- Claude and Codex announce each subagent with `subagent_update` and run it as
  a child session, which the pane renders as a collapsible card.
- Grok runs a child session without announcing it; the card takes the title of
  the parent's running spawn call and is marked finished when the turn ends.
- Kimi reports delegation as one tool call with streamed updates.

## Persistence

The pane kind is stored in SwiftData as a raw string, so adding it needed no
schema migration. The selected agent and each agent's ACP session ID live in
UUID-keyed `UserDefaults`, like terminal fast commands, and are removed when
the pane is deleted. When the agent supports `session/load`, reopening a pane
replays the previous conversation; otherwise a new session starts and the pane
says so.

## Known gaps

- Agents are stopped when their pane is deleted. On quit, closing stdin is what
  ends them; adapters exit on EOF.
- Slash commands, model switching, and session modes are not exposed yet.
- Kimi's cache figures exist only in its local session logs and are not read.
- Markdown rendering covers inline styles and fenced code blocks only.
