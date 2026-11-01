# Design review — made (blau.app web + Pilot/Walkie/Kneeboard apps)

## 2026-10-31 — App-wide cleanup and Liquid Glass (Cockpit, Walkie, Kneeboard, Trigger)

Scope: every app surface except Agentic Use and the 3D runner fleet scene, which
were changing in parallel (landed via #313) and get their glass pass next. Reviewed against the
zandesign catalog (React-targeted; applied to SwiftUI equivalents) in four
parallel slices: Cockpit window shell, Cockpit tool panes, Walkie + Trigger, and
Kneeboard + the widgets and Live Activities shared by all three apps.

### Liquid Glass direction

Glass is the control layer that floats above content: buttons, toggles,
segmented pickers, menus and pop-up buttons, toolbars, pane headers, floating
control clusters, and sheet action rows. Content — lists, cards, editors,
terminals, web pages, device screens — stays solid, and glass never stacks on
glass. Standard SwiftUI controls already render as glass on the 26 SDKs, so the
largest gains came from replacing hand-drawn controls with standard ones.
Buttons use secondary glass by default and prominent glass for the single
primary action per view (BTN-1). Cockpit keeps `#available` guards through
`GlassCompat.swift` (`compatGlassButtonStyle`, `compatGlassProminentButtonStyle`,
`compatGlassCapsule`, `compatFloatingGlass`) because its long-term floor is
macOS 15. Widgets and Live Activities use WidgetKit's accent and vibrant
rendering (`widgetAccentable`, `widgetAccentedRenderingMode`) instead of
custom glass.

### Bugs fixed along the way

- Kneeboard dashboard sheet: panels used `.background` on a grouped background
  and disappeared in dark mode (COL-2).
- Kneeboard "Searching for Cockpit": dark help text on the always-black mirror
  area in light mode (COL-2/TYPE-3).
- Medium dashboard widgets clipped their last row and footer; the small Runners
  widget wrapped "Offline".
- Cockpit tab close button hit area was white-on-white in light mode.
- Device/Simulator/Android overlay buttons rendered light-mode chrome on the
  always-dark device canvas.

### Findings by theme

| Theme | Checks | Representative fixes |
|---|---|---|
| Contrast | TYPE-3 | Informative `.tertiary` text (PR/task metadata, runner details, Docker empty state, quick-jump shortcut) → `.secondary`; colored caption text → tinted glyph + secondary text |
| Button hierarchy and labels | BTN-1, BTN-2, BTN-4, COL-4 | One prominent action per view across sheets, empty states, and device panes; "OK" → "Done"/"Dismiss"; red row icons and red Stop buttons → neutral, red kept for destructive confirmation |
| Confirmations | MODAL-1 | Verb + object titles: "Delete Note?", "Close Busy Terminal?", "Remove Container?", "Remove Connection?" with matching confirm verbs |
| Borders and containers | LAY-1, LAY-2, LAY-4 | Per-row dividers and card borders removed; boxed header above boxed cards removed; nested radii set to inner + padding |
| Hand-rolled controls | HIER-6 | Custom tab chips, word-wrap menu, settings search field, and Walkie tab switcher replaced with standard or glass controls |
| Type and spacing | TYPE-2, TYPE-4, LAY-3, LAY-5, FORM-5 | Raw point sizes → text styles or `scaledFont`; title case for headings and buttons; spacing snapped to the 4pt grid; field + helper grouped at 4pt |
| States | MOT-5, MOT-6 | Bare spinners gained labels; empty states use prominent glass for their next action |

### Verification

Each slice built its own targets, ran its tests, linted, and captured before and
after screenshots in light and dark where a capture path exists. The integrated
branch is validated with `apple/bin/build-ci.sh`, `apple/bin/test.sh all`,
`apple/bin/lint-swift.sh --all`, `bin/check-docs.sh`, and an XcodeGen drift check.

Known gap: Cockpit's offscreen snapshot harness (`capture-pilot-scenes.py`) cannot
render Liquid Glass — glass inside scroll views and the Remote Desktop scene
capture blank. Cockpit glass was therefore verified in the running app, not in
the harness. Teaching the harness to render glass (an on-screen capture window,
or a forced material fallback in `GlassCompat`) is follow-up work.

### Deferred

- Glass pass for Agentic Use and the runner fleet scene (landed via #313 while
  this pass ran).
- Loading skeletons (MOT-5) and illustrated empty states (MOT-6): new design
  work rather than cleanup.
- Pairing alert wording ("Reject") and Walkie's "Remove Download" /
  "Regenerate & re-sync" confirmations: behavior or security decisions.
- Ink color swatches still lack accessibility labels.
## 2026-10-31 — Cockpit Agentic Use dashboard

Scope: the Agentic Use tab as redesigned in #310 (`apple/Sources/Pilot/AgenticUse/*View*`,
KPI cards, daily chart, Token Flow, Provider Breakdown, Top Models, Insights).
Reviewed against the zandesign check catalog. The catalog targets React; checks were
applied to SwiftUI equivalents. Visual pass: `capture-pilot-scenes.py --scenes agentic-use`
at 1440×960 in light and dark, before and after the fixes. Interactive flows (hover
tooltips, legend isolation, popovers) were not exercised.

### Verdict

The data design is strong; the chrome around it was not. Every panel carried a fill
*and* a hairline, Token Flow added fifteen outlined chips, and the insights were cards
inside a card — the page read as border soup. Five rainbow sparklines reused the
provider hues, so decoration looked like data. Stripping chrome and neutralizing the
decoration lets the provider colors and the red/green deltas carry the meaning.

### Findings

| ID | Check | Where | Finding | Fix (applied unless noted) |
|---|---|---|---|---|
| P0-1 | TYPE-3 | `AgenticUseView` footnote, KPI fallback caption, scan count, empty-state hint | Pricing caveat at 10pt `.tertiary` (~26% alpha) fails 4.5:1 | `.secondary`, footnote 10→11pt |
| P1-1 | LAY-2 | `agenticUseCard`, `nodeChrome`, Top Models rows | Fill + 1px border on every card and flow node; divider under every table row | Borders removed; one header rule in Top Models; spacing separates rows |
| P1-2 | LAY-1 / LAY-4 | `AgenticUseInsightsView` | Insight cards (radius 9) nested in a card (radius 10, 14 padding) | Inner surfaces removed; insights grouped by 16pt spacing |
| P1-3 | HIER-2 | Header bar | "Agentic Use" repeated under the identical window title, at a smaller size than card titles | Header leads with the date range |
| P1-4 | HIER-2 | Daily chart legend vs Provider Breakdown | Same share-of-cost percentages shown twice on one screen | **Not applied** — product decision (see below) |
| P1-5 | MOT-5 | `AgenticUseView.content` `.idle` / loaded-without-snapshot | Bare spinner as the whole loading UI | Reuses the labelled scanning state; skeleton still recommended |
| P2-1 | Outside catalog / COL-3 | KPI sparklines | Green/blue/purple/yellow/teal tints collide with Codex/Cursor/Kimi identity colors; yellow goes neon in dark | Neutral `.secondary` sparklines; deltas keep semantic color |
| P2-2 | IMG-2 | Token Flow provider nodes, Insight tiles | Solid gradient tiles with white glyphs read as primary buttons | Soft 16–20% tint with tinted glyph, matching token-type tiles |
| P2-3 | TYPE-4 | Dashboard views | 8 font sizes (9, 10, 11, 12, 13, 14, 17, 26) | 5: caption 10, meta 11, body 12, title 14, display 26 |
| P2-4 | LAY-3 | Dashboard views | Spacing literals 1–3, 5–7, 9, 10, 14, 18 | Snapped to the 4pt grid (hairline 1–2pt kept); card padding 16, radius 12 |
| P2-5 | MOT-6 | `rangeEmptyState` | Empty range had no next action | "Show All History" button when not already on All |

Verified clean: TYPE-1, TYPE-2, COL-2 (dark parity), COL-4, BTN-1, BTN-2, BTN-5,
IMG-1 (SF Symbols + one brand-symbol set), MODAL-*, FORM-* (no forms), HIER-3.

### Detail

- **P0-1 TYPE-3** — `.tertiary` maps to `tertiaryLabelColor`, roughly 2:1 against the
  card fill. The footnote is the only place the API-equivalent pricing caveat and the
  unpriced-token gap appear, so it is content, not chrome. Source:
  https://x.com/zander_supafast/status/1968252670604685678
- **P1-1 LAY-2** — the hairline existed to separate adjacent cards in dark mode; the
  12pt grid gap and a slightly stronger fill (`.quaternary` 0.4→0.5) do that without a
  line. Source: https://x.com/zander_supafast/status/2080000671781110136
- **P1-2 LAY-1/LAY-4** — nested surfaces also broke the radius rule (inner 9 inside
  outer 10 with 14pt padding). Removing the inner surface removes both problems.
  Source: https://x.com/zander_supafast/status/2084623671444799847
- **P1-3 HIER-2** — `ContentView` already sets the window title to "Agentic Use".
  Source: https://x.com/zander_supafast/status/2053925539019165904
- **P1-4 HIER-2 (open)** — for the Cost metric the chart legend and Provider Breakdown
  show identical shares. Options: drop shares from the legend (keep it as a filter),
  or fold Provider Breakdown's cost and per-model popover into the legend and remove
  the card. Left for a product call.
- **P1-5 MOT-5** — a skeleton of the KPI row and chart frame would remove the layout
  jump when data lands. Source: https://x.com/zander_supafast/status/1554384338619453440

### Systemic changes

- `agenticUseCard` is the single card treatment: borderless, `AgenticUseLayout.cardPadding`
  (16) and `cardRadius` (12). One change fixed every panel.
- `AgenticUseLayout` documents the five-size type scale and 4pt spacing for future panels.
- The snapshot workbench header mirrors the live header so captures stay truthful.

### Outside catalog (reviewer judgment)

- The warning banner's icon-only dismiss button had no label or tooltip; added
  "Dismiss" help and an accessibility label.

## 2026-10-23 — contemporary web redesign

Scope: the complete `workers/web` landing experience at `/` and `/made`, its
light/dark themes, product captures, downloads, companion QR dialog, motion,
and the Worker/JavaScript dependency refresh. The earlier native-app review is
retained below.

### Direction and implementation

- Replaced the single download screen with a cinematic hero, four Cockpit
  workflow chapters, a sliding capability rail, companion and security
  sections, and a final download/footer sequence.
- Used locally hosted Geist, porcelain/carbon semantic tokens, the app icon's
  green/orange accents, and real native Cockpit captures instead of generic AI
  imagery. Both routes still emit identical markup and preserve the existing
  canonical/social metadata and download destinations.
- Added an early external theme bootstrap, persisted/system theme behavior,
  synchronized product captures and browser theme colors, and a circular View
  Transitions reveal. Reduced-motion, storage-denied, and non-View-Transitions
  paths remain usable.
- Kept enhancement code native and deferred: no hydrated React, animation
  framework, scroll hijacking, inline script/style, or remote asset dependency.
  Desktop uses the sticky workflow stage; mobile uses per-chapter images in
  normal flow so sticky imagery cannot cover the copy.
- Upgraded Three.js to 0.186.1 with WebGL2 detection, sRGB canvas textures,
  current shader output chunks, legacy-equivalent light scaling, and `Timer`.
  The cockpit remains off the critical script graph and pauses offscreen.
- Updated the workspace to Bun 1.4.4 and current direct dependencies, including
  Astro 7.4, React 19.3, Vitest 5 with `@cloudflare/vitest-plugin`, and Wrangler
  4.152. TypeScript 6 remains only where Astro/embedded-language tooling
  explicitly rejects TypeScript 7; the rendezvous Worker uses TypeScript 7.

### Verified

- Web lint and Astro checks pass with zero diagnostics. All 14 web tests and
  all 25 rendezvous tests pass. Documentation links and repository paths pass
  `bin/check-docs.sh`.
- The production build preserves the CSP and asset-mount checks. Measured
  budgets: CSS 33,239/35,000 bytes; initial JavaScript 6,522/8,000 raw and
  3,182/4,000 gzip; deferred JavaScript 570,536/600,000 raw and
  142,924/150,000 gzip.
- Real Chrome scenarios pass against both Astro and the prepared Cloudflare
  Worker: theme transition and persistence, live OS fallback, matching
  screenshots/meta colors, keyboard carousel controls, workflow controls,
  desktop QR open/close, direct mobile TestFlight behavior, 390px and 320px
  overflow checks, reduced motion without a Three.js request, and core content
  without JavaScript. No browser console errors or failed asset requests were
  observed. Headless GPU performance notices were the only warnings.
- `bun audit` reports no known vulnerabilities in 509 resolved packages. The
  only `bun outdated --recursive` entries are the two documented TypeScript 6
  compatibility pins.

Review captures (bottom capture-only system UI is trimmed; no site content is
removed):

- `design-review/redesign-web-desktop-light.png`
- `design-review/redesign-web-desktop-dark.png`
- `design-review/redesign-web-mobile-light.png`
- `design-review/redesign-web-mobile-dark.png`
- `design-review/redesign-web-workflow-dark.png`
- `design-review/redesign-web-qr-dialog-light.png`

## 2026-09-20 — prior design catalog review

Reviewed 2026-09-20 against the zandesign check catalog (30 checks, IDs cited
below; each links to its source video at
`https://x.com/zander_supafast/status/<id>`). Brief: "super clean, minimal, no
strokes, light and dark mode." Fixes were applied in severity order; see
"Applied" at the end.

Scope: `workers/web` (Astro landing at `/` and `/made`, one screen, one
dialog) plus the SwiftUI sources under `apple/Sources` (Pilot/macOS, Copilot/
iOS, Plotter/iPadOS). Web was reviewed statically and visually (Chrome, 390px
and 1280px, light and dark). Swift was reviewed statically only: the working
tree is mid-migration (project regenerated as `made.xcodeproj`) and the running
Cockpit.app had no on-screen window to capture, so no app screenshots were
taken.

## Verdict

The biggest lever was mode parity: the website hard-pinned `color-scheme:
dark` with raw hex in every rule, so there was no light mode at all, and three
identical filled buttons competed for the single action. In the apps the
recurring smell is "material + hairline stroke + shadow" on the same floating
surface and a `Divider()` under every header bar, which is exactly the border
soup the catalog warns about. Both are now fixed at the token/shared-modifier
level rather than per screen.

## Findings

| # | ID | Sev | Where | Finding | Fix |
|---|---|---|---|---|---|
| 1 | COL-2 | P1 | `workers/web/src/styles/global.css` (before) | `color-scheme: dark` only; no `prefers-color-scheme` rule anywhere; `theme-color` meta hard-coded to `#09090b`. | Two-layer tokens resolved with `light-dark()`, `color-scheme: light dark`, two `theme-color` metas. Applied. |
| 2 | BTN-1 | P0 | `Hero.astro`, screenshot `design-review/web-desktop-dark.jpg` | Three identical brand-filled buttons (macOS, iOS, iPad) in one view. | macOS stays primary; TestFlight buttons and dialog Close become tonal `secondary`. Applied. |
| 3 | TYPE-3 / COL-6 | P0 | tagline `rgba(250,250,250,.55)` over the live 3D scene (`web-desktop-dark.jpg`) | Body-size copy over imagery at roughly 2.5:1 with no scrim under the copy block. | Radial scrim of the page background behind `.landing__content`, tagline moved to `--color-text-secondary`. Applied. |
| 4 | LAY-2 | P1 | `.button` (1px border), `.qr-dialog` (1px `--border`), outline variant | Strokes on the button, dialog, and outline variant; outline hover also set a light background on light text. | All borders removed; secondary is a tonal surface; hover states per variant. Applied. |
| 5 | COL-1 | P1 | `global.css` rules used `#e4e4e7`, `#101012`, `#fff`, `#09090b`, repeated `rgb(250 250 250 / .55)` | Raw hex in component rules; flat token list with no semantic layer. | Primitives (`--zinc-*`) + semantic (`--color-text-secondary`, `--color-surface-tonal`, ...). Applied. |
| 6 | BTN-3 / BTN-4 | P2 | measured widths 186 / 163 / 167 px | Ragged button widths in one group; not full width on mobile. | `--button-min-width: 11.5rem`; buttons stretch to the column under 40rem. Applied. |
| 7 | MODAL-2 | P2 | `.qr-dialog` (`web-desktop-qr-dialog.jpg`) | Dialog popped in with no motion, backdrop was a flat dim. | Backdrop dim + blur fades, card scale-and-fades 240ms ease-out, reduced-motion guard. Applied. |
| 8 | LAY-3 | P2 | `.qr-dialog__code` padding `0.875rem` (14px) | Off the 4px grid. | Spacing scale tokens `--space-*`; padding is now 16px. Applied. |
| 9 | LAY-2 | P1 | Pilot: `NotesView`, `InkOverlay` (x2), `SimulatorPaneView`, `DevicePaneView`, `AndroidPaneView` | Floating capsules drew `.regularMaterial` + 0.5pt separator stroke + shadow on the same element. | Stroke removed; material and shadow already carry the surface. Applied. |
| 10 | LAY-2 | P1 | Pilot: `EditorPaneView` (finder card, error banner), `RemoteDesktopView` (add-connection card, group chips), `NotesView` (selected tab), `BrowserStartPageView` (hotkey chip, preview thumbnail), `WorkspaceView` (collapsed pane slit) | 1pt strokes on cards, chips, and selected states that already had a tinted fill. | Strokes removed; selection reads from the tint alone. Applied. |
| 11 | LAY-2 | P1 | Copilot: `TrackpadView`, tab strip in `ContentView` | 1pt `.secondary` stroke around the trackpad and tab strip on top of `.ultraThinMaterial`. | Strokes removed. Applied. |
| 12 | LAY-2 | P1 | Pilot: `DockerView`, `AgenticUseView`, `DevicePaneView`, `AndroidPaneView`, `SimulatorPaneView`, `WirelessDeviceSession`, `NotesView`, `RemoteDesktopView`, `EditorPaneView`, `PilotApp` settings sidebar, `AgenticUseHeroPanel`, `AgenticUseBreakdownView`, `AgenticUseDailyChart`, `AgenticUseStatRow`, `UsageInspectorView`, `InkOverlay` | `Divider()` under every header bar and between every table row / stat cell. | Dividers removed; grouping comes from existing padding, plus 8pt/24pt spacing where a line was the only separation. Menu separators kept. Applied. |
| 13 | FORM-2 | P1 | `RemoteDesktopView` manual host field | Placeholder "Host, IP, or MagicDNS (e.g. mini01.tailnet.ts.net)". | "Enter a host, IP address, or MagicDNS name". Applied. |
| 14 | LAY-2 | P2 | `WorkspaceView` drop-target highlight | Accent stroke as the drag-over affordance. | Accent fill at 18% instead. Applied. |
| 15 | MOT-5 | P1 | 18 `ProgressView()` sites, e.g. `SimulatorPaneView` status overlay, `AgenticUseView` header | Bare spinners are the only loading UI; no skeleton anywhere in the codebase. | Not applied (design decision). Add a skeleton for list panes (devices, breakdown table) and keep the spinner for sub-second refreshes. |
| 16 | TYPE-4 | P2 | `scaledFont(size:)` uses 11 distinct sizes (6.5, 8, 9, 10, 11, 12, 13, 15, 20, 34, 36); `.system(size:)` adds 14, 16, 17, 26, 28, 32, 40 | 18 distinct sizes across Pilot. | Not applied. Define a 6-step scale on `scaledFont` (10/11/12/13/15/20 + display 34) and map the rest. |
| 17 | COL-3 | P2 | `PilotEditorTheme` dark keywords `srgb(0.98, 0.42, 0.71)`, strings `(0.99, 0.42, 0.42)` | Same saturation as light-mode equivalents on a dark canvas. | Not applied. Bake dark aliases at ~70% warm / ~60% cool. |
| 18 | BTN-1 | P2 | `DevicePaneView`, `AndroidPaneView`, `AgenticUseView` each declare two `.borderedProminent` buttons | Two prominent actions in one pane (only one renders per state in most branches). | Not applied. Confirm each branch renders at most one; demote the second to `.bordered`. |

Verified clean: TYPE-1 (only single-line centered labels), TYPE-2, LAY-4,
LAY-6 (one breakpoint, readable column), COL-4 (red only on badge counts and
error glyphs), COL-5 (no CSS gradients other than scrims), BTN-2, FORM-1,
FORM-3, FORM-4 (n/a on web), MODAL-1 (no "Are you sure?"; Docker removal
dialog is verb + object with Cancel), HIER-4 (one hero, footer nav in one
cluster), IMG-1 (SF Symbols in apps; one inline Apple glyph on web), IMG-3.

## P0 / P1 detail

### 2 — BTN-1 one primary button per view

Evidence: `design-review/web-desktop-dark.jpg`, three white pills side by
side. Users scan for *the* action; three equals none. macOS is the product,
the companions are secondary installs, so those two demote:

```astro
<Button rounded variant="secondary" href={WALKIE_TESTFLIGHT} …>
```

```css
.button[data-variant="secondary"] { background: var(--color-surface-tonal); color: var(--color-text-primary); }
```

Source: 1802684455670136954.

### 3 — TYPE-3 / COL-6 scrim before text on image

Evidence: zoom of the tagline in the first pass, 55%-alpha white over a
mid-blue sky at roughly 2.5:1. Body copy over imagery needs a scrim, then the
type. The fix is one layer, tokenized so it flips with the scheme:

```css
.landing__content::before {
  background: radial-gradient(ellipse at 50% 50%,
    var(--color-scrim-strong) 0%, var(--color-scrim) 40%, var(--color-scrim-none) 72%);
}
--color-scrim-strong: color-mix(in srgb, var(--color-background) 75%, transparent);
```

After: `design-review/after-web-desktop-dark.jpg`,
`design-review/after-web-desktop-light.jpg`. Source: 1968252670604685678.

### 1 — COL-2 dark mode as a first-class mode

Evidence: `:root { color-scheme: dark }` and no media query; the site had one
mode. The token file now declares primitives and semantic aliases once, and
every alias resolves with `light-dark()`, so no rule carries a per-mode
override. `data-theme="light|dark"` on `<html>` pins a scheme for previews and
tests. Source: 1875103802082382115.

### 4, 9, 10, 11, 12 — LAY-2 whitespace over borders

Evidence (web): `.button { border: 1px solid transparent }`, `.qr-dialog
{ border: 1px solid var(--border) }`. Evidence (apps): the pattern

```swift
.background(.regularMaterial, in: Capsule())
.overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
.shadow(color: .black.opacity(0.35), radius: 12, y: 4)
```

repeated in six files, and `VStack(spacing: 0) { headerBar; Divider(); content }`
in nine. The eye lands on the line, not the content. Every decorative stroke
and structural divider listed above is gone; separation now comes from
padding that was already there, or from 8/24pt gaps where a line was the only
spacing. Kept on purpose: gauge arcs in `WorkspaceSidebarRow` (data, not
decoration), ink strokes in `InkOverlay`, and `Divider()` inside menus (a
menu separator, not a border). Source: 2080000671781110136.

### 5 — COL-1 two-layer tokens

Evidence: `#e4e4e7` hover, `#101012` dialog, `#fff` QR, `rgb(250 250 250 /
0.55)` three times. Now `--zinc-*` primitives feed
`--color-{background,surface-*,text-*,button-*,scrim*,backdrop,shadow}`; the
only literals left outside the primitive block are the QR quiet zone, which
must stay white for cameras and is named `--white`. Source:
1875103802082382115, 1835633197905842226.

### 13 — FORM-2 no "e.g." in placeholders

Evidence: `TextField("Host, IP, or MagicDNS (e.g. mini01.tailnet.ts.net)")`.
Screen readers read "e.g." literally and it does not localize. Replaced with a
direct instruction. Source: 1879858975426122119.

### 15 — MOT-5 loading states (not applied)

Evidence: `ProgressView()` is the whole loading UI in 18 places. For list
panes that take more than a beat (device scans, usage aggregation) a skeleton
of the row shape keeps the layout stable. This is a design addition rather
than a cleanup, so it is left for you. Source: 1554384338619453440.

## Systemic recommendations

1. **Web tokens live in one block.** New rules must reference
   `--color-*` / `--space-*` only; a test now fails the build if any CSS rule
   draws a border or the root stops opting into both schemes
   (`workers/web/test/site.test.mjs`).
2. **Apps: one floating-surface recipe.** Six views now share the same
   material + shadow capsule inline. Extracting a `.floatingCapsule()` view
   modifier next to `compatGlassEffect` would make the next stroke impossible
   to add by copy-paste.
3. **Apps: a type scale on `scaledFont`.** Finding 16. Eleven sizes on one
   helper is where one-off values accumulate; give the helper named steps.
4. **Apps: dark-mode aliases for saturated editor colors.** Finding 17; the
   editor theme is already split light/dark, so this is a value change only.

## Outside catalog (reviewer judgment)

- **Dead landing sections.** `Nav`, `Cta`, `Features`, `Devices`,
  `Security`, `TerminalPane`, `UsagePanel` and the scripts `interactions.ts`,
  `liquid-glass.ts`, `tag-cloud.ts` are not imported by any page, and their
  class names (`.btn`, `.feature-card`, `.nav__links`, `--accent`) no longer
  exist in `global.css`. They are uncommitted, so they were left alone; delete
  them or they will drift further from the token system.
- **Light mode over a dark render.** The cockpit scene is dark in its lower
  half by nature, so light mode leans on the scrim (finding 3) to keep dark
  type legible. If the haze reads as washed out, the alternative is to treat
  the scene as a photo and keep the copy block light in both modes; both are
  defensible, and the tokens make either a two-line change.
- **Hard-coded `.white` on capture canvases.** `SimulatorPaneView`,
  `DevicePaneView`, `AndroidPaneView`, `WirelessDeviceSession`, and Plotter
  draw status text in white on a fixed dark stage. That is a video-surface
  convention, not a dark-mode gap, and was left as is.
- **Pane resize handle color** in `WorkspaceView` is a per-scheme white
  literal (0.2 / 0.78). It works in both modes; `Color(nsColor:
  .separatorColor)` would say the same thing with one token.

## Applied

Files changed for this review:

- `workers/web/src/styles/global.css` — tokens, both schemes, no borders,
  button tiers, dialog motion, spacing scale.
- `workers/web/src/components/ui/Button.astro` — `variant: 'primary' |
  'secondary'` (was `default | outline`).
- `workers/web/src/components/Hero.astro` — companion and Close buttons
  `variant="secondary"`.
- `workers/web/src/layouts/Layout.astro` — two `theme-color` metas.
- `workers/web/test/site.test.mjs` — stylesheet scheme/border test.
- `apple/Sources/Pilot/{NotesView,InkOverlay,EditorPaneView,RemoteDesktopView,
  WorkspaceView,PilotApp}.swift`,
  `apple/Sources/Pilot/{Browser/BrowserStartPageView,Simulator/SimulatorPaneView,
  Device/DevicePaneView,Device/WirelessDeviceSession,Android/AndroidPaneView,
  Docker/DockerView,Usage/UsageInspectorView}.swift`,
  `apple/Sources/Pilot/AgenticUse/{AgenticUseView,AgenticUseHeroPanel,
  AgenticUseBreakdownView,AgenticUseDailyChart,AgenticUseStatRow}.swift`,
  `apple/Sources/Copilot/{ContentView,TrackpadView}.swift` — strokes and
  structural dividers removed as itemized above.

Screenshots: `design-review/web-*.jpg` (before),
`design-review/after-web-*.jpg` (after, both schemes, both widths, dialog).
