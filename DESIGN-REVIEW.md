# Design review — made (blau.app web + Pilot/Walkie/Kneeboard apps)

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
