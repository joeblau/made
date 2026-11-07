# Cockpit AppKit design review

Reviewed November 5, 2026, using `b:zandesign`, adapted to native macOS. Scope: the Cockpit presentation in `Sources/Pilot`, shared glass metrics, and its native test fixtures. This is a review of the current migration checkout; the recommendations below are not an assertion that every item has been implemented.

## Verdict

AppKit can retain the modern Liquid Glass appearance: the native split view, toolbar groups, glass controls, and PaperKit picker already supply the right foundation. The consistency follow-up addresses excessive content height and card treatment, narrow-window clipping, and the appearance/contrast defects recorded below. Shared typography roles and zoom-aware workspace creation are implemented. Physical-device, compositor, and broader live-performance acceptance checks retain the limits documented below. Keep glass on navigation and controls, make the working content crisp and compact, and preserve the existing native view reuse and lifecycle boundaries.

## Findings

Severity follows the skill catalog; P0 here means a blocking usability finding for the affected surface, not a crash or security incident.

| ID | Check | Where | Finding | Concrete fix |
| --- | --- | --- | --- | --- |
| F01 · Resolved | TYPE-3 | `AgenticUse/AgenticUseProviderBreakdown.swift:45`, `AgenticUse/AgenticUseTopModels.swift:142`; `agentic-use-1440-light.png` | Provider colors are also used for small text. Approximate screenshot contrast is 1.81:1 for green and 1.88:1 for orange against the light card, below 4.5:1. | Use semantic label colors for names/numbers; retain provider color in a dot, bar, or sparkline. |
| F02 · Resolved | FORM-1 | `RemoteDesktopView.swift`, `showForm(error:)` | Username and password previously had only placeholders and accessibility names. | Added persistent labels with a 4 pt label-to-field gap and a 12 pt gap between groups; removed redundant placeholders. |
| F03 · Resolved | COL-2 | `RemoteDesktopView.swift:156`, `RemoteDesktopView.swift:340`; `remote-desktop-1440-light.png` | The empty remote screen retains a dark layer fill when the window changes to light appearance; its text changes to black. | Resolve layer colors under the view's effective appearance on attachment and appearance changes. |
| F04 · Resolved | LAY-6 | `NotesView.swift:649`; `notes-1000-light.png` and `notes-1000-dark.png` | The overflowing tab strip clips the bottom of tabs and the new-note control. The scroller needs space that the fixed tab viewport does not reserve. | Measure the scroll-view frame height from its required content height and scroller style; keep New Note outside the scrolling document. |
| F05 · Resolved | HIER-1 | `AgenticUse/AgenticUseKPICards.swift:29`; `agentic-use-1000-dark.png` | Five 140 pt KPI cards become two tall rows in a narrower window, delaying the main chart and model detail. The supplied SwiftUI reference is much denser. | Introduce a compact 96 pt KPI layout with a 22 pt value, 12 pt inset, and delta/caption on one line; wrap columns when values would truncate. |
| F06 · Resolved | LAY-1 | `PullRequestListView.swift:482`, `Docker/DockerView.swift:285`; `workspace-1440-dark.png`, `docker-1440-dark.png` | Each inspector item and container is a large filled card, making ordinary lists visually heavy. Inspector rows reserve 88 pt even for short text. | Keep the native tables; use content-sized, approximately 60–64 pt inspector rows and 56 pt container rows. Reserve strong fill for selection/hover, retaining group headings and status symbols. |
| F07 · Resolved | LAY-6 | `AgenticUse/AgenticUseView.swift:350`, `AgenticUse/AgenticUseTopModels.swift:93` | The two-column dashboard begins at 1,080 pt, where the model card can be narrower than its compact table. Horizontal scrolling is then needed despite the surrounding desktop layout. | Derive the two-column breakpoint from both cards' minimum useful widths and use the same calculation for height and layout. |
| F08 · Resolved | TYPE-4 | `UIZoom.swift:108`, `NewWorkspaceSheet.swift:30`, `NativeSettingsSupport.swift:5` | Zoom is centralized, but typography roles are not. Multiple helpers accept arbitrary sizes, and some dialog fonts bypass zoom. | Add named `body`, `caption`, `sectionTitle`, `windowTitle`, and `metric` roles to `CockpitTypography`; keep system control sizes where AppKit owns the control geometry. [Source](https://x.com/zander_supafast/status/1803372068186083545). |

### F01 — Keep chart colors separate from text colors

**Implemented in the consistency follow-up.** Provider and model text now use semantic label colors. Colored symbols, bars, and sparklines preserve the provider mapping; KPI deltas retain their direction indicators. Provider buttons are reused across data updates. The evidence below records the original finding.

Evidence: [light analytics](.build/design-review/agentic-use-1440-light.png), [measured samples](.build/design-review/contrast-samples.json). The embedded display ICC profile was converted to sRGB before measuring dominant text-interior colors against the card's `#E8E8E8` background. Green measured 1.81:1, orange 1.88:1, purple 3.40:1, blue 2.87:1, and red 2.90:1. These are approximate bitmap measurements, not a certification of the entire interface.

Small labels must remain legible independently of the chart palette. [TYPE-3 source](https://x.com/zander_supafast/status/1968252670604685678).

Minimal text fix, followed by a small provider-colored symbol next to the name:

```diff
 // AgenticUseProviderBreakdown.update
-button.contentTintColor = AgenticUseModelPalette.providerColor(for: entry.provider)
+button.contentTintColor = .labelColor
 // AgenticUseTopModels.configure
-cell.label.textColor = column == "provider" ? tint : .labelColor
+cell.label.textColor = .labelColor
```

Keep the existing palette for chart areas, sparklines and provider markers. Apply the same text/mark distinction to runner status labels and KPI deltas, then measure those surfaces separately.

### F02 — Label credentials persistently

**Implemented in the screenshot follow-up.** See [updated remote desktop](.build/header-ux-review/remote-desktop-1440-dark.png). The original evidence and recommendation below describe the issue before the fix.

Evidence: [remote desktop](.build/design-review/remote-desktop-1440-dark.png). A populated username looks like an unlabelled string; a saved password hides even its placeholder. Accessibility names are already present, but do not replace visible labels. [FORM-1 source](https://x.com/zander_supafast/status/1874759761180365226).

In `RemoteConnectionViewController.showForm`, replace the bare fields with labelled groups:

```swift
let usernameGroup = RRUI.stack([
    RRUI.label("Username (optional)", size: 12, weight: .medium), username,
], spacing: LiquidGlassMetrics.Spacing.xxSmall)
let passwordGroup = RRUI.stack([
    RRUI.label("Password", size: 12, weight: .medium), password,
], spacing: LiquidGlassMetrics.Spacing.xxSmall)
RRUI.fillWidth(usernameGroup)
RRUI.fillWidth(passwordGroup)
// Include these groups instead of `username, password` in the outer form.
```

Retain native secure entry, Return-to-connect, focus rings, and field accessibility labels. Put errors beside the credential groups and retain the existing Try Again action.

### F03 — Update layer colors when appearance changes

**Implemented in the consistency follow-up.** Empty remote-screen surfaces resolve their layer colors under the effective appearance on attachment and appearance changes. A regression check changes a retained window through light, dark, increased-contrast light, and light again. The evidence below records the original finding.

Evidence: compare the empty slot in [light](.build/design-review/remote-desktop-1440-light.png) and [dark](.build/design-review/remote-desktop-1440-dark.png). `RemoteDesktopDropView` is a plain `NSView`; its background and border `CGColor`s are assigned once while building the grid. The mode-switch sequence leaves the dark fill behind. This is supported by both source and capture, unlike the sidebar vibrancy capture limitation described below. [COL-2 source](https://x.com/zander_supafast/status/1875103802082382115).

Move the layer color assignments from the controller into the drop view and use the pattern already present in `CockpitCardView`:

```swift
override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshSurface()
}
override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refreshSurface()
}
private func refreshSurface() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
```

Call `refreshSurface()` after creating the layer too. Test light → dark → light without recreating the controller, including Increased Contrast.

### F04 — Give overflowing Notes tabs their full height

**Implemented in the consistency follow-up.** Notes reserves the native scrollbar height on overflow, keeps New Note outside the scrolling document, and reflows the controls and editor below it. Tests cover both scrollbar styles, 100%/200% zoom, and repeated wide/narrow resizing. The evidence below records the original finding.

Evidence: [1,000 pt Notes](.build/design-review/notes-1000-dark.png) versus [1,440 pt Notes](.build/design-review/notes-1440-dark.png). The tab document requires `tabHeight + 8`; the viewport has only `tabHeight + 10` before an always-visible horizontal scroller consumes height. Native scrollbars must fit as well as the tab content. [LAY-6 source](https://x.com/zander_supafast/status/1675855870356344838).

Calculate the frame with `NSScrollView.frameSize(forContentSize:horizontalScrollerClass:verticalScrollerClass:borderType:controlSize:scrollerStyle:)`, requesting the full tab document height and the actual scroller style. Derive the notice/editor positions from the resulting frame's `maxY`. Move the existing new-note button to a fixed trailing slot, and scroll the selected tab into view after selection. Verify both Overlay and Always scrollbar settings at 1× and enlarged UI zoom.

### F05 — Restore the dashboard's information density

**Implemented in the consistency follow-up.** KPI cards use a 96 pt layout and 22 pt metrics, with comparisons on one line. Column count accounts for measured metric widths, and sparklines use the remaining space. Text is measured with the actual display font rather than relying on stale field intrinsic sizes. The evidence below records the original finding.

Evidence: [narrow analytics](.build/design-review/agentic-use-1000-dark.png) and [wide analytics](.build/design-review/agentic-use-1440-dark.png). At 1,000 pt window width with the sidebar, the KPI region alone uses 288 pt before the chart. This competes with the actual usage analysis. [HIER-1 source](https://x.com/zander_supafast/status/1802939950645584131).

Introduce shared dashboard density values: `kpiHeight = 96`, `kpiValueSize = 22`, `kpiInset = 12`, `sectionGap = 8`, all respecting the existing zoom factor. Apply the height in both `preferredHeight` and card placement; redesign the card's internal layout at the same time so text is not simply cropped. Keep the existing native segmented controls and graph hit testing. Keep the row wrap for genuinely narrow widths; do not squeeze five values until they truncate.

### F06 — Use quieter native list rows

**Implemented in the consistency follow-up.** Inspector rows start at 64 pt and grow for wrapped titles/metadata; Docker rows use 56 pt. Repeated card fills are removed, retaining native selection, status marks, actions, and row reuse. The evidence below records the original finding.

Evidence: [inspector](.build/design-review/workspace-1440-dark.png) and [containers](.build/design-review/docker-1440-dark.png). The repeated large fills do little to explain grouping and consume most of the visible inspector. [LAY-1 source](https://x.com/zander_supafast/status/2084623671444799847).

Give `InspectorRepositoryListView` a row-height calculation based on the title and visible metadata, with a 60–64 pt compact target and room for longer titles. Rework container-row insets around a 56 pt target; preserve a larger height for content that needs it. Use the existing `NSTableRowView` selection background and hover affordance, plus spacing between Compose groups. Keep status text/icons and context actions visible. No table-to-stack replacement is needed; cell reuse remains intact.

### F07 — Size dashboard columns from the content they must hold

**Implemented in the consistency follow-up.** A shared layout decision uses the model table's minimum width, including native column spacing and the legacy scrollbar gutter. The model column reserves that gutter before native tiling, avoiding a scrollbar feedback loop. Tests cover 85%/100%/200% zoom and both scrollbar styles. The evidence below records the original finding.

The compact model columns total 485 pt, plus 56 pt of intercell spacing; the enclosing card adds 24 pt. At the current two-column threshold, each card can be only 528 pt wide. This issue is confirmed by the layout arithmetic and the horizontal scrollbar in the supplied running-app screenshot; the 1,000/1,440 pt capture matrix does not sample the exact threshold. [LAY-6 source](https://x.com/zander_supafast/status/1673619316208549889).

Replace the duplicated `width >= 1080 * zoom` check with a single helper used by both sizing and placement:

```swift
private func usesTwoColumns(for width: CGFloat) -> Bool {
    let minimumModelsCardWidth = (485 + 56 + 24) * AgenticUseLayout.zoom
    return (width - 24) / 2 >= minimumModelsCardWidth
}
```

Also account for a non-overlay vertical scroller when calculating the final minimum. Preserve native column navigation and full model names in tooltips. If a denser layout is desired later, move optional trend/rate information into a detail view rather than clipping numeric values.

## Systemic recommendations

1. **Keep the native glass boundary.** `NSToolbar`, `NSSplitViewItem(sidebarWithViewController:)`, `NSSplitViewItem(inspectorWithViewController:)`, `NSGlassEffectView`, and PaperKit supply the chrome. Keep document, terminal, chart and table surfaces opaque and readable. Avoid adding full-window blur layers to imitate the reference.
2. **Extend the existing tokens.** Build on `LiquidGlassMetrics` and `CockpitTypography`; introduce density and semantic type roles rather than a second theme system. Apply tokens to app-authored layout, not undocumented native control internals.
3. **Centralize appearance-aware surfaces and labelled fields.** The shared `CockpitCardView` already refreshes layer colors correctly. Reuse that approach in remote, runner and inspector surfaces. A reusable labelled-field wrapper can retain native focus and secure-entry behavior.
4. **Keep layout and data work separate.** Preserve native table/collection reuse, retained editors, model identity and visibility-scoped observation. Appearance changes should update colors/fonts and layout without restarting sessions, rescanning history, or replacing the editor.
5. **Use native motion and feedback.** Keep normal split-view collapse, native button states and sheet transitions. Do not add delays to tab/sidebar selection to make the app feel animated. The 100–500 ms waits used for screenshots and animation assertions remain test-only.

Verified clean in the sampled flows: explicit action labels and destructive confirmation wording (BTN-2/MODAL-1); native control feedback (BTN-5/FORM-4); restrained product motion (MOT-7); actionable remote empty state (MOT-6); consistent SF Symbols plus intentional platform/provider brand marks (IMG-1).

## Outside catalog — implemented fixes and engineering evidence

These are native macOS observations and fixes, not invented catalog checks.

- **Hidden-sidebar blur fixed.** The native animated hide reproduced a 180 pt stale left inset before any resize. The body used `NSBackgroundExtensionView` plus automatic split-item safe-area adjustment, allowing mirrored/blurred content to occupy that space. The body now uses a plain native host pinned to its safe area; the native sidebar and inspector retain their materials. The regression test checks both content edges immediately after hiding and again after resizing.
- **Drawing covers the full window.** The PaperKit overlay is retained by `CockpitWindowController` and placed above the window content's enclosing view. It covers the toolbar, sidebar, working content and inspector, follows window resizing, and is removed on Done/Escape or window close. It stays in the same window as the content so it belongs to that window's capture. Tests verify bounds, PaperKit canvas size, and hit testing in all three chrome regions.
- **Toolbar placement has a width tradeoff.** Keeping the launcher group and annotation control on the inspector side currently reserves at least 440 pt for that column. At narrower widths this reduces working area. Treat a future compact toolbar/overflow treatment as a deliberate design decision, with the inspector toggle always reachable.
- **AppKit is preserved.** The presentation boundary check covers 249 Pilot Swift sources and finds no app-owned SwiftUI imports/hosting views. Native AppKit controls may use Apple's own internal hosting implementation; that is outside the app's presentation boundary.
- **Performance evidence has limits.** The existing [panel benchmark](../docs/benchmarks/cockpit-appkit.md) records faster resize/layout in all nine measured AppKit fixtures, but mixed construction costs and outstanding Notes/Usage/Actions concerns. The later consistency follow-up repeated the optimized comparison and found mixed, noisy results; it does not claim a whole-app speedup. The [migration contract](../docs/appkit-migration.md) still governs launch, input latency, streaming, hidden sessions and GPU profiling.

## Coverage and reproduction

### Screenshot follow-up: terminal, Runners, and Remote Desktop

- Pane headers now put the title and status on one line, using 28 pt at default zoom. Narrow panes keep the close/hide actions visible and expose hidden metadata through tooltips and accessibility help. A minimum header height preserves the buttons at reduced text size.
- Runners source tabs and Remote Desktop groups share a native scrolling row. Scrollbars hide when the controls fit; overflowing rows reserve the height required by the current macOS scrollbar style. All actions remain reachable by scrolling, including after resizing.
- Remote credentials have persistent labels, one connection title per card, and a vertical scrollbar only when needed. The native secure text field and connection actions remain intact.

Updated fixture captures: [terminal](.build/header-ux-review/workspace-1440-dark.png), [Runners](.build/header-ux-review/runners-1440-dark.png), [Remote Desktop](.build/header-ux-review/remote-desktop-1440-dark.png). These have the same compositor limitations as the original captures below. Regression checks cover wide → narrow → wide transitions, both native scrollbar styles, and access to the remote Connect button in compact cards.

Follow-up validation: full Pilot suite with refreshed captures **1,049 passed, 0 failed, 3 intentional opt-in skips** (`Test-PilotTests-2026.11.05_21-12-36--0800.xcresult`). Pane header checks include 85%, 100%, and 200% zoom. Swift lint: **0 violations across 457 files**. AppKit presentation boundary and whitespace checks passed.

### Consistency and interaction follow-up

The shared content transition now covers sidebar pages, pane mode changes, inspector tabs, agent selection, usage ranges, and chart controls. It uses a short native layer animation on the incoming view, without retaining bitmap snapshots or delaying model/focus updates. Repeated transitions replace one animation, and Reduce Motion disables it. The inspector itself retains the native split-view animator.

Analytics observation no longer renders twice for one change. Model-table layout updates geometry and zoom-dependent fonts without reformatting every visible value or rebuilding trend data. Provider buttons survive snapshot updates. Metric glyph measurements are cached until their values or zoom change. Agent selection renders immediately, while streaming transcript updates still coalesce; explicit renders cancel pending redundant refreshes. Each window also retains its folder index between New Workspace sheets while refreshing it in the background on the next opening.

Updated captures: [analytics](.build/polish-review/agentic-use-1440-light.png), [Notes](.build/polish-review/notes-1000-dark.png), [inspector](.build/polish-review/workspace-1440-dark.png), [Docker](.build/polish-review/docker-1440-light.png), and [Remote Desktop](.build/polish-review/remote-desktop-1440-light.png). The capture matrix contains 26 images and retains the compositor limitations below. A visual pass caught stale intrinsic text widths in the compact metric labels; their geometry now uses measured glyph widths plus native field padding.

Validation: full Pilot suite with refreshed captures **1,059 passed, 0 failed, 3 intentional opt-in skips** (`Test-PilotTests-2026.11.05_22-12-49--0800.xcresult`). Swift lint: **0 violations across 457 files**. AppKit boundary and whitespace checks passed. The hosted UI fixtures now explicitly drive visibility and wait for scan/sheet state instead of requiring the test app to remain frontmost.

The typography follow-up adds shared body, caption, section-title, window-title and metric roles, adopted by workspace creation, settings headings and analytics values. New Workspace measures its controls instead of using fixed dialog heights; empty search stays compact, results size to their rows within a bounded viewport, and live zoom preserves the query and selection. Native alert controls keep system metrics.

The pane initialization follow-up resolves slot geometry before attaching native content, keeps hidden headers out of zero-sized layouts, and removes an erroneous autoresizing constraint from scrolling tab stacks. Pane layout now caches model geometry between renders. This fixes a reproduced SwiftData crash when a closing window's split animation outlives the workspace context, and avoids reading models on every animation frame. Browser and Android mode changes also use the shared transition when they reuse a controller.

Focused validation: **37 passed, 0 failed**, with **zero constraint conflicts** in exported runtime diagnostics. Coverage includes the New Workspace sheet at 85%, 100% and 200%, search/selection/Create, all native window tests, pane lifecycle tests, and a new regression that lays out a retired workspace after its persisted model is deleted. [Workspace captures](.build/workspace-polish-review/) retain the compositor limitations below; screen-capture permission is unavailable in this session.

Final functional validation: **1,063 passed, 0 failed, 4 intentional opt-in skips** (`Test-PilotTests-2026.11.05_23-26-08--0800.xcresult`), with 26 refreshed [review captures](.build/polish-final-review/) and **zero Auto Layout constraint conflicts** in exported diagnostics. Sidebar rows now update only when their displayed content changes; visited inspector tabs and global pages retain their native views and constraints. Hidden pages relinquish keyboard focus and pause their existing lifecycle work. Regression checks retain drafts, selections, renamed workspace labels, and inspector rows across navigation. The [repeated performance evidence](../docs/benchmarks/cockpit-appkit.md) distinguishes measured synchronous action work from unmeasured end-to-end display latency.

### Inspector animation and tool-pane follow-up

The inspector toggle now uses the native split-item animator. Repeated observation refreshes leave an in-progress transition alone, while initial/restored layout and Reduce Motion use immediate layout. A regression test records intermediate content widths on opening and closing and confirms the inspector controller is reused.

The six toolbar launchers open their category directly. New Terminal, Browser, Apple, and Android panes now present a one-time opening choice. After choosing Raw / Agentic Terminal, Safari / Chrome, or Simulator / Device, the chooser disappears and the content takes the full space beneath its header. Existing and restored panes use their saved kind, browser engine, or Android target. Opening choices start no session until selection; explicit menu choices bypass the chooser. Chrome retains the existing Chromium-runtime availability gate. The separate Agent Chat launcher is removed; provider choice remains inside the chat view.

The pane cache retains both terminal modes so switching preserves input and session state. Mode changes preserve repository context, and deletion cleans up every mode's runtime. Android target choice is stored with the pane. These changes continue to use AppKit controllers and native controls.

Local-server rows now fill the available width, keep shortcuts/status aligned, truncate long names, and use compact spacing. Device pickers use a shared compact header with trailing refresh and wireless actions. The New Workspace sheet starts with a visible selected-folder card and compact actions; searching reveals the results area instead of leaving an empty list onscreen.

Updated fixture captures: [tool panes at 1,000 pt](.build/tool-ux-review/tool-panes-1000.png), [tool panes at 1,440 pt](.build/tool-ux-review/tool-panes-1440.png), [workspace sheet](.build/tool-ux-review/new-workspace-NSAppearanceNameDarkAqua.png), [search results](.build/tool-ux-review/new-workspace-results.png). Browser fixtures use isolated local package manifests; capture-device rows are fictional. View-hierarchy captures do not faithfully composite sheet materials or native default/cancel button text, so those controls are checked through bounds and native actions as well.

Validation: full Pilot suite **1,053 passed, 0 failed, 4 intentional opt-in skips** (`Test-PilotTests-2026.11.05_21-37-37--0800.xcresult`). Swift lint: **0 violations across 457 files**. The AppKit boundary check still covers 249 sources; whitespace checks passed. Live Chrome/device connections and final sheet compositor appearance were not exercised by these isolated fixtures.

### Original review matrix

Six primary surfaces were inspected in light/dark appearance at 1,000 and 1,440 pt window widths, with 960 pt height, using the production AppKit window/sidebar/toolbar and fictional data:

| Surface | 1,000 pt | 1,440 pt |
| --- | --- | --- |
| Workspace + Actions inspector | [Light](.build/design-review/workspace-1000-light.png) · [Dark](.build/design-review/workspace-1000-dark.png) | [Light](.build/design-review/workspace-1440-light.png) · [Dark](.build/design-review/workspace-1440-dark.png) |
| Notes | [Light](.build/design-review/notes-1000-light.png) · [Dark](.build/design-review/notes-1000-dark.png) | [Light](.build/design-review/notes-1440-light.png) · [Dark](.build/design-review/notes-1440-dark.png) |
| Remote Desktop | [Light](.build/design-review/remote-desktop-1000-light.png) · [Dark](.build/design-review/remote-desktop-1000-dark.png) | [Light](.build/design-review/remote-desktop-1440-light.png) · [Dark](.build/design-review/remote-desktop-1440-dark.png) |
| Docker | [Light](.build/design-review/docker-1000-light.png) · [Dark](.build/design-review/docker-1000-dark.png) | [Light](.build/design-review/docker-1440-light.png) · [Dark](.build/design-review/docker-1440-dark.png) |
| Agentic Use dashboard | [Light](.build/design-review/agentic-use-1000-light.png) · [Dark](.build/design-review/agentic-use-1000-dark.png) | [Light](.build/design-review/agentic-use-1440-light.png) · [Dark](.build/design-review/agentic-use-1440-dark.png) |
| Runners, Compact layout | [Light](.build/design-review/runners-1000-light.png) · [Dark](.build/design-review/runners-1000-dark.png) | [Light](.build/design-review/runners-1440-light.png) · [Dark](.build/design-review/runners-1440-dark.png) |

Additional static coverage: shared button/input/card/sheet helpers, settings forms, typography/zoom, glass accessibility fallbacks, chat provider selection, loading/error/empty branches and destructive alerts. Desktop control conventions were retained; mobile checkout, hero imagery and decorative entrance-motion checks were not applied to this developer app.

Flows exercised with fixture state and native actions:

- Workspace selection → inspector toggle → sidebar hide → resize → annotate → Escape/close. Bounds and input routing were checked with the real PaperKit controller.
- Notes creation → text entry/save → Delete Note sheet → Cancel in both appearances → confirmed deletion. Only the newly created in-memory fixture note was deleted. Native sheet labels and action results were asserted; the sheet bitmaps were unusable because of compositor capture limitations.
- Docker filtering/selection → restart → request removal → leave the surface. The injected engine received one restart; removal remained pending until confirmation and was cancelled when the surface hid. Chat tests additionally exercise provider switching with a retained draft and keyboard submission/composition behavior.

**Capture limitations:** these are `cacheDisplay` view-hierarchy captures. They flatten native glass/vibrancy and render sidebar selection as a black area; that artifact is not evidence of a live sidebar color defect. Native sheet materials and SceneKit/Metal content are not faithfully captured. Runners therefore uses Compact layout. Terminal contents are a fictional fixture, and Agentic Use mounts the production dashboard with fixture history while excluding the live scanner/header. Remote connection and editing controls are intentionally disabled in isolated captures. Live terminal/browser/VNC rendering, active-window glass composition, VoiceOver, all zoom levels and the 760 pt minimum width still require their own checks. Screenshots are ignored scratch artifacts in `.build/design-review`, not committed app assets.

Capture and flow run: `LandingSnapshotTests/testNativeDesignReviewScreenshots`, passed. Focused window/canvas checks: 24 passed. Full `apple/bin/test.sh pilot`: **1,046 passed, 0 failed, 4 intentional opt-in skips** (`Test-PilotTests-2026.11.05_20-55-52--0800.xcresult`). Swift lint: **0 violations across 457 files**. UI boundary and `git diff --check`: passed.

To regenerate the capture matrix from the repository root:

```sh
source apple/bin/lib/xcodebuild-ci.sh
TEST_RUNNER_MADE_NATIVE_REVIEW_OUTPUT="$PWD/apple/.build/design-review" \
  ci_xcodebuild test "$MACOS_DERIVED_DATA" -scheme PilotTests \
  -destination "$MACOS_DESTINATION" \
  -only-testing:PilotTests/LandingSnapshotTests/testNativeDesignReviewScreenshots
```


### November 6 opening-choice and analytics follow-up

The permanent mode-selector row is removed from working panes. Temporary opening
state follows pane UUIDs, surviving SwiftData model recreation between toolbar
actions and rendering, and is pruned with live pane membership. The chosen mode
uses the existing persisted fields; no schema migration is needed. The browser
now explicitly stops observation and queued callbacks on pane closure, avoiding
a reproduced zoom callback into a model whose context has expired.

The provider-model popover uses a fitted native table without a nested scroll
view. Its text columns account for formatted values. Larger model lists use
Previous/Next controls to remain accessible within the available screen height.
Token Flow also has no nested scroll view: all three node columns fit the card,
and narrow model nodes put their token count on a second line with enough card
height for the full graph.

Provider, metric, and date-range controls replay both the daily chart and
Token Flow through a short native Core Animation reveal after their current
data and layout are ready. Repeated input replaces
the current reveal, resizing clears its mask, and Reduce Motion skips it.
The underlying views, focus, chart interactions, and cached data stay intact.

Validation: full Pilot suite **1,069 passed, 0 failed, 4 opt-in skips**
(`Test-PilotTests-2026.11.06_05-38-55--0800.xcresult`), with **zero Auto Layout
conflicts** in exported diagnostics. Swift lint reports **0 violations across
457 files**; the 249-source AppKit boundary and whitespace checks pass.
Regression coverage includes saved opening choices, session creation only after
selection, reclaimed pane space, closed-browser callbacks, fitted and paged
provider rows, Token Flow geometry at 320–1,200 pt and 85%/100%/200% zoom, and
replaying/clearing both chart animations through every filter path. The refreshed
[analytics review captures](.build/analytics-controls-review/) and
[tool-pane captures](.build/opening-choice-review/) retain the previously noted
WindowServer compositor limitations.
