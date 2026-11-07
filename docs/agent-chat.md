# Agent Chat pane

Cockpit's **Agent Chat** pane drives a coding agent — Claude Code, Codex, Kimi
Code, or Grok Build — through a native chat UI instead of the agent's terminal
UI. It speaks the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP, v1): JSON-RPC 2.0, one message per line, over the agent's stdin/stdout.

Source: `apple/Sources/Pilot/AgentChat/`. Tests: `AgentChatTests`,
`AgentTranscriptTests`, `AgentToolVerbTests`, `AgentRedactionTests`,
`AgentActivityMachineTests`, `AgentTimelineTests`, and `AgentChatGalleryTests`.

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
- At most 32 permission requests queue; more are answered `cancelled` and
  leave no record. So are malformed requests: an id that is not a number or a
  string of at most 256 bytes, or no usable option. Only the first 16 options
  are kept.
- Each pane keeps at most 2,000 transcript items per session, dropping the
  oldest 10% at once when over (pending approvals are never dropped); the
  agent keeps the full history. At most 64 child sessions are rendered.
- Tool-call fields are bounded before they are kept: paths 4 KiB, names and
  ids 256 bytes, subjects 512 characters, error summaries 200 characters
  (redacted before they are clipped), 64 content blocks and 512 KiB of their
  text, 64 locations, 256 KiB per thought and per terminal-output buffer
  (newest bytes kept; the partial line at the cut is dropped so a secret cut
  in half cannot lose the key or prefix its redaction rule needs).
- Raw `rawInput`/`rawOutput` JSON is size-measured by an early-exit walk; over
  256 KiB only a bounded text prefix is kept. These per-step payloads share a
  64 MiB budget per pane; past it, the least recently written settled steps
  are evicted (running steps never are) and the Inspector says
  "Detail evicted".
- Writes to stdin use `F_SETNOSIGPIPE`, so an exited agent surfaces as a write
  error rather than a `SIGPIPE` that terminates Cockpit.

Cockpit advertises **no** `fs` or `terminal` client capabilities. Agents use
their own built-in file and shell tools under their own permission rules,
exactly as in their TUI; Cockpit never reads or writes files on an agent's
behalf. Requests for those methods are answered `Method not found`.

Permission requests are shown to the user and never auto-approved (see
[Approvals](#approvals)). Cancelling a turn first answers every open request
`cancelled`, as ACP requires.

Sign-in is never initiated from Cockpit. If an agent reports `auth_required`,
Cockpit completes only a silent method the agent itself marks as cached (Grok's
`cached_token`); otherwise the pane shows the CLI's login command to run in a
terminal. Cockpit never opens a browser or selects API-key auth, which could
change how the user is billed.

## Context, prompt caching, and usage

The agent owns the conversation. Cockpit sends only each new prompt
(`session/prompt`), so the agent builds every model request with its own prompt
caching, compaction, and context management. To keep caching intact, a pane
keeps one long-lived agent process per session, passes no extra MCP servers
(the agent keeps its configured ones, and with them its cacheable prompt
prefix), and adds nothing to the system prompt.

Usage appears in two places only: a disabled item at the end of the agent
menu's Conversation submenu ("Context 58.1k / 258.4k · Cache 97%") and the
Inspector's Meta tab for the run, which **Show Run Usage** in the Inspector's
Actions menu opens from any subject (never per step or per subagent: agents
report usage only for the root session). The composer shows no meter. Usage is normalized because agents disagree on what
`inputTokens` means: Grok's includes cache reads, Claude's and Codex's do not,
Codex reports no cache writes, and Kimi reports no per-turn usage over ACP
(only context size). These semantics were measured against Claude Code
2.1.318, Codex 0.166.0, Kimi Code 2.5.0, and Grok Build 1.0.70; re-verify
`ChatAgent.inputTokensIncludeCacheReads` when an agent changes its reporting.

In the Meta tab the meter reads `used / window · Cache NN% · cost`, labelled
"reported by <agent>". Tokens are reported per turn, never per step or per
subagent, because no agent reports per-tool or per-subagent usage. Step,
thought, and group subjects show the session's model.

## Transcript tiers

The transcript has three tiers of disclosure.

1. **Narrative**: user messages, agent prose, code and diff blocks, notices,
   and plan rows. Agent prose has no bubble, is selectable, and offers a
   hover-only **Copy** for the whole message plus one per fenced code block;
   ` ```diff ` fences are colored by `+`/`−` line. Only `http`, `https`, and
   `mailto` links survive. User messages are right-aligned bubbles with no copy
   control. Plans render as one `☰ Plan · 3/7 done` row at the latest position
   of their turn.
2. **Activity**: consecutive tool calls, reasoning, and subagents between two
   narrative rows fold into one activity card that streams while live and
   settles into a one-line receipt.
3. **Inspector**: a trailing drawer with the raw, redacted detail of one step,
   thought, agent, group, plan, or the whole run.

Raw commands never label a row in the thread. In the thread, copy controls
appear only on hover and only for prose, code blocks, and step commands.

## Activity cards

`AgentTimeline.project` folds the root transcript into rows. Approval records
and plan updates do not split a group. Consecutive subagents inside a group
become one roster. Decided approval records render after the group holding
their tool call.

The collapsed header reads
`{summary} · {n} steps · {k} failed · {n} stopped · {duration}`, for example
`Explored files · 9 steps · 1 failed · 42s`. The summary truncates first,
then the step count; the failed count (drawn in the failure color), stopped
count, and duration never do. The summary comes from the dominant kind of step: reads and searches
give "Explored files" (or the repository name when one is supplied), edits
"Edited files", commands "Ran commands", fetches and web searches
"Researched", and subagents "Coordinated agents". When no single kind covers at
least half the steps, the summary is "Worked".

Weight scales with size:

- A settled group of at most three rows with no failures, subagents, or
  pending approval renders inline without card chrome.
- A live group past 15 rows shows its last 6 under "N earlier".
- An expanded settled group past 15 rows shows its first 2 and last 2 around
  "Show N more".
- A collapsed group still lists its failed steps and failed agents beneath
  the header; past 6, the older ones fold into "N earlier failures".

### State machine

Each card's state is `idle → live → settling → settled`, computed by the pure
`AgentActivityMachine` from typed events: `stepStart`, `stepEnd`, `stepFail`,
`agentSpawn`, `agentEnd`, `reasoningDelta`, and `reasoningEnd`. The projection
rebuilds every group's inputs from the transcript on each render, so no live
event can be lost.

- Any start event (`stepStart`, `agentSpawn`, `reasoningDelta`) makes the
  group live, including a late start after it settled.
- A live group starts settling once it is closed (a narrative row follows it,
  or the turn ended) and nothing in it is running.
- A settling group becomes settled when the view acknowledges that the 0.18 s
  ease-out collapse animation finished. Under Reduce Motion, in a hidden
  window, or for an inline group, the acknowledgement is immediate.
- Replayed history is always settled.

Collapse is never driven by a timer or the scroll position. Live and idle
cards are expanded; settling and settled cards are collapsed. A user's
disclosure toggle overrides that for the group. While live, the card streams
the newest step at the bottom and shows a shimmer status line (static under
Reduce Motion, updated at most four times a second) with the elapsed time.

### Verbs and glyphs

`verbForTool` turns each call into a human verb with a 14 pt monochrome
vector glyph. It resolves the tool name first (ACP `name`, Claude's
`_meta.claudeCode.toolName`, or Grok's `_meta["x.ai/tool"].name`), then the
shape of `rawInput`, then title heuristics, then the ACP `kind`.

| Glyph | Example (settled) | While running |
|-------|-------------------|---------------|
| Command | `Ran git status` | `Running git status` |
| Read | `Read Package.swift`, `Read 3 files` (sub-line: two names `+N`) | `Reading …` |
| Search | `Searched "chain\|protocol" in hyperevm` | `Searching …` |
| Edit / Create | `Edited transport.ts (+42 −7)`, `Created notes.md` | `Editing …` / `Creating …` |
| Delete / Move | `Deleted old.swift`, `Moved a.swift` | `Deleting …` / `Moving …` |
| Fetch | `Fetched example.com/path` | `Fetching …` |
| Web search | `Searched the web for "…"` | `Searching the web …` |
| Plan | `Updated plan` | `Updating plan` |
| Agent | `Delegated: <description>` | `Delegating: …` |
| Tool server | `Used <server> · <tool>` (MCP) | `Using …` |
| Tool | `Used skill <name>`, `Compacted conversation`, `Switched mode` | |

An unknown tool falls back to its title, then its tool name, then "Tool
call", never raw JSON. "Thought" is reserved for reasoning. Edit line counts
are computed once, when a call completes, and omitted past 20,000 lines per
side or when a diff was truncated. Hovering a step shows the exact command or
arguments (redacted, with control and bidirectional characters escaped) in a
tooltip, plus a **Copy command** button that copies at most 64 Ki characters,
redacted. Clicking a step opens it in the Inspector. Each step also exposes
**Copy command**, **Open in Inspector**, and (when offered) **Ask to retry**
as accessibility actions.

### Failed, stopped, and rejected steps

Outcomes come from the ACP status plus Claude's
`_meta.claudeCode.nonExecutionKind`:

- **Failed**: `failed` status. Red status dot and inline error summary (the
  first meaningful line, at most 200 characters). Counted in `{k} failed`.
- **Stopped**: `interrupted` or `cancelled` (including ACP's `cancelled`
  status), or a call still running when the turn ended. Hollow gray dot,
  counted in `{n} stopped`, never as a failure.
- **Rejected**: `nonExecutionKind` of a rejection, a permission rule, or an
  auto mode decision. Counted as stopped.

When a turn ends, calls still running become stopped: `cancelled` when the
stop reason was `cancelled`, otherwise "not finished". Calls inside a subagent
the agent still reports running stay live (see [Subagents](#subagents)).
Durations are client receive times; replayed history has none.

## Reasoning

While the newest item of a running turn is an open thought, the card's live
line is the last complete sentence of that thought (Markdown stripped,
redacted, at most 80 characters). Otherwise it shows "Waiting for approval"
when a request is pending, then the running step's verb, then "Working…".
When the thought ends (at the next item in its session, a new message ID, or
the end of the turn), it settles into the card as `Thought for 12s`. Without
both times, for example in replayed history, it reads `Thought`.

Full reasoning text is only shown in the Inspector's **Reasoning** tab. It is
never copyable from the thread, and in the Inspector it is selectable only
when reasoning export is allowed (see [Inspector](#inspector)).

Cockpit does not enable Claude's thinking summaries; it does not set
`CLAUDE_CODE_THINKING_DISPLAY`. Claude Code sends no thought chunks by
default, so for Claude the live line normally shows the running step's verb
or "Working…" and never claims a thought.

## Subagents

Cockpit opts into ACP's subagents RFD (`clientCapabilities.subagents`):

- Claude and Codex announce each subagent with `subagent_update` and run it as
  a child session.
- Grok runs a child session without announcing it; its chip takes the title of
  the parent's running spawn call and ends when the turn ends.
- Kimi reports delegation as one tool call with streamed updates, which renders
  as a step.

Parallel subagents render as a roster: a wrapping row of chips
`{status dot} {name} · {steps}`, each at most 160 pt with tail truncation and a
tooltip giving the name, lifecycle, elapsed time, and step counts. Clicking a
chip opens that agent in the Inspector with its own nested activity card and
final prose. When no subagent is running, the roster collapses to
`{n} agents · {done} done · {failed} failed` (plus `{s} stopped` when any
were cancelled), and its chevron shows the chips again.

| Lifecycle | When | Dot |
|-----------|------|-----|
| queued | Announced, no work reported yet | Gray dashed ring |
| running | Reported running | Filled live color, pulsing (static under Reduce Motion) |
| done | Idle with a stop reason | Green check |
| ended | Idle without a stop reason | Green check |
| failed | Stop reason `error`, or an error reported | Red cross |
| cancelled | Stop reason `cancelled` | Hollow gray ring |
| background | Still reported running after the root turn ended | Half ring |

When the agent process exits or is shut down, every running or background
subagent ends as cancelled and its running steps and open reasoning close, so
nothing stays live for a process that is gone.

## Inspector

The Inspector is a trailing overlay drawer above the transcript. It does not
reflow the table, resizes from 240 pt to the smaller of 520 pt and 85% of the
pane, and slides in over 0.18 s (instantly under Reduce Motion). It is closed
by its close button or Esc, and by a click outside it when the pane is
narrower than 560 pt. While open, Tab cycles only among its own controls.

| Subject | Tabs | Opens on |
|---------|------|----------|
| Step | Input, Output, Meta | Output |
| Thought | Reasoning, Meta | Reasoning |
| Agent | Output (nested card and final prose), Reasoning when the child reasoned, Meta | Output |
| Plan | Output, Meta | Output |
| Group, run | Meta | Meta |

Meta lists the start, end, duration, tool, kind, status, exit code, locations,
edit counts, and model, plus group counts and member lines for a group.
Missing data is named rather than left blank: "No input reported by <agent>",
"No output reported by <agent>", "No reasoning reported by <agent>", or
"Detail evicted".

### Redaction

Every string that reaches a sink passes through `AgentOutputRedaction.swift`
first. The sinks are step labels, detail lines, tooltips, **Copy command**,
live status lines, error summaries, chip names and tooltips, approval
subjects and option names, accessibility labels and announcements, plan text,
Inspector text, every copy except **Copy Unredacted**, and every export.

The policy masks values with `••••` and leaves the rest in place:

- `Authorization` and `Proxy-Authorization` headers, `Bearer` tokens, `Cookie`
  and `Set-Cookie` headers, and the password in `scheme://user:password@host`.
- Prefixed tokens: Anthropic and OpenAI `sk-`, GitHub `ghp_`/`gho_`/`ghs_`/
  `ghu_`/`ghr_`/`github_pat_`, Slack `xox?-`, AWS `AKIA`/`ASIA`, Google `AIza`,
  GitLab `glpat-`, npm `npm_`, Stripe `sk_`/`rk_` live and test keys, and JWTs.
  Tokens of 16 characters or more may keep their known prefix as a hint.
- Values of secret-named keys in env, YAML, JSON, and CLI flags: any key
  named or ending in `password`, `passwd`, `secret`, `token`, `apikey`,
  `authorization`, or `cookie`, joined by `_`, `-`, `.`, or nothing
  (`accessToken`, `clientSecret`, `PGPASSWORD`); a `secret` segment anywhere
  (`SECRET_KEY_BASE`); any `*_key`, `*_pass`, or `*_pwd` behind a separator;
  `privateKey`, `accessKey`, and similar qualified keys; and `auth`, ignoring
  case. The key stays visible; numbers, booleans, `null`, and `$VAR`
  references are left alone.
- PEM and PGP private-key bodies (`-----BEGIN PGP PRIVATE KEY BLOCK-----`) and
  PuTTY `Private-Lines`; an unterminated `BEGIN` masks to the end of the text,
  and an `END` with no `BEGIN` before it masks everything before it.
- The whole content of files named `.env*`, `*.pem`, `id_rsa*`,
  `id_ed25519*`, `.netrc`, `.npmrc`, `.pgpass`, `.git-credentials`,
  `credentials*`, or `.docker/config.json`, at every sink: Inspector, exports,
  step tooltips, **Copy command**, and the approval card (where the raw input
  sits behind **Reveal secrets**).

JSON is redacted key by key and string by string before it is printed. Prose
and notices are masked only for known-secret shapes (prefixed tokens, bearer
tokens, Authorization headers, URL passwords, PEM keys), so a sentence such as
"the token is invalid" is untouched. Every quantifier is bounded, and text over
64 KiB is redacted off the main actor. A `redacted` chip appears whenever
something was masked.

Text is redacted before it is truncated, so a secret that straddles the cut
cannot leak its head. Inspector pages stop at 200 lines with a
`truncated · show all` chip, which re-redacts the full text without the limit.

### Copy and export

The Actions menu offers only what applies to the current subject:

- **Copy Input** and **Copy Output** copy the full redacted text.
- **Copy Unredacted** copies the raw text of the current Input or Output tab
  (or Reasoning, only when reasoning export is allowed). It also declares
  `org.nspasteboard.ConcealedType` so clipboard managers skip recording it.
- **Export Step JSON…** and **Export Run Trace JSON…** write redacted JSON.
- **Export Reasoning…** writes redacted plain text and appears only when
  reasoning export is allowed.
- **Ask to Continue…** appears for a failed agent.

Exports ask for a location first, suggesting a sanitized file name. Nothing is
written without a chosen URL, and the file is never opened. A run trace is
`{"schema": "cockpit.agent-chat.trace/1", "redacted": true, "reasoningIncluded": …, "agent": …, "items": […], "subagents": [{"childSessionID": …, "items": […]}]}`;
a step export carries the same `schema`, `redacted`, and `reasoningIncluded`
keys around one `step`. Each item has `key`, `session`, `turn`, `replayed`, and
`type` (`user`, `assistant`, `notice`, `thought`, `step`, `plan`, `agent`, or
`approval`) plus that type's fields. Unless reasoning is included, a thought
carries `"reasoningExcluded": true` instead of its text.

Reasoning export is off by default. Turn it on with:

```bash
defaults write app.blau.pilot agentChat.allowReasoningExport -bool true
```

The setting is read each time it is needed, so it takes effect without
relaunching.

## Controls

- **Stop** cancels the root turn (`session/cancel`) after answering every open
  permission request `cancelled`. Calls still running become stopped. Subagents
  the agent keeps running are shown as background rather than stopped.
- **Steer** is used only when the agent's `initialize` result advertises
  `_meta.steering.supported`. Text sent during a turn then goes to
  `_session/steering` with `_meta.steering.idleBehavior = "promptRequired"`,
  without attachments. The user bubble appears once the agent reports
  `injected`. A `promptRequired` answer queues the text while the turn runs,
  sends it at once if the turn already ended with `end_turn`, and otherwise
  returns it to the draft. A failure, an unrecognized outcome, or no answer
  within 15 seconds returns the text to the draft with an error.
- **Queue for next turn** applies to agents that do not advertise steering.
  Queued text fills one slot (later text is appended), can be edited or
  removed, and is sent only after the turn ends with stop reason `end_turn`.
  Any other ending returns it to the draft, as do stopping, restarting, or
  switching the agent and a closed connection.
- **Ask to retry…** (failed steps) and **Ask to continue…** (failed agents)
  only pre-fill the composer with a redacted request naming the step or agent.
  They never send, and never resume a tool call. Ask to retry is not offered
  for replayed, stopped, or rejected steps.
- **Send again** appears on the notice of a failed turn and resends the last
  prompt's text and attachments.

## Approvals

A pending request docks above the composer as an approval card for the head of
the queue, with "N more" when others wait. The card names the requesting agent
(the root agent, the subagent's title, or "untracked subagent"), and shows the
title, the requested action ("Run git push", never "Running" before it is
approved), and full command or arguments in a scrollable monospaced view.
Control and bidirectional characters are escaped so the input reads exactly as
it will run, and secrets are masked behind **Reveal secrets**.

- The card shows one button per option the agent sent, in the agent's order,
  with the agent's own names (single-line redacted). Cockpit keeps no
  allowlist and never answers on the user's behalf.
- Only the first option can be the default, and never when it is
  `allow_always`, an `exit-plan` option, or any option of a `switch_mode`
  request.
- The card never takes focus by itself. Return chooses the default only after
  the user focuses the card, and only for the request that was showing when it
  was focused.
- **Cancel Request** answers `cancelled`.

A decision is recorded only after the answer was written to a live connection.
The record stays in the timeline after its group as "Approved · <option>"
(allow options), "Rejected · <option>" (any other option), "Cancelled",
"Withdrawn by agent", or "Stopped", followed by the requested action
("Approved · Allow · Run git push origin main"); the raw request title is
only its tooltip. An agent can withdraw an open request with
`$/cancel_request`. The id must match exactly (a string never matches a
number), and Cockpit answers the withdrawn request with error `-32800`.
Stopping a turn, a closed connection, or a restart records open requests as
"Stopped".

## Keyboard

- In the composer, Return sends and Option-Return or Shift-Return inserts a
  newline. An input method's marked text keeps Return. While a turn runs,
  Return steers (when the agent advertises steering) or queues for the next
  turn instead of starting a new one.
- Cmd-. stops the running turn from the composer or the transcript. Esc closes
  the Inspector first; otherwise it stops a running turn only when the
  composer is empty, so a half-written steer is never lost.
- In the transcript, `j` and `k` move a step cursor (with a focus ring) over
  visible steps, collapsed cards, roster chips, and approval records; a
  collapsed card is one stop. Enter or Return opens the item under the cursor
  in the Inspector and `/` focuses the composer. Shift-Tab from the composer
  moves focus to the transcript, and clicking a row focuses the transcript
  and places the cursor there. The keys apply only while the transcript is
  first responder, so typing elsewhere is never intercepted.
- Approval cards never take focus automatically; see [Approvals](#approvals).
- In the Inspector, Esc closes the drawer and returns focus to where it was,
  and Tab and Shift-Tab cycle within the drawer.

## Persistence

The composer accepts photos and videos through its paperclip picker, paste,
or drag and drop. Removable thumbnail chips appear above the draft. Messages
can contain media without text. Images are downsampled to at most 2,048 pixels
and 1 MiB each before sending; up to eight attachments are allowed per message.
Source images are limited to 20 MiB and videos to 100 MiB. Decoding and copying
run off the UI thread, and invalid files leave the draft intact.

Images use ACP image content when the agent advertises image support. Otherwise,
images and videos use ACP resource links to pane-owned local copies; the agent's
tools and model determine which media it can analyze. Videos are not advertised
as native video prompt content. Copies live in Application Support under
`app.blau.pilot/ChatAttachments/<pane UUID>` and are removed when the pane is
deleted. Removing an unsent chip also removes its copy.

The model menu displays the active agent's advertised models, including grouped
options. It prefers `configOptions` with the `model` category and switches through
`session/set_config_option`; older adapters advertising `models.availableModels`
use `session/set_model`. A selection is shown only after acknowledgement or an
agent configuration update. Rejected changes preserve the previous model and
draft. Providers and conversation actions are separate submenus. Cockpit does
not maintain a hard-coded catalog or modify authentication to select a model.

The pane kind is stored in SwiftData as a raw string, so adding it needed no
schema migration. The selected agent and each agent's ACP session ID live in
UUID-keyed `UserDefaults`, like terminal fast commands, and are removed when
the pane is deleted. When the agent supports `session/load`, reopening a pane
replays the previous conversation; otherwise a new session starts and the pane
says so.

## Known gaps

- Agents are stopped when their pane is deleted. On quit, closing stdin is what
  ends them; adapters exit on EOF.
- Slash commands and session modes are not exposed yet.
- Kimi's cache figures exist only in its local session logs and are not read.
- Markdown rendering covers inline styles and fenced code blocks only.
