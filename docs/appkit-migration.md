# Cockpit AppKit migration

The migration tracker is [#339](https://github.com/joeblau/made/issues/339).
The baseline is commit `513715f6fe218f11d3cf1829d038da0588931268`.
This document records the presentation boundary and verification contract.
The issues retain the implementation history; the release checklist below
retains outstanding verification after the implementation backlog is closed.
Closing implementation issues does not mark unverified release checks as passed.

## Presentation boundary

The `Pilot` application owns AppKit windows, controllers, menus, views and
native event routing. Existing terminal, browser, text, VNC, video and scene
engines remain reusable. SwiftData and Observation are model/service choices;
they do not require SwiftUI presentation.

SwiftUI remains in the WidgetKit extension and the iPhone, iPad and watch apps.
Their view sources must not be compiled into `Pilot`. Audit the generated
project's source membership rather than banning a shared directory or a
transitively linked system framework.

Run the source boundary check after generating the project:

```sh
apple/bin/install-xcodegen.sh generate --spec apple/project.yml --project apple
python3 apple/bin/check-cockpit-ui-boundary.py
```

The check reads `Pilot`'s actual Xcode sources phase and rejects SwiftUI/Charts
imports and explicit SwiftUI hosts. Runtime view-tree checks are also needed for
third-party presentation: the original code editor used a hosted find panel.
Passing the source scan alone does not establish runtime or feature parity.

`build-ci.sh` and the `pilot`/`all` lanes of `test.sh` run the source-membership
boundary check before compiling. CI regenerates the project and verifies that
checked-in source membership is in sync before running `build-ci.sh`.
Companion smoke coverage builds Pilot (including PilotWidgets), Copilot
(including CopilotWidgets and Wingman Watch App), and Plotter (including
PlotterWidgets), then runs SharedTests and PlotterTests through `test.sh shared`
and `test.sh plotter`. These builds preserve the separate SwiftUI apps and
extensions; paired-device Main/Extendo capture, ink, input, reconnect and deep
links still require recorded hardware validation.

## Ownership and lifetime

Application services own persistence, pairing, discovery, polling, capture,
terminal/agent connections and background work. Window controllers own
navigation, selection, toolbar state, responders and sheet presentation. Pane
controllers own attached view state; hiding a workspace must not implicitly
terminate a durable session.

Controller subscriptions and presentation-only timers stop when their owner is
disposed or inactive. Async results must be checked against the current request
or connection generation. Main and Extendo retain distinct pane runtime
identities and route remote input to the intended last-active surface.

## Baseline parity inventory

The frozen generated project compiled 237 Swift sources into `Pilot`.
The source audit found 73 files importing SwiftUI/Charts or constructing a
SwiftUI host, including five shared presentation/model files. The inventory
below covers those sources and the behavior they expose. It is a verification
map, not a declaration that every row has passed.

| Surface | Baseline source families | Required parity | Tasks |
| --- | --- | --- | --- |
| Application lifecycle | PilotApp, PilotAppDelegate | Startup/setup gating, single instance, CEF dispatch/shutdown, reopen, services, test isolation | #343–#345 |
| Shared presentation boundary | Shared SettingsView/LiquidGlassStyles/SecureIdentity, DashboardShared views | Shared models/settings keys preserved; widget views excluded from Pilot | #342, #378 |
| Visual primitives | GlassCompat, UIZoom, PilotAppearanceReporter, PreviewCanvasBackground, PilotEditorTheme | Appearance/accent, text sizing, zoom, control states, reduced effects | #346 |
| Main window/global modes | ContentView, SidebarSelection | Workspace, Notes, Remote Desktop, Docker, Agentic Use, Runners, empty states | #347 |
| Menus and responders | PilotCommands, ExtensionWindowView, ContentView shortcut controls | Native editing/IME, menu validation, contextual copy/screenshot, close, browser commands | #348 |
| Sidebar | WorkspaceSidebarList/Row/Drag, WorkspaceGroups, WorkspaceQuickJump | Pin/group/reorder, expansion, activity/gauges, quick jump, rename and selection | #349 |
| Sidebar footer/status | ContentView, AwakeSessionController | Device/audio/microphone detail popovers, Keep Awake switches/status/errors | #349 |
| Workspace dialogs | NewWorkspaceSheet, TextPromptSheet, DirectoryFinder | Create/import, root folder, rename/group, cancellation, close/save confirmation | #350 |
| Sessions and split panes | WorkspaceView, WorkspaceTabItem, WorkspaceStore, runtime registries | Retain sessions across detach, resize/collapse, move/drop, selection, teardown | #351–#352 |
| Extendo | ExtensionWindowView | Singleton window, independent runtime identity, inspector state, cross-window move and remote-input target | #353 |
| Toolbars/launchers | ContentView, WorkspacePaneLauncher, TerminalToolbarControls | Contextual controls, overflow, Local/Drone/engine selection, fast commands and capture actions | #354 |
| Terminals | GhosttyTerminal, DroneTerminalView, TerminalRuntimeCache | Metal host, tmux/remote attachment, keyboard/IME, mouse, drops, occlusion, resize | #355 |
| Editor | EditorPaneView, EditorDocumentSession, PilotEditorTheme, FileFinder | Quick open, actual native find/replace, syntax, undo, wrap, save/conflict safety | #356 |
| Notes | NotesView/NotesEditorTextView, MarkdownImagePreview, NotesGutter | Tabs, source editing, formatting, image/copy/masking interactions, caret/undo | #357 |
| Browser engines | WebKitBrowserView, ChromiumBrowserView, WalletPopupPanel | Native engine/profile lifetime, downloads, failures, DevTools, extension/popup anchoring | #358 |
| Browser presentation | BrowserPaneView/StartPage/ToolbarControls/FaviconView/FindInPage/JavaScriptDialog | URL editing, local servers, find, prompts, navigation, annotation and data reset | #359 |
| Physical devices/AirPlay | DevicePaneView, WirelessDeviceSession, DeviceCaptureRegistry | Choose/connect/recover, capture/record/screenshot, native layer and permissions | #360 |
| Simulators | SimulatorPaneView and session/framebuffer | Select/boot/stream, input mapping, screenshots/recording, shutdown/recovery | #361 |
| Android | AndroidPaneView and device/stream services | Device/emulator selection, input, stream, reconnect, screenshots/recording | #362 |
| Remote Desktop | RemoteDesktopView/Viewer and groups/session/input | Browse/connect/password, groups, VNC keyboard/mouse/clipboard, recovery | #363 |
| Ink | InkOverlay and BrowserAnnotate | Drawing/passthrough, undo/clear, normalization, Main/Extendo and remote ink | #364 |
| Inspector | PullRequestListView, GitHubTasksStore | Tasks, PRs, Actions, links/actions/refresh, native tab state, selected repository | #365 |
| Provider usage | UsageInspectorView/UsageSettingsView | Plan/credit data, countdowns, auth/enablement, errors, settings links | #366 |
| Agentic Use | AgenticUse views, DailyChart/Sparkline/TokenFlow/TopModels/KPIs/Insights/ProviderBreakdown/ModelPalette | All metric/data semantics, native charts/interaction, filtering, accessible alternatives | #367 |
| Docker | DockerView, DockerContainer, DockerStore | Compose/container states/actions, confirmations, endpoint errors, targeted refresh | #368 |
| Runners | RunnersView, RunnerFleetView/Scene/Layout | Scope settings, list/3D selection, state, popovers, visibility-aware rendering | #369 |
| Drones | DroneSettingsView and registry | Discovery/manual pairing, verification, rename/revoke/retry, destination identity | #370 |
| Agent chat | AgentChatPaneView and session/transcript | Streaming text/code, composer, tool/subagent details, approvals, setup/errors, scrolling | #371 |
| Settings | PilotSettingsView, CheckForSoftwareUpdatesView, ChromiumDiagnosticsSettings, shared SettingsView | Search/section links, identity, updates, setup, diagnostics and safe profile reset | #372 |
| Setup | SetupView and progress/permission/tool services | Welcome/permissions/tools/ready, skip/reopen, companion opt-in, native keyboard flow | #373 |
| Messaging/pairing | SecureMessagingView, PilotApp pairing alerts | Messaging statuses, verification/approve/reject, exactly-once resolution | #374 |
| Companion integrations | PilotApp, PilotWalkieDelivery, ScreenMirror, DashboardPublisher, BuildPushCoordinator | Remote input/capture/ink, appearance, build follow, widgets/deep links | #375 |
| Cross-feature validation | All native controllers | VoiceOver/keyboard/IME, appearance/zoom/displays, resource and data preservation | #376–#380 |

The original screenshot catalog has fourteen scenes in both appearances:
workspace, editor, browser, notes, remote-desktop, docker, agentic-use, runners,
actions, tasks, pull-requests, files, usage and device. Its engine/device previews
are fictional stand-ins; their images never prove live engine behavior.

## Measurement scope

`apple/bin/benchmark-cockpit-presentation.py` runs an opt-in hosted test with
in-memory stores, isolated preferences and injected services. It records panel
mount/layout time, repeated width-change layout time, and the host's resident
memory after each sample. The optimized configuration is Debug with `-O` and
whole-module compilation, keeping the existing hosted-test isolation contract.
Use the same configuration, hardware, OS, Xcode and workload for both versions.

The harness excludes deliberate settling delays from timing. It does not
measure full application launch, interactive input latency, frame rendering,
energy, live terminal/browser/video, or Chromium's process tree. Resident memory
is a host observation, not per-view allocated bytes. See the benchmark report
for actual results and remaining measurements.

Before considering performance acceptance:

- Repeat isolated runs with other builds/profilers idle; retain raw samples and
  report median, p95 and variance.
- Investigate mount/layout p95 regressions exceeding 15% on a reproducible
  workload before accepting the new UI. Small sub-millisecond changes and noisy
  samples require a longer run, not a claim of a speedup.
- Use Instruments separately for actual launch, event-to-display hitches, UI
  work during streaming, rendering/energy, and retained-resource growth.
- Verify lifecycle stress with running terminal/browser/capture sessions and
  confirm the existing Chromium budgets independently.
- Record physical device, companion, Drone, display and accessibility checks
  honestly; fixture success cannot substitute for them.

## Completion evidence

Release acceptance remains incomplete while any parity row lacks its behavioral
checks, any app-owned/third-party SwiftUI presentation remains, or required
builds and upgrade checks fail. The tracker must be updated from observed
results rather than from the presence of replacement files.

### Verification record — 2026-11-05

The implementation replaces Cockpit's application entry point, native windows,
menus, pane controllers, all feature presentation, auxiliary windows and
snapshot infrastructure. The generated Pilot sources phase contains 249 Swift
files and passes the AppKit boundary check. The editor dependency is a local
adaptation of pinned CodeEditSourceEditor 0.15.2; its provenance, license and
native presentation changes are documented in
[UPSTREAM.md](../apple/Packages/CodeEditSourceEditor/UPSTREAM.md).

The affected companion lane passed on Xcode 27.2: Copilot (including widgets
and the Wingman watch app) and Plotter (including widgets) built for iOS
Simulator. SharedTests passed 256 tests (286 parameterized executions), and
PlotterTests passed 4 tests (6 executions), with no failures, skips or runtime
warnings. DroneTools built and DroneTests passed all 8 tests, including the
protocol, lifecycle, jobs, PTY, tools and encrypted worker proofs. These results
validate the shared code and automated contracts; they do not replace pairing
and streaming with physical companions.

The migration-only review checkout also passes strict Swift lint, icon
validation, CI-script orchestration tests, documentation checks and the source
boundary audit. It excludes concurrent icon artwork changes from a separate
task. The universal arm64/x86_64 Release build passed. Both the standard
Debug (`-Onone`) and optimized Debug (`-O`, whole-module) macOS suites passed
1,041 tests (1,134 parameterized executions), with zero failures or runtime
warnings. Their three intentional skips are the opt-in
Chromium real-engine, screenshot-export and presentation-benchmark tests;
those run through their dedicated gates rather than silently exercising live
services in the default suite.

Signed Chromium real-engine tests passed on arm64 and on x86_64 under Rosetta
(one test each, no failures or skips), including the existing pinned budgets.
Both reported a CEF worker-thread QoS priority-inversion warning during
shutdown; exported stacks contain CEF/pthread frames rather than Pilot/AppKit
frames. The warning remains recorded and was not suppressed.

A clean universal Chromium build passed from the isolated review checkout.
Release archive validation is **not passed**: the strict validator rejected
extra application/team identity entitlements injected by Development signing.
The subsequent Manual Developer ID build requires matching Pilot and
PilotWidgets provisioning profiles that are not installed locally. The
reviewed entitlements and validator remain unchanged. Complete this gate in
the provisioned release environment; notarization and publication were not
attempted.

All fourteen fixture scenes were exported and visually inspected in light
and dark, along with the actual native Notes window. No blocking clipping,
missing content or unreadable controls were found. Engine/device fixtures
remain stand-ins and do not establish live-session parity.

Three optimized native benchmark runs retain 189 mount and 3,780 resize
samples, with matching source and product fingerprints. Resize medians are
45.7–94.5% lower across the nine fixtures, but initial construction is mixed.
Notes, Usage and Actions exceed the mount/layout p95 investigation threshold;
they remain unresolved performance concerns recorded in #379. See the
[complete comparison](benchmarks/cockpit-appkit.md) for the measurements,
fixture limitations and excluded contended attempts.

Implementation review is tracked in
[PR #384](https://github.com/joeblau/made/pull/384). It links all 41 child tasks;
merging the implementation and closing its task backlog do not mark remaining
release acceptance criteria as complete. Local result bundles and screenshots are retained under the
`/tmp/made-appkit-*` validation directories. The portable benchmark samples
and reproduction instructions are committed with the report.

## Release verification and rollout

The AppKit implementation is not a release approval. The following gates keep
the remaining work actionable. An unchecked item requires an evidence link or
a recorded owner and follow-up issue before the migration can be called
complete. Do not substitute fixture screenshots for the physical checks.
After the implementation backlog closes, the release maintainer owns the
unchecked items below; the linked historical tasks retain the original scope
and findings. Release publication still requires these gates to be reviewed.

- [x] Generate the project and pass the source boundary check against `Pilot`'s
  actual source membership. Run the full macOS suite, including native pane
  lifetime, editor find, browser prompts, notes, pairing, capture, inspector,
  runners, and snapshot hierarchy tests. Record commands, Xcode version and
  result bundles.
- [x] Pass the existing iPhone/iPad simulator and Drone test lanes, and build
  the widget/watch targets. Shared model, settings and protocol changes must
  preserve the companion apps' SwiftUI presentation.
- [x] Export all fourteen scenes in light and dark at the same dimensions.
  Inspect clipping, empty rows, chart labels, scrolling, contrast and selected
  state. Native macOS controls can use system compositing that a view bitmap
  does not capture; check affected controls in an actual fixture window and
  record that limitation alongside any image.
- [ ] Complete the Developer ID universal Chromium build with matching Pilot
  and PilotWidgets provisioning profiles, then pass the unchanged
  `apple/bin/validate-chromium-archive.sh` gate. Follow
  [the release signing process](apple-releases.md); a successful Development
  build and real-engine test do not substitute for the release entitlement
  policy. Record the retained CEF shutdown QoS warning with the candidate.
- [ ] Repeat optimized panel benchmarks with other builds idle; keep raw
  samples and compare against the frozen baseline on the same machine. Then
  separately profile full launch, rapid workspace switching, streaming chat,
  large analytics history, terminal resize, browser navigation and video
  capture in Instruments. Record p95 hitches, CPU, retained memory and energy,
  including Chromium helper processes. Investigate reproducible regressions
  using the measurement policy above.
- [ ] On a QA account, create workspaces, groups, pinned items, notes, browser
  profiles, settings and paired-device records with the previous build. Save
  a backup, upgrade to the candidate, and verify data, selection, identity and
  permissions survive launch and relaunch. Check unsaved editor rejection,
  interrupted saves and app quit. This is a disposable upgrade fixture, not
  the developer's personal application data.
- [ ] Exercise Main/Extendo transfer in both directions while terminal,
  browser, editor and capture panes are active. Switch workspaces, collapse,
  restore and close panes repeatedly; verify focus, local/remote input,
  exactly-once teardown and stable retained-resource counts.
- [ ] Verify wired iPhone capture, wireless AirPlay, iOS Simulator and Android
  device/emulator streaming, input, recording, screenshot and reconnect after
  disconnect. Record the device/OS/connection and permission state used.
- [ ] Verify Walkie voice/input, Kneeboard mirror/rotation/ink, Trigger
  gestures, widget deep links and background dashboard updates against the
  candidate. Pair and revoke a real Drone; confirm execution destinations and
  reconnect behavior remain correct.
- [ ] Verify keyboard-only navigation, menu validation, text selection,
  copy/paste, find, undo, IME composition and VoiceOver on every major surface.
  Check dark/light, accent changes, zoom, reduced transparency/motion, mixed
  display scales and moving windows between displays.
- [ ] Install the prior version again on the QA account and confirm the
  rollback procedure. If a restored backup is required, document exactly
  which data is restored and retain the candidate's newer data separately.
  Do not assume UI-only changes prove downgrade compatibility.

Prepare a candidate with its exact commit, build identifiers, evidence links,
known gaps and rollback instructions. Start with internal QA, then a small
opt-in cohort that uses terminal/browser/device/companion workflows daily.
Collect crash/hang reports and user-visible regressions before increasing the
cohort. Stop expansion for data loss, broken pairing or input routing, repeated
crashes, or a reproducible performance regression outside the accepted budget.
Release publication and installation on other people's machines remain a
separate maintainer action after these gates are reviewed.
