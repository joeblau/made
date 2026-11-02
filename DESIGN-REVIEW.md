# Design review — made (blau.app web + Pilot/Walkie/Kneeboard apps)

## 2026-11-01 — Liquid Glass finish for iOS, iPadOS, and macOS 27

Branch `style/liquid-glass-27` (base `079e4bc`). Review uses the zandesign catalog (`~/.claude/skills/zandesign/checks/`), adapted from React to SwiftUI. Check IDs are cited from that catalog.

### Verdict

The biggest lever was consistency, not adding new surfaces. Buttons, fields, segmented controls and corner radii had drifted apart: bordered, borderless and hand-drawn buttons sat alongside glass, and chips and tabs were squared off. One shared token and style layer (`apple/Sources/Shared/LiquidGlassStyles.swift`) now drives every actionable control in Cockpit, Walkie and Kneeboard. Trigger, the widgets and the Live Activities follow the same rules using the native glass APIs.

### Systemic changes

- `LiquidGlassMetrics`: spacing on the 4pt grid (LAY-3); radius tokens control 8, field 12, card 16 and panel 24, plus `inner(outer:padding:)` for concentric nesting (LAY-4); spring and state-change animation tokens (MOT-4).
- `.liquidGlassField()`: an interactive glass capsule for single-line fields or a ConcentricRectangle for multi-line ones, with a visible focus ring (FORM-1/FORM-4). It is not applied inside grouped Forms, alerts, or fields already hosted in a glass toolbar or palette, so glass never stacks on glass.
- `LiquidGlassSegmentedControl`, `.liquidGlassChip(isSelected:)`: capsule segmented and chip controls with a sliding glass selection pill. The system `Picker(.segmented)` is preferred and is used for all 7 segmented pickers.
- `.liquidGlassButtonStyle(prominent:)`, `.liquidGlassIconButton()`, `compatGlassIconButton()`: one prominent action per view (BTN-1), glass secondary actions, and glass circle icon buttons.
- `.liquidGlassPressable`: hover and press feedback for row, card and tile tap targets that stay plain (BTN-5).

### Most-cited checks

LAY-3 ×51, MOT-4 ×41, BTN-5 ×37, BTN-1 ×29, LAY-4 ×26, COL-2 ×25, MOT-5 ×20, MOT-6 ×19, TYPE-4 ×19, IMG-1 ×13, FORM-1 ×11, COL-1 ×11, COL-4 ×9, TYPE-3 ×8, HIER-6 ×7, FORM-5 ×7, HIER-3 ×6, LAY-2 ×6, FORM-4 ×5, LAY-5 ×5

### Change log

| Source | File | Checks | Change |
|---|---|---|---|
| foundation | apple/Sources/Shared/LiquidGlassStyles.swift | BTN-1, BTN-5, FORM-1, FORM-4, LAY-3, LAY-4, MOT-4, COL-1, COL-2, COL-4, HIER-6, brief-1, brief-2, brief-3, brief-4, brief-5 | New shared file. LiquidGlassMetrics holds spacing on the 4pt grid, corner radii (control 8, field 12, card 16, panel 24, plus inner(outer:padding:)), and the spring and state-change animations. It also adds: a .liquidGlassField modifier (plain text style, interactive glass in a capsule for single-line or a ConcentricRectangle for multi-line, .tint focus stroke, optional leading symbol, its own @FocusState or one the caller passes in); LiquidGlassSegmentedControl (a semantic-fill capsule track with a sliding glass pill via matchedGeometryEffect and a spring, turned off under Reduce Motion; real Buttons with the .isSelected trait and optional per-segment identifiers; hover and press feedback); .liquidGlassButtonStyle(prominent:); .liquidGlassIconButton (glass, circle shape, iconOnly label style, set control size); .liquidGlassContainerShape; LiquidGlassChipButtonStyle (.liquidGlassChip(isSelected:)); and LiquidGlassPressableButtonStyle (.liquidGlassPressable) for plain row and card tap targets. Every 26-only API is behind #available(iOS 26.0, macOS 26.0, *) with a material or bordered fallback in the same shape. |
| foundation | apple/Sources/Pilot/GlassCompat.swift | BTN-1, brief-1 | Added compatGlassIconButton(prominent:controlSize:), which hands off to the shared liquidGlassIconButton. Added a doc note pointing Pilot restylers to the shared field, segmented control, chip and pressable helpers. Existing helpers are unchanged. |
| foundation | apple/made.xcodeproj/project.pbxproj | brief-7 | Regenerated with the pinned apple/bin/install-xcodegen.sh. Running it changed nothing except adding LiquidGlassStyles.swift (1 file ref, 1 group child, 3 build files and 3 Sources-phase entries for Pilot, Copilot and Plotter). project.yml is unchanged. |
| restyle:cockpit-shell | apple/Sources/Pilot/WorkspaceView.swift | brief-1, brief-3, brief-4, brief-5, LAY-3, LAY-4, BTN-1, BTN-5, MOT-4, MOT-6, IMG-1 | Pane tab strip: the tabs were glass rounded rectangles with radius 9. They are now interactive glass Capsules, with the same shape for the drop-target overlay (now not hit-testable) and the content shape. Tab height is a new PaneLayoutMetrics.tabHeight token. Horizontal tabs sit in an HStack with 4pt spacing (was 1) inside CompatGlassContainer(spacing: 0); the resizable vertical tab bar also gets CompatGlassContainer(spacing: 0). Bar padding is now on the 4pt grid (6 -> 4 vertical, 8 horizontal), the tab inner inset goes from 14 to 8, and tint changes animate with LiquidGlassMetrics.stateChange. The drag preview is a regularMaterial Capsule, not glass, because drag snapshots have no backdrop. Empty 'No Panes' state: the add-pane buttons are secondary capsule glass inside a container, with padding added. Collapsed-slit unhide: a hand-made plain eye button became compatGlassIconButton(.mini) with a Label for VoiceOver. Hidden-terminal fast-command play/stop: hand-drawn Circle backgrounds became circular .mini glass icon buttons in a container. Their glyph frame is fixed so the spinner swap does not resize the button. The ease-in-out animations became LiquidGlassMetrics.spring. Body and task logic are unchanged, only moved into indicatorStack. |
| restyle:cockpit-shell | apple/Sources/Pilot/WorkspaceTabItem.swift | brief-1, brief-5, BTN-5, COL-1, COL-2, MOT-4, LAY-3 | Close/hide/unhide header buttons and the browser-favicon unhide button changed from .plain to .liquidGlassPressable(cornerRadius: 9). That gives a circular hover wash and press feedback, and keeps them unglazed because they sit inside the tab's glass (no glass on glass). The close circle's fill is now the semantic .fill.tertiary instead of Color.primary.opacity(0.08). Hover-in transition is opacity+scale. Animations use the stateChange/spring tokens. Header buttons get accessibilityLabel(help), which reuses existing tooltip text. Spacing 6 -> 8. |
| restyle:cockpit-shell | apple/Sources/Pilot/WorkspaceQuickJump.swift | brief-1, brief-4, brief-5, BTN-1, LAY-3 | Pinned quick-jump buttons stay secondary glass but get an explicit .buttonBorderShape(.capsule) and a Capsule content shape. The grid is wrapped in CompatGlassContainer(spacing: 0), spacing literals became tokens, and the button was moved into a quickJumpButton helper. The accessibility identifier and the shortcut mapping are unchanged. |
| restyle:cockpit-shell | apple/Sources/Pilot/WorkspaceSidebarList.swift | MOT-6, HIER-3 | The empty-group drop hint is now a Label with a tray.and.arrow.down glyph instead of bare text. The copy is the same. |
| restyle:cockpit-shell | apple/Sources/Pilot/WorkspaceSidebarRow.swift | brief-1, brief-2, brief-4, FORM-4, BTN-5, MOT-4, LAY-3, LAY-4 | The in-place rename TextField uses liquidGlassField(isFocused: renameFocused): a capsule glass field with a focus ring. It is applied after the field's own onSubmit/onExitCommand/onChange so their semantics are unchanged. The drag preview is a Capsule with grid padding. The group header row changed from .plain to .liquidGlassPressable for hover/press feedback. Its drop-target wash is rounded at Radius.control, and its chevron is a single chevron.right that rotates with a spring instead of swapping glyphs. Spacing 6 -> 8. |
| restyle:cockpit-shell | apple/Sources/Pilot/ContentView.swift | brief-1, brief-5, BTN-1, BTN-5, MOT-6, IMG-1, LAY-3 | Sidebar bottom status cluster (microphone, Keep Awake, iPhone/iPad/Watch/audio): the plain icon buttons with a 22pt rectangular hit frame became circular glass icon buttons (compatGlassIconButton(controlSize: .small)) in a CompatGlassContainer(spacing: 0). Each glyph has a fixed 14pt frame so every circle is the same size, and the device cluster spacing is 4 so the row still fits the 180pt minimum sidebar width. All accessibility identifiers, labels, popovers and help text are unchanged. The microphone glyph changed from waveform.circle(.fill) to waveform, so there is no circle inside the circle, and it animates with variableColor while recording. Device glyphs use the .replace content transition. The no-workspaces empty state now has a prominent capsule 'New Workspace…' action (new identifier workspace.empty.new-workspace) that opens the existing NewWorkspaceSheet. Toolbar: Annotate and Inspector are split into separate ToolbarItems with a fixed ToolbarSpacer between them on 26+, so the Inspector toggle gets its own system glass group. No extra glass wrapping was added. statusButtonHitTarget was replaced by statusGlyphFrame/statusButtonStyle helpers plus a StatusClusterMetrics enum. |
| restyle:cockpit-shell | apple/Sources/Pilot/NewWorkspaceSheet.swift | brief-1, brief-2, brief-4, FORM-1, FORM-2, FORM-4, FORM-5, LAY-2, LAY-4, BTN-1, BTN-5, MOT-6 | The search field changed from .roundedBorder to liquidGlassField(systemImage: magnifyingglass, isFocused:). It has a persistent visible 'Starting Folder' label above it, which also serves as its accessibility label, and the placeholder stays an instruction. 'Use Home Folder' and 'Choose…' are now secondary capsule glass (they were default bordered). Cancel is secondary and Create is prominent, both capsule and grouped in containers. The bordered results List became a plain list with a hidden scroll background on a quiet .fill.quaternary surface clipped to Radius.field. Rows are inset 4pt, and the selection highlight radius is Radius.inner(outer: 12, padding: 4) = 8 instead of 4. Result rows changed from .plain to .liquidGlassPressable with the same radius and an .isSelected trait. The no-results state has a folder.badge.questionmark glyph on the same rounded surface. Form spacing now follows FORM-5: label to field 8, groups 20, final helper to actions 24, container padding 24. |
| restyle:cockpit-shell | apple/Sources/Pilot/WorkspacePaneLauncher.swift | brief-1, brief-5, BTN-5, LAY-4 | The custom glass launcher capsule keeps its single glass surface (toolbar shared background stays hidden) and plain/borderless slots, so there is no glass on glass. Every slot (Buttons and Menus) gets a circular .fill.tertiary hover wash via a launcherSlot() helper. It respects isEnabled and animates with stateChange. It is applied on the control itself rather than the label, because macOS flattens Menu labels. The capsule's horizontal padding goes from 4 to 2 so the 32pt hover circles nest concentrically in the 36pt capsule. Slot size is a token. Accessibility identifiers are unchanged. The glass was deliberately left non-interactive, because the capsule is a container, not a control. |
| restyle:cockpit-shell | apple/Sources/Pilot/TerminalToolbarControls.swift | brief-1, brief-2, FORM-1, LAY-3 | The Fast Command toolbar field stays plain inside the system toolbar glass (not wrapped twice). It gets a leading secondary 'bolt' glyph (accessibility-hidden) so it stays identifiable after the placeholder is replaced by a command, plus .help("Fast Command"). The 'terminal.fast-command' identifier is still on the TextField itself. The play/stop ControlGroup is unchanged. |
| restyle:cockpit-shell | apple/Sources/Pilot/PilotApp.swift | MOT-6 | The Extendo window's needs-setup placeholder was a bare padded Text. It is now ContentUnavailableView('Setup Required', systemImage: gearshape.2), with the original sentence as the description. It was kept to a net +1 line so PilotApp stays under SwiftLint's 1500-line file_length limit (1498 now). Menus, commands, alerts and scene modifiers are untouched. |
| restyle:cockpit-shell | apple/Sources/Pilot/ExtensionWindowView.swift | brief-1 | Toolbar grouping now matches the main window: Annotate and Inspector are separate ToolbarItems with a fixed ToolbarSpacer between them on 26+. Accessibility identifiers extension.annotate and extension.inspector-toggle are unchanged. |
| restyle:cockpit-browser | apple/Sources/Pilot/Browser/BrowserToolbarControls.swift | brief-1, brief-2, brief-5, BTN-5, LAY-3, FORM-1, MOT-4 | Address bar (toolbar item): stays on the system toolbar Liquid Glass capsule, with no liquidGlassField wrapper, because wrapping it would put glass on glass. Placeholder stays "URL" because BrowserAddressFocus finds the NSTextField by it for Cmd-L. Added accessibilityLabel("Address"). Padding now uses tokens (12/32/4). The inline reload/stop button moved from .plain to .liquidGlassPressable(cornerRadius: 12): a 24pt circular hit area with hover wash and press feedback. Its icon frame grew from 14 to 16pt with 4pt padding. The icon now carries the enabled state (secondary vs tertiary), since the custom style does not dim itself, and the icon/spinner swap uses a stateChange animation. |
| restyle:cockpit-browser | apple/Sources/Pilot/Browser/BrowserToolbarControls.swift | brief-1, brief-2, brief-5, FORM-1, FORM-5, BTN-1, LAY-3, LAY-5 | Chromium find popover: added a persistent "Find in Page" headline label above the field. The field went from .roundedBorder to liquidGlassField(systemImage: "magnifyingglass") (capsule glass with focus stroke) and gained accessibilityLabel. Previous/Next went from bare .iconOnly to compatGlassIconButton(controlSize: .small) with .help tooltips. Done went to compatGlassButtonStyle + capsule border shape, .small. The three buttons are grouped in a CompatGlassContainer. Match summary uses .callout with monospacedDigit. Spacing is 8 for label to field, 12 for field to actions and 16 padding, all on the grid. Identifiers browser.find-field, find-previous and find-next are unchanged. |
| restyle:cockpit-browser | apple/Sources/Pilot/Browser/BrowserStartPageView.swift | brief-1, brief-4, brief-5, BTN-5, LAY-4, LAY-2, LAY-1, COL-1, MOT-4 | LocalServerCard: removed the hand-rolled hover @State and fill, and the .plain tap target became .liquidGlassPressable(cornerRadius: Radius.card) for hover wash plus press dim/scale. Content card with a quiet .fill.quinary background, no glass and no border. Card radius 18 became the 16 token. The thumbnail radius is now concentric via Radius.inner(outer: 16, padding: 12). The hotkey badge uses semantic .fill.tertiary and Radius.control instead of quaternaryLabelColor and radius 6. The live dot animates color changes. |
| restyle:cockpit-browser | apple/Sources/Pilot/Browser/BrowserStartPageView.swift | COL-2, COL-1, LAY-4 | BrowserPreviewThumbnail: hard-coded Color.white fill and .black foreground became Color(nsColor: .textBackgroundColor) and .primary, so the mini page follows dark mode. Now takes a cornerRadius parameter for concentric nesting. It is hidden from accessibility because it repeats the card's name and URL. |
| restyle:cockpit-browser | apple/Sources/Pilot/Browser/BrowserStartPageView.swift | MOT-5, MOT-6, TYPE-1, MOT-4, LAY-3 | Start page states: added a scanning state (small spinner plus "Looking for dev servers…") that appears only if the scan takes longer than 400ms, so a fast scan never flashes it. The empty state is still left-aligned, now with a server.rack symbol and a next-step hint ("Start a local server, or enter a URL in the address bar."). The empty, list and scanning states swap with an opacity transition, spring animations on hasScanned and servers, and stateChange on the scanning flag. The "Local" header was pulled into a shared sectionHeader. All paddings and spacings use LiquidGlassMetrics.Spacing tokens. |
| restyle:cockpit-browser | apple/Sources/Pilot/Browser/ChromiumBrowserView.swift | brief-1, BTN-1, brief-4, MOT-5, COL-2 | ChromiumBrowserContainerView (AppKit status overlay): the Retry NSButton uses bezelStyle .glass, borderShape .capsule and tintProminence .primary on macOS 26+ (old .rounded bezel kept on older systems), with controlSize .large. Added a small spinning NSProgressIndicator above the message while runtimeState == .starting. It is hidden when stopped and driven from updateMessage via defer. Message label uses preferredFont(.body). Fixed dark-mode parity: the layer's windowBackgroundColor CGColor is now re-resolved in viewDidChangeEffectiveAppearance via performAsCurrentDrawingAppearance. Before, it was frozen at init. |
| restyle:cockpit-browser | apple/Sources/Pilot/Browser/ChromiumDiagnosticsSettings.swift | brief-1, BTN-1, COL-4, MODAL-1 | The destructive "Clear Chromium Browsing Data" button in the grouped Settings Form now uses compatGlassButtonStyle() + .buttonBorderShape(.capsule). It keeps role .destructive and stays secondary rather than prominent. The alerts are unchanged. |
| restyle:cockpit-browser | apple/Sources/Pilot/BrowserAnnotate.swift | LAY-4, brief-4, brief-5, COL-2, MODAL-2, MOT-4, BTN-5, LAY-3, FORM-1 | Injected Lasso annotate panel (HTML/CSS in the userScript). Radius is now concentric: panel 20 = textarea 8 + padding 12 (was 12). The Send button became a capsule (radius 999px) with press scale, and Dismiss became a 24px circle. The <tag> chip became a capsule with 2px/8px padding, and header gap went from 6 to 8. Panel translucency is closer to glass: 0.8 alpha, blur 24px, saturate 1.8. Added a light-mode palette via @media (prefers-color-scheme: light), using new pa-title, pa-tag, pa-input and pa-hint classes with !important overrides of the inline dark styles. Added a scale-and-fade entrance: rAF plus a 100ms setTimeout fallback so the panel can never stay invisible, disabled under prefers-reduced-motion. Transitions are ease-out 0.15s. Textarea has an aria-label. Copy, data-pilot-annotate-* markers, message payloads and the bridge token logic are untouched. Script syntax checked with node --check. |
| restyle:cockpit-editor | apple/Sources/Pilot/EditorPaneView.swift | LAY-4, LAY-3, brief-4 | Added radius and inset constants for quick open: the finder palette uses Radius.panel (24), and result highlights use Radius.inner(outer: 24, padding: 8) = 16, so rows are inset 8 on the sides and 8 at the bottom and nest concentrically. The palette was a 12pt radius with 6pt row insets. |
| restyle:cockpit-editor | apple/Sources/Pilot/EditorPaneView.swift | BTN-5, MOT-4, LAY-3, brief-1 | Finder result rows were onTapGesture with no feedback. They are now real Buttons using .liquidGlassPressable(cornerRadius: 16), giving hover wash, press dim and the button trait for VoiceOver. The tap still sets selectedIndex and calls openSelected(). The highlighted row gets the .isSelected trait, continuous corners and an ease-out highlight animation. Row padding moved to 12/8 and line spacing to 2. |
| restyle:cockpit-editor | apple/Sources/Pilot/EditorPaneView.swift | MOT-6, HIER-3, IMG-1 | Finder status messages (no root, error, no matches) now show a quiet SF Symbol above the secondary text, sized with scaledFont(20, .light) and hidden from accessibility. The message copy is unchanged. |
| restyle:cockpit-editor | apple/Sources/Pilot/EditorPaneView.swift | MOT-6, BTN-1, TYPE-4 | The empty editor state used a hand-built VStack with .font(.system(size: 32)). It is now a ContentUnavailableView: 'No File Open', with the existing '⌘P to find a file' as the description and one primary 'Find File…' action (compatGlassProminentButtonStyle) that calls the existing openFinder(). |
| restyle:cockpit-editor | apple/Sources/Pilot/EditorPaneView.swift | BTN-5, LAY-4, brief-5, brief-1 | The error banner was .thinMaterial at radius 8. It is now floating glass (compatFloatingGlass) with a concentric radius of 20 (dismiss radius 12 + inset 8). The dismiss button was .plain with a 16pt hit area; it is now a 24pt circle with .liquidGlassPressable for hover and press feedback, kept plain inside the glass banner so there is no glass on glass. The accessibilityLabel and help are unchanged, and the decorative icon is hidden from VoiceOver. |
| restyle:cockpit-editor | apple/Sources/Pilot/EditorPaneView.swift | MOT-4, MOT-3, MODAL-2 | The banner and finder overlays now animate in and out with LiquidGlassMetrics.spring: the banner slides down from the top, and the finder scale-fades from 0.98 anchored at the top. Each sits in its own ZStack wrapper with .animation(value:), so the animation never reaches the SourceEditor layer. Under Reduce Motion they use a plain opacity fade. |
| restyle:cockpit-editor | apple/Sources/Pilot/NotesView.swift | brief-3, brief-4, MOT-4 | Note tabs were glass rounded rectangles at radius 7; they are now interactive glass capsules with an ease-out selection animation. The tab drag preview is now a capsule too, and the drop insertion marker uses the stateChange ease-out in place of easeInOut. |
| restyle:cockpit-editor | apple/Sources/Pilot/NotesView.swift | BTN-5, LAY-4 | The tab close button was .plain, 18 wide with no height. It is now an 18x18 circle with .liquidGlassPressable (hover and press feedback), inset 4 from the trailing, top and bottom edges so it sits concentrically in the capsule (13 = 9 + 4). Added an accessibilityLabel 'Close Note'. Its existing hover/selected visibility logic is unchanged. |
| restyle:cockpit-editor | apple/Sources/Pilot/NotesView.swift | brief-1, IMG-1 | The '+' new-note button now uses Label('New Note', systemImage: 'plus') with .compatGlassIconButton(), so it is a consistent circular glass button with a VoiceOver name. The tab-drop destination on it is kept. |
| restyle:cockpit-editor | apple/Sources/Pilot/NotesView.swift | MOT-6, BTN-1 | The 'No Note' empty state gained a single primary 'New Note' action (compatGlassProminentButtonStyle) calling the existing store.addNote(). Title and description copy are unchanged. |
| restyle:cockpit-editor | apple/Sources/Pilot/NotesView.swift | LAY-3 | Moved the secret-storage disclosure padding to the 4pt grid (vertical 6 to 4) and tokenized the tab-bar and menu padding. |
| restyle:cockpit-editor | apple/Sources/Pilot/InkOverlay.swift | BTN-1, BTN-5, LAY-4, LAY-3, MOT-4, COL-2, brief-1, brief-5 | The ink toolbar was one floating capsule of .plain buttons, a .plain 'Done' and Color.clear spacers. It is now three neighboring glass groups in a CompatGlassContainer: (1) a swatch capsule of plain swatch buttons with .liquidGlassPressable circular hover/press feedback, using 28pt targets and a 4pt inset so the ends are concentric; (2) eraser, undo and clear as .compatGlassIconButton(controlSize: .large) with Label names; (3) 'Done' as the single compatGlassProminentButtonStyle action. The swatch selection ring now animates. The swatch is 20pt, up from 18, and has a 0.5pt hairline so the white swatch stays visible on light glass. Top padding went from 14 to 16. |
| restyle:cockpit-editor | apple/Sources/Pilot/InkOverlay.swift | brief-1, COL-4 | Clear annotations (local and Kneeboard) now uses role: .destructive with a neutral .primary foreground, so it carries the semantics without extra red. The RemoteInkControls capsule of plain buttons became two circular glass icon buttons (large) in a CompatGlassContainer. Actions are unchanged. |
| restyle:cockpit-editor | apple/Sources/Pilot/NotesEditorTextView.swift | LAY-2, LAY-3, brief-4, TYPE-4, COL-2 | MarkdownImagePreviewView (AppKit chrome only): dropped the hairline border in favor of the existing quiet fill; the radius went from 8 to Radius.card (16) with continuous cornerCurve; the image inset went from 10 to 8; the status label uses preferredFont(forTextStyle: .subheadline), the same 11pt on macOS, in place of systemFont(ofSize: 11). Fixed a dark-mode parity bug: the layer background was a CGColor snapshot taken at init. It is now re-resolved in viewDidChangeEffectiveAppearance via performAsCurrentDrawingAppearance. |
| restyle:cockpit-editor | apple/Sources/Pilot/NotesEditorTextView.swift | brief-4, IMG-1 | The inline color-chip swatch was a 3pt rounded square; it now draws as a circle (NSBezierPath(ovalIn:)) to match the ink palette swatches. The hairline stays so light swatches remain visible. Hit area, frame and click behavior are unchanged. |
| restyle:cockpit-devices | apple/Sources/Pilot/Device/DevicePaneView.swift | BTN-1, BTN-5, brief-1, brief-4, brief-5, LAY-3, HIER-3, HIER-6, MOT-5, MOT-6, TYPE-4, COL-2 | Added four shared internal views, used by the iOS device, Simulator and Android panes. (1) DevicePickerHeader: title plus a circular small glass Refresh button (compatGlassIconButton) that replaces the .borderless one. Spacing is on the 4pt grid. (2) DevicePickerRow: leading symbol column, title and detail, optional green state badge, trailing chevron. It has an 8/4 inset so the pressable hover wash does not touch the text. (3) DevicePaneMessage<Actions>: wraps ContentUnavailableView for empty, loading and failure states. While loading, the symbol pulses (symbolEffect .pulse) and a small spinner shows. Actions sit in a CompatGlassContainer/HStack. Text follows Pilot's zoom ladder via .uiZoomedDynamicType(). The onCanvas option puts it on the dark PreviewCanvasBackground with a dark color scheme. (4) DevicePaneToast: a floating glass capsule (compatFloatingGlassCapsule) that replaces the compatGlassCapsule toast. Changes in this file's own views: picker rows use .liquidGlassPressable instead of .plain. The full-width 'Share Wirelessly…' button and the safe-area 'Share Wirelessly…' button get a capsule border shape and token padding. The picker empty states, the Connecting/Capture Failed status blocks and the camera-permission block now use DevicePaneMessage; Connecting now shows a loading state. The private DeviceToastView was removed. All copy and actions are unchanged, and the Retry/Open Camera Settings button stays the only prominent one. |
| restyle:cockpit-devices | apple/Sources/Pilot/Device/WirelessDeviceSession.swift | brief-1, brief-4, COL-2, TYPE-3, TYPE-4, MOT-5, LAY-3 | WirelessDeviceView only (receiver logic untouched). The header's 'Use USB' and 'Stop' changed from .borderless to small capsule glass buttons grouped in a CompatGlassContainer. The header now forces a dark color scheme: it sits on the dark canvas, and in light appearance its headline used to render black on near-black. The instructions' icon uses .largeTitle instead of scaledFont(36) and pulses while the receiver is starting or waiting. The pairing code uses .largeTitle.monospaced().weight(.medium) instead of .system(size: 36). Added .uiZoomedDynamicType(), token spacing and capsule shapes on the prominent Try Again / Start Wireless Sharing buttons. Added a private isListening helper. |
| restyle:cockpit-devices | apple/Sources/Pilot/Simulator/SimulatorPaneView.swift | BTN-1, BTN-5, brief-1, COL-2, TYPE-3, HIER-6, MOT-5, MOT-6, TYPE-4 | The picker header uses DevicePickerHeader (glass circular Refresh), rows use DevicePickerRow with the 'Booted' badge and .liquidGlassPressable, and the empty states use DevicePaneMessage. SimulatorToolingMissingView uses DevicePaneMessage(onCanvas: true). This fixes a contrast bug: the view never set the dark color scheme, so its secondary text was dark gray on the dark canvas in light mode. SimulatorStatusOverlay's booting, starting and failed states use DevicePaneMessage: the loading states get a pulsing symbol plus spinner, and Back to Devices stays the one prominent action. The toast uses DevicePaneToast. The NSView capture/HID host is untouched. |
| restyle:cockpit-devices | apple/Sources/Pilot/Android/AndroidPaneView.swift | BTN-1, BTN-5, brief-1, HIER-6, MOT-5, MOT-6, TYPE-4, LAY-3 | Same treatment as the Simulator pane: DevicePickerHeader, DevicePickerRow for running devices and bootable AVDs (both with .liquidGlassPressable; the .disabled gating is kept), and DevicePaneMessage for the empty, adb-missing, booting (with secondary Back to Devices), connecting and failed (prominent Retry plus secondary Back) states. The toast helper now wraps DevicePaneToast. Presentation coordinator, polling and the capture/input host are untouched. |
| restyle:cockpit-devices | apple/Sources/Pilot/RemoteDesktopView.swift | FORM-1, FORM-2, FORM-4, FORM-5, BTN-1, BTN-4, BTN-5, brief-1, brief-2, brief-3, brief-4, brief-5, LAY-3, LAY-4, COL-2, COL-6, MODAL-2, MOT-4, MOT-6, TYPE-4, HIER-6 | Group bar: the hand-rolled plain button plus compatGlassCapsule chip became .buttonStyle(.liquidGlassChip(isSelected:)), keeping the .isSelected trait, context menu and drop destination. The chip run and the trailing cluster each sit in a CompatGlassContainer, and selection changes animate with stateChange. New Group and Rename changed from Image plus .circle plus .glass to Label plus compatGlassIconButton(); their VoiceOver names are unchanged ('New Group' / 'Rename Group' via the Label title). Add Computer gets a capsule shape. Cell header: the ellipsis Menu changed from .borderlessButton to .menuStyle(.button) with .menuIndicator(.hidden) and compatGlassIconButton(controlSize: .small); it keeps its 'Options for …' accessibility label. Header padding moved to 12/4 tokens and the selection wash animates. Empty grid slots show a quiet 'Empty Slot' placeholder (new copy, justified by MOT-6), keeping their 'Empty computer slot N' accessibility label. Connecting overlay: dark color scheme with semantic .secondary text instead of white at 0.85, and a capsule Cancel. Connect form: the placeholder-as-label .roundedBorder fields became liquidGlassField capsule fields under persistent visible labels ('Username' with an 'Optional' hint, 'Password'). The placeholders are now instructions via prompt: ('Enter username' / 'Enter password'), and the field titles still give the VoiceOver names. Spacing follows FORM-5 (label to field 8, between groups 20, to the submit button 24). The error moved into the left-aligned form column. Connect / Try Again changed from a fixed 120pt prominent button to a full-width capsule .large prominent button. Computer picker: the .ultraThinMaterial card at radius 16 with a manual shadow became compatFloatingGlass at Radius.panel (24, continuous). The xmark Close changed from plain to a small glass icon button. Discovered rows use .liquidGlassPressable with an inset wash. The manual host field gets a persistent 'Host Address' label, a quiet capsule fill (not glass, to avoid glass-on-glass inside the glass panel) and an animated tint focus ring. Connect is a capsule. The overlay now enters with a scoped spring opacity+scale transition; the animation is limited to the overlay ZStack so the VNC grid never interpolates. The picker construction moved into a remoteComputerPicker(groupID:) helper with identical closure logic. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseView.swift | TYPE-4, LAY-3, LAY-4, LAY-2, LAY-1, brief-4, brief-5, brief-6 | Shared dashboard tokens: AgenticUseLayout now uses LiquidGlassMetrics (cardPadding = Spacing.medium, cardRadius = Radius.card, which is 16 and was 12, new gap = Spacing.small). Added AgenticUseLayout.TextStyle (display 26 / title 14 / body 12 / meta 11 / caption 10) and a View.agenticUseFont(_:weight:design:) helper that wraps scaledFont, so every text node uses a named style and still follows Cockpit's text zoom. agenticUseCard() keeps its quiet non-glass fill with no border and now also declares liquidGlassContainerShape so children nest concentrically. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseView.swift | brief-1, brief-3, brief-5, BTN-5, MOT-4, IMG-1 | Header bar: the range Picker(.segmented), a system capsule on 26+, and the refresh button are grouped in a CompatGlassContainer. The refresh button is now Label + compatGlassIconButton(controlSize: .small), replacing a bare Image with ad-hoc circle/glass modifiers. The refreshing spinner is .mini with an opacity transition and a stateChange animation, replacing .small scaled to 0.7. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseView.swift | brief-1, brief-4, BTN-5 | Warning banner: the full-bleed squared orange strip is now an inset rounded strip (card radius, aligned with the cards). The .plain xmark is now a circular glass icon button (compatGlassIconButton(controlSize: .mini)). The warning glyph is hidden from accessibility. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseView.swift | MOT-5, MOT-6, BTN-1, LAY-3 | Loading state: the lone centered spinner is now a dashboard skeleton (5 KPI placeholders plus a chart placeholder that breathes slowly and holds still under Reduce Motion), with the existing progress bar, 'Loading agent usage…' text and file count overlaid in the chart slot. The empty, range-empty and failed ContentUnavailableViews keep their single compatGlassProminentButtonStyle primary action. All spacing literals now use tokens. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseKPICards.swift | TYPE-4, LAY-3, MOT-4 | Grid spacing now uses AgenticUseLayout.gap. All fonts use named styles (the value is .display rounded bold). Sparkline height 30 -> 32. The value animation moved from an ad-hoc interactiveSpring to LiquidGlassMetrics.spring. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseDailyChart.swift | brief-3, BTN-5, MOT-4, HIER-6 | The provider legend's .plain buttons are now capsule filter chips (.liquidGlassChip(isSelected:)) in a CompatGlassContainer. The isolated provider gets the selected tint and the .isSelected trait, and the spring animation is the shared token. The chip row falls back to a horizontal ScrollView when the card is too narrow. The metric Picker stays system .segmented (a capsule on 26+). |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseDailyChart.swift | brief-5, LAY-2, TYPE-4, LAY-3, MOT-4 | The hover tooltip changed from regularMaterial with a hairline stroke to compatFloatingGlass in a Radius.field rounded rect: it floats over the plot, so it belongs to the control layer. The stroke is removed. The tooltip animation uses LiquidGlassMetrics.spring. Axis, tooltip and legend fonts use named styles, and spacing uses tokens. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseInsightsView.swift | TYPE-4, LAY-3 | Named fonts and token spacing (adaptive column minimum 190 -> 192). The tile radius uses Radius.control. The tile glyph is accessibilityHidden because the combined row already reads the title and detail. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseProviderBreakdown.swift | BTN-5, COL-1, COL-2, LAY-3, TYPE-4 | Legend entries, which open their popover on hover, now show a visible hover wash: a .fill.tertiary rounded rect that bleeds 4pt past the entry so the grid does not shift, animated with stateChange. The share bar track uses .fill.tertiary instead of Color.secondary.opacity(0.1), and its height is 14 -> 12. Named fonts and token spacing throughout, including the popover. The unpriced badge padding is snapped to the grid (4h/2v). |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseTopModels.swift | brief-1, BTN-1, IMG-1, MOT-4, TYPE-4, LAY-3 | The 'View All N Models' / 'Show Top 10' disclosure is now a capsule secondary glass button using a Label with chevron.down/chevron.up (was arrow.right/chevron.up) and a symbol replace transition. The toggle uses LiquidGlassMetrics.spring. Rows use named fonts and token spacing. The provider glyph is 16pt wide and accessibilityHidden. Sparkline height 22 -> 24. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/AgenticUse/AgenticUseTokenFlow.swift | LAY-4, brief-4, brief-5, TYPE-4, LAY-3, MOT-4 | Node corners are now concentric. A new private NodeMetrics enum sets tileRadius = Radius.control (8) and padding = 8, so node radius = 16; before, the node and its inset tile both used 8. Short model nodes therefore render as capsules, with 4pt extra horizontal padding. Nodes stay solid content fills, not glass. Named fonts, token spacing, tile glyphs hidden from accessibility, and hover/dim animations use LiquidGlassMetrics.stateChange. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/Usage/UsageInspectorView.swift | brief-1, BTN-1, brief-4, MOT-4, MOT-5, LAY-3 | Provider cards use the shared card radius (16, continuous; was 12, non-continuous) and declare a container shape. The 'Enable Usage' and 'Set Up' actions changed from .link to small capsule secondary glass buttons (compatGlassButtonStyle). They are not prominent because several cards can show them at once. Loading is a redacted two-window skeleton (accessibility label 'Loading usage') instead of a lone spinner. Card content changes animate on a coarse state key with LiquidGlassMetrics.spring, and the countdown animation uses the shared spring. Spacing snapped to the grid (6 -> 8, 10 -> 12, plan badge 6 -> 8 horizontal). The brand glyph is accessibilityHidden. |
| restyle:cockpit-dashboards | apple/Sources/Pilot/Usage/UsageSettingsView.swift | IMG-1, brief-2 | The 'Disabled' status label gets .labelStyle(.titleAndIcon) to match the Signed in / Not signed in labels. Everything else is a grouped Form with system styling, so it is left as is (brief-2 exception). |
| restyle:cockpit-devtools | apple/Sources/Pilot/PullRequestListView.swift | BTN-5, TYPE-4, LAY-3, MOT-5, brief-1 | Shared change to InspectorSectionHeader, used by Actions, Tasks, PRs, Files and Usage: the plain 17pt refresh glyph is now an icon-only glass circle (compatGlassIconButton, .small) labelled Label(refreshHelp). While loading, the spinner shows inside the same button, which is disabled, so nothing shifts. Headers without a refresh action (Files) reserve the slot with a hidden copy of the button, so every tab's header is the same height. The header icon uses .subheadline.weight(.medium) instead of scaledFont(size: 11), which still follows the uiZoomedDynamicType zoom steps. Spacing now uses LiquidGlassMetrics tokens. |
| restyle:cockpit-devtools | apple/Sources/Pilot/PullRequestListView.swift | MOT-5, BTN-5 | New internal InspectorRefreshGlyph: the arrow.clockwise symbol swaps in place for a mini spinner. The symbol keeps its layout slot (only opacity changes), so the button never resizes. Reused by Runners and Docker. |
| restyle:cockpit-devtools | apple/Sources/Pilot/PullRequestListView.swift | BTN-5, LAY-3, LAY-4, LAY-1, LAY-2, brief-1, brief-4, brief-5 | Inspector cards: added the InspectorCardMetrics token (padding 12, was 10 and off-grid; radius LiquidGlassMetrics.Radius.card 16, was 8). inspectorListCard() is split into inspectorCardSurface() and inspectorCardTransition() and keeps its old behaviour for GitHubTasksView. PR and Actions rows: the card surface now sits inside the Button label and .plain becomes .liquidGlassPressable(cornerRadius: card radius). The whole card is the tap target, with a hover wash and press scale in the card's own shape. Cards stay content: no glass, no border. |
| restyle:cockpit-devtools | apple/Sources/Pilot/PullRequestListView.swift | MOT-5, HIER-5, LAY-3 | New internal InspectorLoadingPlaceholder: redacted placeholder cards of varied widths that pulse gently. The pulse stops under Reduce Motion, and VoiceOver reads a single 'Loading'. The tab-selector padding changed from 8/6 to 8/8. |
| restyle:cockpit-devtools | apple/Sources/Pilot/GitHubTasksStore.swift | BTN-5, MOT-4, MOT-5, LAY-3 | GitHubTasksView: the centered small ProgressView is replaced by InspectorLoadingPlaceholder. This is safe because the store only sets isLoading for a first or manual load when nothing is on screen, never for background polls. GitHubTaskRow: the '#number' prompt button changes from .plain to .liquidGlassPressable, with a 4pt inset cancelled by matching negative padding so the layout is unchanged. Its green 'sent' state now animates. The issue title's onTapGesture is now a real Button with the same open action and help text, styled .liquidGlassPressable, so it gets hover and press feedback and is exposed to VoiceOver as a button. Spacing uses tokens. |
| restyle:cockpit-devtools | apple/Sources/Pilot/Runners/RunnersView.swift | brief-1, brief-3, brief-5, BTN-5, HIER-6 | Scope tab strip: the hand-built .plain + compatGlassCapsule(tint:) chips now use the shared .liquidGlassChip(isSelected:) style inside a CompatGlassContainer. A spring animates selection changes. The context menus and .isSelected trait are kept. They stay chips rather than a segmented control because each tab has a context menu and the strip scrolls. The Add and Refresh buttons are Label-based compatGlassIconButton() circles at one control size; their accessibility labels are kept as the Label titles. |
| restyle:cockpit-devtools | apple/Sources/Pilot/Runners/RunnersView.swift | brief-2, MOT-5, LAY-3 | The 'Filter runners' field is now TextField.liquidGlassField(systemImage: "magnifyingglass") instead of a hand-made HStack + glass capsule. The separate 'if isRefreshing ProgressView' that pushed the cluster sideways is removed; the spinner now shows inside the refresh button via InspectorRefreshGlyph. Summary dots changed from 6 to 8pt. |
| restyle:cockpit-devtools | apple/Sources/Pilot/Runners/RunnersView.swift | LAY-4, brief-4, BTN-5, MOT-4, brief-1, LAY-3 | Cards and tiles: added a private RunnerSurface token enum that encodes the existing concentric math (card 24 = thumb 8 + pad 16; tile 20 = thumb 8 + pad 12) and switched every RoundedRectangle to .continuous. Added a shared private runnerThumbnail(size:cornerRadius:) used by the card, tile, popover, and the edit sheet, which gains the same tinted thumbnail. The plain pencil edit buttons are now compatGlassIconButton(controlSize: .small). The tile's hover wash and edit-button reveal now animate with stateChange. The error banner uses continuous corners with radius 24 (12 for the Retry capsule plus 12 padding) and spacing tokens. |
| restyle:cockpit-devtools | apple/Sources/Pilot/Runners/RunnersView.swift | brief-2, FORM-1, FORM-4, FORM-5, BTN-1 | AddRunnerScopeSheet: the .roundedBorder TextField becomes .liquidGlassField(isFocused: isNameFocused), passing the existing @FocusState, under the persistent visible label already there. One prominent action (Add Source) and Cancel as glass are kept. Sheet spacing and padding use tokens. RunnerDetailsSheet keeps its system Form fields per the brief; only spacing tokens and the thumbnail changed. |
| restyle:cockpit-devtools | apple/Sources/Pilot/Runners/RunnerFleetView.swift | BTN-5, LAY-4, TYPE-4, LAY-3, brief-4 | Camera controls: the RoundedRectangle(16) glass on a 32pt-wide column is now an explicit compatGlassCapsule(interactive: true). Each .plain button becomes .liquidGlassPressable(cornerRadius: 16), giving a circular hover/press wash concentric with the capsule. The fixed .system(size: 12) font becomes .callout.weight(.semibold), which is 12pt on macOS. Legend spacing and swatch size snapped to the 4pt grid. |
| restyle:cockpit-devtools | apple/Sources/Pilot/Docker/DockerView.swift | TYPE-4, brief-2, brief-1, MOT-5, MOT-4, LAY-3 | Every scaledFont(size:) becomes a semantic style with the same macOS size (13 → .body, 12 → .callout, 11 → .subheadline, 10 → .caption). The root gets .uiZoomedDynamicType() so ⌘+/⌘- zoom still scales the text. The filter field is now liquidGlassField(systemImage: "magnifyingglass"). The refresh button is a compatGlassIconButton(.small) with the refresh spinner moved inside it; the separate mini spinner beside the engine status is gone. The running count animates with numericText. Status dots changed from 7 to 8pt and spacing uses tokens. |
| restyle:cockpit-devtools | apple/Sources/Pilot/Docker/DockerView.swift | brief-4, brief-1, brief-5, BTN-1, BTN-5, COL-4, MODAL-1, MOT-4 | Error banner: the full-bleed square orange strip becomes an inset banner with continuous corners (radius 20, from the dismiss circle plus the 8pt inset) that springs in and out. The plain xmark is now a compatGlassIconButton(.small) labelled 'Dismiss error'. The empty-state Retry (prominent) and Open Docker Desktop (glass) buttons are wrapped in a CompatGlassContainer. Row actions: the plain 22pt glyph buttons become compatGlassIconButton(.small) circles in a CompatGlassContainer. While busy, the actions keep their layout slot (opacity 0, disabled, hidden from accessibility) with the spinner overlaid, so the ports column no longer jumps. Remove has no destructive role or red tint because the confirmation dialog still holds the danger styling. Hover and busy changes animate. |
| restyle:cockpit-settings | apple/Sources/Pilot/Setup/SetupView.swift | LAY-4, LAY-3, LAY-1, brief-4, brief-5 | Shared card style first: added a file-private `setupCard(tint:)` modifier that every setup card now uses (permission rows, project card, tool cards, the install-location warning, and the new summary card). It applies 16pt padding, full width, continuous corners at `Radius.card` (16) instead of 12 non-continuous, and `liquidGlassContainerShape()`. Cards keep a quiet `.quaternary` fill (or a 10% tint for the warning). They do not get glass, because they are content. |
| restyle:cockpit-settings | apple/Sources/Pilot/Setup/SetupView.swift | BTN-5, MOT-4, LAY-4, COL-1, brief-1, brief-3 | Sidebar step rows are full-row tap targets, so they stay plain-looking. `.buttonStyle(.plain)` became `.liquidGlassPressable(cornerRadius:)`, which adds hover and press feedback. The selected step gets a capsule pill (`.fill.secondary`) that slides between rows with `matchedGeometryEffect` on `LiquidGlassMetrics.spring` (turned off under Reduce Motion). The pill is concentric with the step badge: badge grown from 26 to 28pt, inset 8, so the pill radius is 14+8. The unselected badge fill changed from `Color.secondary.opacity(0.12)` to the semantic `.fill.tertiary`. Negative horizontal padding keeps the badges lined up with the header. Accessibility traits are unchanged. |
| restyle:cockpit-settings | apple/Sources/Pilot/Setup/SetupView.swift | BTN-1, brief-1, brief-5 | All unstyled actionable buttons now use `compatGlassButtonStyle()` (secondary glass): Enable/Open Settings, Refresh Status, Check Local Network, Choose Folder…, Copy, and Check Again. Refresh Status and Check Local Network sit together in `CompatGlassContainer`. The footer buttons (Back, Set Up Later, and Continue or Open Cockpit) are now also wrapped in `CompatGlassContainer`. Their existing styles and the single prominent action per step are unchanged. |
| restyle:cockpit-settings | apple/Sources/Pilot/Setup/SetupView.swift | MOT-5, MOT-1, MOT-4, BTN-5, IMG-1 | Loading and state feedback: a small `ProgressView` appears next to a permission's button while that permission's request is in flight. The Copy button is now `Label(Copy/Copied, doc.on.doc/checkmark)` with a symbol-replace content transition and ease-out animation. Tool status and the Ready-step permission summary now show the same checkmark.circle.fill / circle icons as the permission rows, so state is not shown by color alone. Step content cross-fades with `LiquidGlassMetrics.stateChange` (turned off under Reduce Motion). |
| restyle:cockpit-settings | apple/Sources/Pilot/Setup/SetupView.swift | FORM-5, LAY-5, LAY-3, COL-1 | Layout: each Toggle and its helper caption are now grouped with 4pt spacing, with a larger gap before the next group (companions toggle, update toggle). Install commands are shown as inline code chips (`.fill.quaternary`, `Radius.control`, continuous corners). Every spacing literal now uses `LiquidGlassMetrics.Spacing` tokens (content padding 28 to 24, footer 28/16 to 24/16). The feature icon uses `.foregroundStyle(.tint)`. Decorative icons and the app icon are hidden from VoiceOver. |
| restyle:cockpit-settings | apple/Sources/Pilot/PilotSettingsView.swift | BTN-1, brief-1, LAY-5, MOT-6, TYPE-4, LAY-4, LAY-3 | Check for Updates… and Set Up Cockpit… now use secondary glass (`compatGlassButtonStyle`); neither is prominent because the page has no single primary action. In the Setup section the description now sits beside its button in a `LabeledContent` row (button trailing). The style is applied where Settings uses `OpenSetupButton`, so the menu-bar command copy is untouched. The sidebar search shows `ContentUnavailableView.search(text:)` when no section matches. In `PilotSettingsPageHeader`, the fixed 34pt glyph became `.largeTitle.weight(.medium)` + `.imageScale(.large)`. The tile uses `Radius.card` with continuous corners and is hidden from VoiceOver, and spacing uses tokens. |
| restyle:cockpit-settings | apple/Sources/Pilot/SecureMessaging/SecureMessagingView.swift | BTN-1, FORM-1, MOT-5, COL-1, COL-2, MOT-6, LAY-3 | Copy My Key, Generate Pairing Token, Send Test Blob, and Disconnect/Cancel Connection (keeps `role: .destructive`) now use secondary glass. Send uses `compatGlassProminentButtonStyle`; Send and Connect are never shown together, so each state has exactly one primary action. The message field now has a persistent `LabeledContent("Message")` row label (the field uses `.labelsHidden()`, so its title still shows as placeholder text). While signaling, hole punching, or handshaking, the status shows a small `ProgressView` instead of an orange dot, and the status text fades between states. Idle status uses `.secondary` instead of `.gray`. The empty session log became a Label with an SF Symbol. |
| restyle:cockpit-settings | apple/Sources/Shared/SettingsView.swift | brief-1, LAY-3, MOT-4, COL-2 | Regenerate & re-sync uses a new file-private `settingsActionButtonStyle()`. On macOS that is `liquidGlassButtonStyle()` (secondary glass). On iOS it does nothing, so the Form button keeps the platform's list-row look. The Synced badge became `Label("Synced", systemImage: "checkmark.circle.fill")` (not color alone), with padding on the 4pt grid (6/2 to 8/4) and an 8pt header gap. It fades and scales in with `LiquidGlassMetrics.spring` when the synced state changes. It stays a tinted fill, not glass, because it is a status badge. |
| restyle:walkie | apple/Sources/Copilot/ContentView.swift | brief-1, HIER-4, IMG-1 | Toolbar: added a `ToolbarSpacer(.fixed, placement: .topBarLeading)` so the Settings and Speech Storage buttons sit in one glass group and the Dashboard and Builds buttons in another. The Speech Storage button now uses `Button("Speech Model Storage", systemImage:)` like its neighbors, so the VoiceOver label is the same. Toolbar items are not double-wrapped in glass. |
| restyle:walkie | apple/Sources/Copilot/ContentView.swift | brief-1, brief-5, MOT-4, LAY-3 | Speech-model download banner rebuilt as a new `modelLoadingBanner`: the status panel (glass, `Radius.panel`) and a Cancel button styled with `.liquidGlassButtonStyle()` at large size are now side-by-side glass shapes in one `GlassEffectContainer`. Before, Cancel was a plain button inside the glass. The banner slides and fades in with `LiquidGlassMetrics.spring` instead of appearing instantly. Spacing now uses the shared tokens. |
| restyle:walkie | apple/Sources/Copilot/ContentView.swift | MOT-4, MOT-5, LAY-3 | Recording status panel: spacing and padding use the tokens, the radius uses `Radius.panel`, and it slides in and out with a spring tied to `walkie.phase`. The red recording mic pulses. The "Looking for Cockpit…" empty state now animates its antenna symbol and keeps the ProgressView. |
| restyle:walkie | apple/Sources/Copilot/ContentView.swift | BTN-5, LAY-4, LAY-3 | Tab switcher bar: the previous/next halves were `.plain` with no press feedback. They now use `.liquidGlassPressable(cornerRadius: barHeight / 2)`, which gives a pressed wash concentric with the 64pt capsule (inner radius = outer radius with zero inset). Each half gets an accessibility label, "Previous Tab" / "Next Tab" (VoiceOver only). Height is now a `barHeight` constant and spacing uses the tokens. |
| restyle:walkie | apple/Sources/Copilot/ContentView.swift | MOT-5, LAY-3 | Speech Storage sheet: while the model downloads, shows a progress row using the existing `modelLoadingFraction` and `modelLoadingProgress`, because the sheet covers the main screen's banner. No new text. Workspace row and badge padding now use the tokens; trackpad container spacing uses the tokens. |
| restyle:walkie | apple/Sources/Copilot/CopilotDashboardView.swift | LAY-5, brief-4, MOT-1, MOT-4, BTN-1, BTN-4 | Regrouped by relationship (LAY-5): picker / (disconnected label, card, persistence error) / (Live Activity control, activity error, explanation). Small gaps inside groups, `Spacing.xLarge` between them. The card radius moved from 24 to the `Radius.card` token and the card declares `liquidGlassContainerShape()`. Switching families now fades the content and springs the layout. The Live Activity status icon swaps with a `.replace` symbol transition. The system segmented Picker and the single full-width `.glassProminent` primary button are kept. |
| restyle:walkie | apple/Sources/Copilot/BuildMonitorView.swift | LAY-1, MOT-6, HIER-3, MOT-4, LAY-3, brief-1 | The empty state now has a clear row background, so it no longer sits in a boxed row card. The status icon uses the existing `BuildActivityState.buildTint`, the same color as the Live Activity card, with a `.replace` symbol transition. The Follow Build glass button gets an explicit capsule shape. The list springs when the followed run or the run list changes. Spacing uses the tokens. Stop Following stays a destructive row button. |
| restyle:walkie | apple/Sources/Copilot/VolumeScrollListView.swift | MOT-4, COL-4, LAY-3 | Volume-button scrolling now uses `withAnimation(LiquidGlassMetrics.spring)` instead of the default curve. The highlighted row gets the `.isSelected` accessibility trait. Preview badge padding uses the tokens. No logic changes to the volume observer or gesture classifier. |
| restyle:walkie | apple/Sources/Copilot/SecureMessaging/SecureMessagingView.swift | FORM-1, FORM-2, FORM-5 | Fixed placeholder-as-label: the peer key, pairing token, and rendezvous URL fields now have a persistent label above them, 8pt from the field (new `labeledField` helper; the visible label is hidden from VoiceOver because the field title carries it). Placeholders are now an instruction or a bare example: "Paste your peer's base64 key", "Generate or paste a token", and the default URL shown verbatim. The old label "Peer public key (base64)" became "Peer public key". Fields keep the system Form styling. |
| restyle:walkie | apple/Sources/Copilot/SecureMessaging/SecureMessagingView.swift | BTN-1, brief-1, MOT-5, COL-2, MOT-6 | Send is now a round prominent glass icon button, `Button("Send", systemImage: "arrow.up").liquidGlassIconButton(prominent: true)`. It is the screen's only prominent action while connected, because Connect is hidden then. The connection status shows a small ProgressView during signaling, hole punching, and handshake, and its text fades on change. The idle dot uses semantic `.secondary` instead of `.gray` and is hidden from VoiceOver. The empty session log shows an icon, matching the Pilot version. |
| restyle:kneeboard | apple/Sources/Plotter/ContentView.swift | LAY-3, brief-5 | Floating control cluster (Settings, Dashboard, connection badge): the GlassEffectContainer and HStack spacing and the cluster padding now use LiquidGlassMetrics.Spacing tokens (xSmall, small). The UIKit annotation toolbar's 12pt safe-area inset now uses the same LiquidGlassMetrics.Spacing.small, so the leading and trailing clusters share one edge from one source. |
| restyle:kneeboard | apple/Sources/Plotter/ContentView.swift | IMG-1, brief-1 | The Dashboard icon button label changed from a bare Image to Label("Dashboard", systemImage:) with .labelStyle(.iconOnly), so the name stays attached to the glyph. The existing .accessibilityLabel("Dashboard") and .help are kept. |
| restyle:kneeboard | apple/Sources/Plotter/ContentView.swift | LAY-3, brief-4 | GlassCircleButtonStyle gains a circleDiameter (48) constant. ConnectionStatusBadge uses it instead of a magic 48, so every circle in the cluster has the same size. |
| restyle:kneeboard | apple/Sources/Plotter/ContentView.swift | MOT-4, BTN-5, brief-4 | ConnectionStatusBadge: the laptop glyph now changes state with .contentTransition(.symbolEffect(.replace)) plus .animation(LiquidGlassMetrics.stateChange, value: connected), keyed on the Bool so per-frame ticks never animate. Added .contentShape(.contextMenuPreview, Circle()) so the long-press or secondary-click 'Forget Paired Cockpit' preview lifts a circle, not a square-cornered rectangle. |
| restyle:kneeboard | apple/Sources/Plotter/ContentView.swift | MOT-5, MOT-3, MOT-1, MOT-6 | SearchingOverlay: the antenna symbol now animates with .symbolEffect(.variableColor.iterative) as the one designed loading motion. I removed the second spinner (ProgressView in the actions slot) so two motions no longer compete. The placeholder is now in a ZStack and fades out with .transition(.opacity) and .animation(LiquidGlassMetrics.stateChange, value: isSearching) when the first frame arrives, instead of cutting. |
| restyle:kneeboard | apple/Sources/Plotter/PlotterDashboardView.swift | BTN-1, BTN-4, COL-4, brief-1, brief-4 | Replaced the private LiveActivityButtonStyle ViewModifier with the shared .liquidGlassButtonStyle(prominent: !isActive): Start is the single glassProminent action and Stop is neutral .glass. Added an explicit .buttonBorderShape(.capsule) and kept the full-width large control. The button moved into a liveActivityButton(isActive:) helper; behavior and the disabled conditions are unchanged. |
| restyle:kneeboard | apple/Sources/Plotter/PlotterDashboardView.swift | LAY-5, FORM-5, MOT-4, BTN-5 | Live Activity panel regrouped by relationship: the heading row plus description form one 8pt group, and the button plus 'Start becomes available...' helper form another 8pt group, with 16pt between the groups. Previously every gap was 12pt. The helper fades in and out (.transition(.opacity)). The panel animates On/Off and button-tier changes with LiquidGlassMetrics.spring (nil under Reduce Motion), and the progress spinner appears with stateChange. |
| restyle:kneeboard | apple/Sources/Plotter/PlotterDashboardView.swift | LAY-4, brief-4, brief-5, COL-2 | Both content panels now use one panelShape built from LiquidGlassMetrics.Radius.card (16, continuous) instead of two hard-coded radius-20 RoundedRectangles. They keep the semantic secondarySystemGroupedBackground fill, not glass, because they are content cards. |
| restyle:kneeboard | apple/Sources/Plotter/PlotterDashboardView.swift | LAY-3, MOT-1, MOT-4 | All spacing and padding literals (24/12/8/4/16/20) now use LiquidGlassMetrics.Spacing tokens with the same values. Switching the dashboard family now animates the panel content and height change with LiquidGlassMetrics.spring (skipped under Reduce Motion) instead of a hard cut. Added @Environment(\.accessibilityReduceMotion). |
| restyle:widgets-watch | apple/Sources/PlotterWidgets/PlotterSnapshotWidget.swift | COL-2, COL-6, TYPE-3, brief-5, brief-7 | Made the widget follow the widget rendering mode. ContentUnavailablePlaceholder no longer draws an opaque Color.black layer (the black stage already comes from .containerBackground(.black, for: .widget), which the system removes in accented / tinted / clear-glass and vibrant modes). In those modes the Color.black layer would have shown as a solid plate. The bottom gradient scrim now draws only when @Environment(\.widgetRenderingMode) == .fullColor, so the black scrim no longer turns into a light wash over the caption in accented or vibrant modes. Placeholder copy, glyph and widgetAccentable are unchanged; the VStack now fills the frame so the content stays centered. |
| restyle:widgets-watch | apple/Sources/PlotterWidgets/PlotterLiveActivity.swift | COL-1, LAY-4, HIER-3, brief-4, brief-6 | Replaced the raw `.gray.opacity(0.3)` thumbnail placeholder with the semantic `.quaternary` hierarchical fill, which resolves correctly on the forced-dark stage. Moved the thumbnail radius into one named constant and documented the concentric math (about 24pt card radius minus the 16pt inset gives 8pt). Added `.keylineTint(isConnected ? .green : nil)` so the Dynamic Island keyline matches the status dot. Added an accessibilityLabel (Connected / Disconnected) to the status dot, which appears alone in compactTrailing. |
| restyle:widgets-watch | apple/Sources/CopilotShared/BuildActivityCard.swift | COL-2, IMG-1, MOT-4 | The stale state is now a Label with an orange wifi.slash glyph and secondary copy, matching DashboardWarningLabel in the dashboard activities and the wifi.slash used in the compact Island. The copy "Updates delayed" is unchanged. The status glyph uses .contentTransition(.symbolEffect(.replace)) and the status text uses .contentTransition(.opacity), so Live Activity updates change in place instead of cutting. Padding and line count are unchanged, so BuildPresentationTests' 70-160pt height bounds still hold. |
| restyle:widgets-watch | apple/Sources/CopilotWidgets/BuildLiveActivity.swift | COL-2, IMG-1, MOT-4 | The expanded Dynamic Island stale line ("Updates delayed · check Cockpit", copy unchanged) uses the same orange-glyph / secondary-text caution Label as the card. The compactLeading status glyph gets the symbol replace content transition. |
| restyle:widgets-watch | apple/Sources/DashboardActivities/DashboardLiveActivities.swift | HIER-3, COL-2, MOT-4, TYPE-4 | Added a private DashboardIslandLabel for the expanded leading region of the Actions, AI Usage and Runners Islands. Its glyph carries the family tint already used by the compact, minimal and keyline views, and the title stays primary text (before, the expanded Label was untinted while the compact glyph was blue/purple). Expanded trailing and compactTrailing counts and costs now use .monospacedDigit() (expanded trailing lacked it) and .contentTransition(.numericText(value:)), so values roll on update. |
| restyle:widgets-watch | apple/Sources/DashboardShared/DashboardPresentation.swift | MOT-4 | DashboardMetric values and the usage cost headline use .contentTransition(.numericText(value:)), so timeline reloads roll the numbers instead of cutting. Nothing else changed: the header, metric, row, empty and stale views were already on text styles, semantic and system colors, widgetAccentable anchors and a 4pt grid. |
| restyle:widgets-watch | apple/Sources/Wingman/Wingman Watch App/ContentView.swift | MOT-4, BTN-1, BTN-4, brief-1, brief-7 | The delivery-status text cross-fades with .contentTransition(.opacity) plus an .easeOut(0.15) animation keyed on deliveryStatus. The gesture readout now has a .spring(duration: 0.3, bounce: 0.15) animation keyed on currentIcon, which drives the existing symbol replace transition and the label cross-fade. The connection dot is accessibilityHidden because the adjacent text already states the connection. The primary "Send to Walkie" button was already .glassProminent, full width, with no hand clipping; it is unchanged. |
| sweep:cockpit | apple/Sources/Pilot/WorkspaceView.swift | LAY-6, BTN-1 | Empty-panes state: the six capsule 'add pane' glass buttons now sit in a ViewThatFits. They show as one row when the pane is wide enough and as two rows of three when it is narrow (for example an Extendo window), so they no longer clip. The editor button keeps its disabled state and help text through a new addPaneButtons(_:) helper. A static emptyPaneKinds list keeps the order Terminal, Browser, Device, Simulator, Android, Editor. Everything stays inside the existing CompatGlassContainer. |
| sweep:cockpit | apple/Sources/Pilot/WorkspaceView.swift | BTN-5 | CollapsedPaneSlit: the button covering the whole slit now uses .liquidGlassPressable(cornerRadius: 0) instead of .plain, so the unhide target shows a hover wash and press feedback. The action and the 'Unhide <kind>' accessibility label are unchanged. The wash is square because the slit is a pane edge, not a control. |
| sweep:cockpit | apple/Sources/Pilot/NewWorkspaceSheet.swift | FORM-1 | The new visible 'Starting Folder' label is now hidden from accessibility, because the field already has .accessibilityLabel("Starting Folder"). This stops VoiceOver from reading the name twice, and matches the fieldGroup pattern in RemoteDesktopView. |
| sweep:walkie-shared | apple/Sources/Copilot/ContentView.swift | BTN-5, LAY-4, brief-4 | Regression fix: TabSwitcherBar halves had lost their `.contentShape(Rectangle())`. With `.liquidGlassPressable(cornerRadius: barHeight / 2)` each half's hit shape was a 32pt-radius rounded rect, so the inner corners at the bar's center (where the label ignores touches) stopped responding to taps. The halves now use `.liquidGlassPressable(cornerRadius: 0)`, so the full rectangle is tappable again, and the bar is clipped with `.clipShape(Capsule())` so each pressed wash is exactly one half of the glass capsule. Accessibility labels (Previous Tab / Next Tab) are kept, and the barHeight doc comment is corrected. |
| sweep:walkie-shared | apple/Sources/Copilot/ContentView.swift | TYPE-3, COL-4, MOT-4, brief-6 | Walkie HUD recording label: the red is now only on the pulsing mic glyph and the footnote copy stays primary, because red footnote text on the glass HUD fails contrast. The copy is unchanged. Also added a spring animation keyed on `walkie.statusMessage`, so an idle status message alone shows or hides the HUD with its transition, not only phase changes. |
| sweep:walkie-shared | apple/Sources/Copilot/CopilotDashboardView.swift | TYPE-3, COL-2, COL-4 | The disconnected, persistence-error and Live Activity error lines no longer use orange or red footnote text. A new private `cautionLabel(_:systemImage:tint:)` puts the tint on the glyph only; the disconnected line keeps secondary text and the errors keep primary text. The 'Live Activity is on/off' status likewise moves the green to the glyph (keeping the symbol replace transition) and leaves the text secondary. Copy and localization are unchanged: string literals still go through Text(LocalizedStringKey) and runtime error strings are still verbatim. |
| sweep:walkie-shared | apple/Sources/Shared/SettingsView.swift | TYPE-3, COL-2 | 'Synced' header badge: the green is now on the checkmark glyph only and the caption2 text is primary, because green caption text on a 15% green capsule fails contrast. The badge stays a non-glass content badge with the same transition and animation. Shared across Copilot, Plotter and Pilot. |
| sweep:kneeboard-trigger-widgets | apple/Sources/Plotter/PlotterDashboardView.swift | TYPE-3, COL-1, COL-2 | Fixed the contrast of the Live Activity On/Off badge. The caption text was green on a 12% green wash, roughly 2:1 contrast in light mode. The text is now primary when On and secondary when Off. The green state signal moves to the capsule fill (green at 20% opacity), and Off uses the semantic .fill.tertiary instead of Color.secondary.opacity(0.12). Copy and layout are unchanged. |
| sweep:kneeboard-trigger-widgets | apple/Sources/Plotter/PlotterDashboardView.swift | TYPE-3, COL-4 | Moved both error labels (dashboardError, activities.lastError) into one errorLabel(_:) helper. The red now sits only on the exclamationmark.triangle.fill glyph and the footnote copy is primary text, because system red on the light grouped background is below small-text contrast. The message strings are unchanged. This matches the 'state color on glyph, copy neutral' pattern the branch already uses in DashboardPresentation. |
| sweep:kneeboard-trigger-widgets | apple/Sources/PlotterWidgets/PlotterLiveActivity.swift | outside catalog (accessibility) | Fixed an accessibility regression from the branch. The new accessibilityLabel on statusDot was applied in every placement, so on the Lock Screen and in the expanded Island VoiceOver would read the state twice ('Disconnected' from the state line, then 'Disconnected' from the dot). statusDot now takes a speaksState parameter. The compact-trailing dot, which stands alone, keeps an explicit accessibility element with the Connected/Disconnected label. The Lock Screen and expanded-trailing dots are hidden from accessibility. |
| visual | apple/Sources/Plotter/ContentView.swift | COL-1, COL-2, brief-5, brief-6 | Kneeboard's mirror stage is always black. In light mode, its floating glass controls (the Settings / Dashboard / connection cluster and the UIKit annotation toolbar) showed as flat gray disks, and the green laptop glyph had about 1.6:1 contrast. Both are now pinned dark: `.environment(\.colorScheme, .dark)` on the SwiftUI cluster and `toolbarGlass.overrideUserInterfaceStyle = .dark` on the toolbar. This matches the existing SearchingOverlay rule for the stage. |
| visual | apple/Sources/Plotter/ContentView.swift | COL-2 | Follow-up to the dark pinning: the shared SettingsButton presents its own sheet, so the Settings sheet came out dark in light mode. In Kneeboard only, it is replaced with an inline ellipsis Button that keeps the same "Settings" accessibility label and glass circle style. A `.sheet { SettingsScreen() }` is now presented from the ZStack, so Settings follows the system appearance again. The Dashboard sheet already followed it. Also updated a doc comment on GlassCircleButtonStyle that no longer applied. |
| visual | apple/Tests/PilotTests/Snapshots/SnapshotWorkbench.swift | brief-3, brief-4, LAY-4 | The stand-in Notes tabs in the capture harness were squared rounded rectangles (radius 7), but the real NotesView tabs are capsules. Changed them to an opaque Capsule so the landing-page screenshots match the restyled app. |

### Closeout (round 2)

Decided: controls inside glass panels, sheets, and popovers are glass, following the system's own 26/27 sheets. That covers the remote-computer picker and the Chromium find popover. Field rule: free-standing fields, fields in panels, sheets, and popovers, and Form rows with their own stacked label are glass. These keep system styling: macOS grouped-Form rows whose title is the row label, fields already hosted inside a toolbar glass capsule or glass palette, and system alert fields, which cannot be styled.

- Kneeboard: the floating circle buttons, the connection badge, and the UIKit annotation toolbar share one `@ScaledMetric` (48pt at default). They scale together with Dynamic Type and are capped at AX2 so the two clusters never collide on iPad mini (TYPE-4, LAY-3).
- Walkie Secure Messaging fields and the remote-computer host field adopt `.liquidGlassField` (FORM-1/FORM-4).
- Glass chips gain a pointer hover wash (BTN-5).
- Docker row actions show for keyboard focus and VoiceOver and are exposed as accessibility actions. Fast Command play/stop have labels.
- Pane launcher menus drop the deprecated borderless menu style.
- Dynamic Island expanded dashboard Live Activities: no duplicate header, at most two rows, and an inset that clears the Island's curved corners (HIER-3, LAY-2).
- Trigger: the root tint is wired, so the glyph and the one `.glassProminent` action no longer fall back to gray (BTN-1, COL-4).
- `CopilotUITests` is `@MainActor`, like `PlotterUITests`, so it compiles under Swift 6. It was broken at the base commit too.
- Visually verified in the simulator: Trigger (dark; watchOS has no light mode), the Walkie widget gallery in all nine kind/size pages, the dashboard Live Activities on the Lock Screen and in the compact and expanded Island, Walkie Secure Messaging, and Kneeboard from default size through accessibility sizes. The real Cockpit glass window cannot be captured without granting Screen Recording, so Cockpit was checked with the headless harness only.

- Every text input is now Liquid Glass. The Cockpit text-entry alerts (New/Rename Workspace Group, Rename Group) became `TextPromptSheet`, a glass sheet with a persistent label, a glass field, glass Cancel, and a prominent Create/Save button. Cockpit Secure Messaging and the Runners Edit Device sheet use stacked labels with glass fields. The only plain fields are the URL bar, Fast Command, and quick open, which already sit inside a glass toolbar capsule or a glass palette.
- PilotTests: the TLS fixture imported its PKCS#12 identity into the login keychain, where the ACL was pinned to one build's cdhash. Every rebuilt test host then blocked on keychain consent, which stalled Network.framework and cascaded into all 15 Docker, TLS, remote-desktop, and WebKit failures. With `kSecImportToMemoryOnly`, the full suite passes: PilotTests 813/0, SharedTests 208/0, PlotterTests 4/0.

### Cockpit real-glass visual pass (macOS 26 VM)

Cockpit was run with `-demoMode YES` inside a tart macOS 26.6 VM. The guest window server renders real Liquid Glass, and the screen was read over VNC, so no host Screen Recording grant was needed. Every major surface was captured in light and dark, about 75 captures, then reviewed by a second, independent reviewer. Each fix was confirmed in a fresh capture.

- Systemic (brief-3, LAY-4): macOS 26 draws glass and bordered buttons, pop-up pickers, and segmented pickers as squared rounded rectangles unless `buttonBorderShape(.capsule)` is set. The compat glass button styles now apply the capsule shape, and so does the root of `ContentView`. Icon circles keep their innermost `.circle`.
- `GlassChipScroller`: horizontal glass chip strips (Notes tabs, Remote Desktop groups, Runners sources) no longer clip the glass shadow into a hard gray rectangle in light mode.
- Contrast (TYPE-3): the Remote Desktop "Empty Slot" label goes from 2:1 to 6.3:1, and the browser start-page hint from 1.9:1 to 5.9:1.
- Device, Simulator, and Android panes: empty-state actions stack in narrow panes instead of truncating ("Open Cam…").
- Agentic Use: the header stays pinned at the top in empty, failed, and scanning states.
- Runners: no lone `+` in an empty scope strip.
- New Workspace: no full-width separators.
- `TextPromptSheet`: the placeholder is now a bare example (FORM-2).
- Inspector PRs, Actions, and Tasks: a failed `gh` read reads as "Couldn't Load …", with a plain-language cause and one Retry (MOT-6, HIER-2). "No open pull requests" appears only after a successful empty read. A failed poll keeps the last good list.
- Copy: "Cockpit talks to…" (it said Pilot).

Not reachable in the VM: populated data states (no agent logs, container engine, or gh auth in the guest), live device and simulator streams, a live remote-desktop session, and the Chromium find bar.

### Populated-data pass (real glass and simulators)

Cockpit ran in the macOS 26 VM with guest-only fixtures: synthetic Claude, Codex, Grok, and Kimi session logs, a stand-in `gh` answering exactly the calls Cockpit makes, a fake Docker Engine socket, HTTPS stand-ins for the Claude and Codex usage endpoints, and a live Screen Sharing session to the guest itself. Walkie and Kneeboard ran in the iPhone and iPad simulators with dashboard and build fixtures in their app-group containers, in light, dark, and AX3. Each pass had a reviewer and an independent critic, and every fix was re-captured.

- Contrast (TYPE-3): tinted text on its own tint wash measured about 2:1. Runner status, the plan badges, the terminal agent badge, and the unpriced badge now keep the hue in the dot or wash with primary text. Chart y-axis labels go from 1.85:1 to 3.87:1 in light. Usage meters keep the provider color until 90%.
- Agentic Use: tooltips no longer clip at the chart edge; sub-dollar axes read `$0.05`; the metric picker no longer slides with the title width; KPI captions align across cards; Token Flow groups models by provider (covered by a test).
- Inspector, Docker, and Runners: Actions SHAs never wrap and the metadata degrades gracefully; Docker port columns line up; runner labels do not break at hyphens; the edit button no longer fights the hover popover; filter results read "N of M runners".
- Remote Desktop: the selected tile header is legible over the live session, and the connect form fits short tiles.
- Walkie and Kneeboard dashboards (DashboardShared): headers, status glyphs, row subtitles, and metric columns adapt at accessibility sizes instead of truncating or overlapping. Stop Live Activity is neutral glass in both apps, and the segment reads "AI Usage" everywhere.
- Walkie build monitor: Stop Following is a glass action, no doubled "Queued", and a tighter status row.
- Walkie Settings: an empty stored peer key no longer shows a "Synced" badge. This is display only; pinning still reads `DeviceIdentity` directly.
- Kneeboard: the PencilKit tool picker hides while a sheet is up. The floating glass cluster uses the UIKit corner-adapted safe area (`.safeArea(cornerAdaptation: .horizontal)`), so in a resized iPadOS window it starts clear of the window controls. The annotation toolbar moves to a second row when both clusters cannot fit.

Still not reviewable in this pass: the Runners 3D Fleet (the VM's paravirtual GPU asserts) and live Simulator, Device, and Android streams. The macOS 27 pass below covers them.

Finding outside design scope: when nothing is paired, the pairing store reports the peer key as an empty string, and `BuildActivityController` and `BuildPushCoordinator` accept it in their `guard let peerKey` checks. Normalizing that belongs to a security-reviewed change, not this pass. It is fixed in the macOS 27 pass below.

### macOS 27 pass, live streams, and peer-key hardening

Cockpit ran in a macOS 27.2 tart VM (`ghcr.io/cirruslabs/macos-runner:golden-gate`, Xcode 27.2, iOS 27 runtimes) with the same guest-only fixtures, plus a guest-only stand-in `adb` that answers the exact commands `AdbBridge` runs and streams a looping H.264 phone clip for `screenrecord`. A reviewer captured light and dark, and an independent critic re-read the captures and the diff.

- macOS 27 against the 26 captures: no glass regressions. Toolbar groups, the pane launcher, sidebar, inspector tabs, the Docker filter field and switch, Agentic Use, Remote Desktop, Runners, Settings, the sheets, popovers, and menus all match. Control heights are unchanged.
- Runners 3D Fleet: the VM crash comes from SceneKit's two-pass bloom. The paravirtual Metal driver cannot back the per-mip texture views and asserts in `AppleParavirtTexture`; every other scene feature renders. Cockpit now uses one bloom pass when the Metal device is paravirtual and two everywhere else, so real hardware is unchanged and the fleet renders in VMs.
- Fleet fixes: back-row captions no longer sit on the lids of taller cases in front (row spacing 31 → 36, plus a text scrim; COL-6). The details popover takes `.preferredColorScheme(.dark)`, so its glass matches its white text in light mode (TYPE-3). The Idle and Offline legend swatches get a hairline rim.
- Simulator pane: live iPhone 18 Pro (iOS 27.0) stream, toolbar, and Command-drag export all checked; no chrome defects. Device-specific runtimes now read "iOS 27.2 (iPhone19,4)" instead of "iOS 27.2.iPhone19.4" (HIER-5), with a test.
- Android pane: live stream, taps, swipes, and the Back/Home/App Switch keys all work. Fixed a real bug: `adb emu avd name` replies in CRLF, which Swift treats as one character, so running emulators never matched their AVD and were offered for boot again. The parsed name must now pass the same allowlist as `-list-avds` output, with a test. Rows show the AVD name ("Pixel 9 API 36") instead of the shared "sdk gphone64 arm64" model, and a restored pane is titled "Android".
- Device (USB) pane: the live stream needs a physical iPhone, so only its non-live states were checked on 27 (permission, header, empty state, disabled toolbar).

Security: an unpaired store reports the peer pin as `""`, which `BuildActivityController` (Walkie) and `BuildPushCoordinator` (Cockpit) accepted as a key. A monitor could start or restore and keep polling while unpaired. `DeviceIdentity.peerPublicKeyBase64()` now returns `nil` unless the stored pin parses as an X25519 key, and both coordinators normalize again. `pairingDecision` treats an unparsable pin as first pairing. Every path is equal or stricter: nothing that was refused is now allowed, and the only label change (Pair instead of Trust New Key for a malformed pin) cannot happen in production. Walkie shows "Pair Walkie with Cockpit to follow a build." Covered by `PairedPeerKeyTests` and `BuildPushCoordinatorPairingTests`. SecureMessagingView's peer-key field shares the PeerSync pin's Keychain slot; the follow-up below stops it writing malformed text there.

Verification: `build-ci.sh`, `test.sh all` (PilotTests 819 passed, 2 CEF skips; SharedTests 214; PlotterTests 4), `lint-swift.sh --all`, `app-icon-tool.swift validate`, `check-docs.sh`, and the Copilot and Plotter UI tests all pass.

### Last fields, real Android emulator, and pin writes

- Every text input is now glass, with no exceptions. The terminal Fast Command and browser URL fields each have their own toolbar item, with the shared toolbar capsule hidden (`compatSharedBackgroundHidden()`), so the field's glass capsule is the only layer. Both take the toolbar control height (36pt on macOS 27.2) to line up with their neighbors, and the reload button nests concentrically in the URL capsule (LAY-4). Quick-open is Spotlight-style: a glass search capsule and a separate glass results card that hugs short lists.
- Focus ring (FORM-4): `@FocusState` never becomes true for a field in an `NSToolbar` item on macOS 27.2. The two toolbar fields read editing state from the window's first responder instead (`toolbarFieldEditing`). This also fixes a page load overwriting a URL the user was still typing.
- Android, against a real emulator (the host's `Medium_Phone_API_35`, through the host adb server): the picker shows "Medium Phone API 35" (the CRLF fix), and tap, swipe, Back, and Home work. Fixed: a still screen never showed a frame. `FileHandle.read(upToCount:)` waited for 64 KB, and the Annex-B parser held the last frame until the next one began. The reader now uses `poll`/`read(2)` and flushes the buffered tail after 100ms of silence; if the next bytes do not begin a new frame, it resets and requests a keyframe. This reverses the earlier flush-only-at-EOF rule, so a cut-short frame can flash before the resync.
- Secure messaging: the peer-key field is the shared PeerSync pin, and it used to save any text on disappear. Now only a canonical base64 X25519 key is written. An emptied field still unpairs. Malformed text leaves the pin untouched and shows an inline error under the field (FORM-4). Connect gates on the same check. Every write path is equal or stricter, covered by `PairedPeerKeyTests`.
- Not verifiable here: the wireless Device pane advertises its AirPlay receiver in the VM, but tart's shared network blocks VM-to-VM traffic, so no Mac sender could mirror into it. The USB Device stream needs an iPhone on a cable. Both need a physical iPhone.
- Open, unchanged: ⌘L does not focus the URL field when the browser is already selected (pre-existing). Unfocused URL text in dark mode measures about 4.2:1 against the system toolbar blend. Quick-open file paths use the system secondary color.

Verification: `build-ci.sh`, `test.sh all` (PilotTests 819 passed, 2 CEF skips; SharedTests 218; PlotterTests 4), `lint-swift.sh --all`, `app-icon-tool.swift validate`, `check-docs.sh`, and the Copilot and Plotter UI tests all pass.

### Coverage round: every remaining surface

An inventory listed 45 surface groups that no earlier capture had reached (55 rows once split by state). Each was then captured in light and dark mode on real glass: Cockpit in the macOS 27.2 VM, Walkie and Kneeboard in the iOS/iPadOS 27.2 simulators, and Trigger in the watchOS simulator. An independent critic re-read every capture against the zandesign checks. Hard-to-reach states use DEBUG-only fixtures: Cockpit's `-demoPairingPrompt`, `-demoPeerRecording`, `-demoPeersConnected` and `-demoSecureMessaging`, and Walkie's `-demoScenario <name>`. A fixture prompt only dismisses itself and never resolves a real pairing request. Copilot's compilation conditions now inherit `DEBUG` (`$(inherited)` in `project.yml`), so these fixtures compile in Debug and are absent from Release.

Result: of the 55 rows, 51 are covered on real glass and 1 is unreachable by design (No Panes; the last pane can't be closed). Two are partly covered: the wireless Device pane (every state except a live stream) and the Chromium wallet popup (the button and tooltip, not the popup content). One is not captured: the USB Device stream. Both rounds below were recaptured in the VM and simulators after the fixes.

Fixes from the coverage round, then from the recapture of those fixes:

- Cockpit:
  - The Actions inspector shows skeleton cards on first load instead of "No Actions" (MOT-5). The empty or error state then stays put during the 30s poll instead of flickering.
  - Toasts in the device, Simulator and Android panes sit on a dark capsule inside the glass. They measure 13.6–15.9:1 over a pure-white phone screen and over the home wallpaper; before this they measured 1.96–3.6:1 (TYPE-3).
  - The Wireless header steps down to icon-only buttons in narrow panes. Its row spans the pane, and both icon circles are the same size.
  - Device picker titles truncate to one line with the full name in the tooltip, instead of breaking mid-word.
  - The start page keeps the port visible: the URL truncates from the front, and the hotkey badge drops first.
  - ⌘C copies a Simulator screenshot.
  - Panes now have a 160pt minimum width. Dragging one divider no longer resizes the panes that aren't part of the drag. When the window is too narrow to give every pane 160pt, device-pane messages and the Wireless instructions switch to a glyph layout at the measured width where their longest word stops fitting, so no word ever breaks ("De- / vice / s"); checked from 100 to 200pt. The text moves to the tooltip and VoiceOver label, and the Wireless pane keeps the pairing code and icon-only Start and Try Again buttons. The receiver name shrinks to fit on one line rather than breaking.
  - Cleared earlier in the round: ⌘L focuses the URL field when the browser is already selected; unfocused URL text and quick-open paths meet 4.5:1; and empty states, the Lasso glyph, menus, inline rename, ink controls, PR placeholders and Docker errors were tidied.
- Cockpit hang (it predates this branch): hiding a terminal pane in a narrow window while the wireless receiver ran froze the app in a SwiftUI layout cycle. `GhosttyMetalView` set `isHidden` inside `updateNSView`, and AppKit's key-view rebuild re-entered SwiftUI's focus graph mid-update. The hide now waits for the next main-queue turn and applies whatever state is current then.
- Walkie:
  - The speech storage sheet offers Cancel Download, or Cancel Loading for a cached model, while a load runs.
  - It stacks the progress row at accessibility text sizes and lines up every row separator.
  - It keeps the error message when opened from the "Transcription Unavailable" alert.
  - The model banner sits in the safe-area inset.
  - Fixed during review: a fixture alert no longer resolves a real pending pairing request.
- Widgets and Live Activities (shared by Walkie, Kneeboard and Cockpit): the status tints and secondary text are named colors in `DashboardColors.xcassets`, resolved when the system draws the widget. Tints resolved inside the extension had drawn undarkened on the macOS desktop. On the light macOS 27.2 desktop all five tones measure 4.79–4.91:1 and secondary text 5.33:1, up from 2.22:1 for green and 2.31:1 for orange. Accented rendering keeps the system colors. The large AI Usage widget fills its height with the token split and a bar per plan.
- Kneeboard and Trigger: badge menu, bounded ImageIO snapshot thumbnails (640/320px), Builds link, Runners lock-screen row and contrast fixes.

Closing rounds, each recaptured after the fix:

- Cockpit:
  - Hidden and occluded terminals report occlusion to Ghostty (`ghostty_surface_set_occlusion`), so `drawFrame` stops while they're off screen. Ghostty still rebuilds rows for incoming output; only its drawing checks visibility.
  - The "Changes could not be saved" alert is reviewable with the DEBUG `-demoPersistenceFailure YES` fixture. Its text measures 9.6–13.3:1 and Retry is the only prominent button.
  - Remote Desktop's picker stays dark over the black canvas, with secondary text at 7.3:1 instead of 3.2:1. An open picker recovers on its own after Local Network access is granted, and the Settings button's tooltip says to choose Local Network (macOS 27.2 opens the top of Privacy & Security).
  - Browser Find in Page is an in-pane glass find bar for both engines, with Edit ▸ Find…, Find Next and Find Previous. ⌘F means Find only while a browser pane is selected and is Focus Selected Pane everywhere else. Typing selects the first match and Return advances.
  - Chromium JavaScript dialogs are window sheets titled by the page's origin. Page text is capped at 1,000 characters, stripped of control and bidi characters, and shown as plain text. beforeunload reads Leave/Stay, Stay is the default, and a page that floods dialogs is throttled. Text measures 6.7–14.9:1.
  - A failed Chromium load shows only Chromium's error page and its Reload button, not a second Retry.
  - Chromium settings use legible secondary text and darkened state tints, and settings search finds "Chromium".
  - Chromium crash (it predates this branch): SwiftUI's App lifecycle creates its own `NSApplication` subclass and ignores `NSPrincipalClass`, so `PilotApplication` never ran. CEF crashed on `-isHandlingSendEvent` once the wallet button could be clicked, and quitting skipped `CefShutdown`. ChromiumKit now adds `CefAppProtocol` and the `sendEvent:` wrapper to the real `NSApp` class at launch. A Chromium-only app delegate cancels the quit, shuts CEF down (capped at 5 seconds), then quits again. A logout, restart or shutdown quit, read from the quit Apple Event, exits at once. The wallet button now appears, survives a minute of use and ⌘Q exits cleanly in the VM. Its tooltip resolves `__MSG_` names from the extension's bounded `messages.json`.
- Walkie and Kneeboard: grouped-list headers, footers and secondary rows; the speech storage sheet; dashboard sheets and empty states all use the legible gray (5.3–6.7:1 in both modes, from 3.3–4.0:1 in light). The Kneeboard Off chip uses primary text (10.7:1 dark). The `modelLoadingCached` fixture shows the stored size.

Not capturable here:
- USB Device stream: the pane needs the screen-capture device macOS publishes only for a physical iPhone on a USB cable. The simulator doesn't provide one, the VM tool (tart 2.41.1) has no USB passthrough, and acting on a physical device is out of bounds for this review.
- Wireless live stream: it needs a Screen Mirroring sender. The only one available is a macOS VM, and its Screen Mirroring menu lists no receivers. The simulator has no Screen Mirroring, and every other sender is a physical device. Every other wireless state is covered.
- Actions "No Actions" empty state: the test `gh` stand-in can't return zero runs; the overlay logic is unit-tested.

Left open: see the control audit below, which resolves the wallet popup, the quit and logout paths, and the widget modes.

Verification: `build-ci.sh`, `test.sh all` (PilotTests 864 passed with 2 CEF skips, SharedTests 232, PlotterTests 4), `lint-swift.sh --all` (0 violations in 359 files), `app-icon-tool.swift validate`, `check-docs.sh`, the Copilot (1/1) and Plotter (2/2) UI tests on the iOS 27.2 simulators, the Chromium configuration build, and an XcodeGen drift check all pass.

### Control audit and final round

Every button, field, menu, picker and toggle in Cockpit, Walkie, Kneeboard and Trigger was listed and checked one by one: 380 controls. 162 use the repo's glass styles (`compatGlassButtonStyle`, `compatGlassProminentButtonStyle`, `compatGlassIconButton`, `liquidGlassField` and the glass containers). 144 are system controls that the 27 SDK already draws in Liquid Glass (segmented pickers, toggles, menus, toolbar items, alert and sheet buttons). 64 stay plain on purpose: inline text links, list rows, the terminal and editor surfaces, and controls drawn by web content. The other 10 had a squared or plain style and now use glass with a capsule shape: the extension window buttons, the Notes Word Wrap menu, the GitHub task "#N" button, the Agentic Use daily-chart controls, the Runners toolbar, Setup, the Wireless and Device pane buttons, and Remote Desktop.

Fixes from the audit, each checked in the macOS 27.2 VM or the 27.2 simulators:

- Cockpit:
  - Selected segmented-picker labels were white on the system accent at 3.9:1 dark and 4.2:1 light. `.legibleSegmentedPicker()` darkens the user's own accent until white text reaches 5.2:1, which measures 5.0–5.6:1 on screen across all five segmented pickers. Unit tests cover every system accent.
  - The Wireless pane switches to its compact layout in narrow panes in every state. The pane width now comes from a `GeometryReader`; before, the overflowing content reported its own width, so the compact layout never appeared and the header clipped. Checked at 60–160pt, stopped and waiting.
  - Secondary text in the Edit Device and Add Runner sheets and in the runner and model popovers measures 6.7–7.0:1 (3.95:1 before). Text that sets `.secondary` itself needs the legible gray set directly; a sheet-wide `legibleSecondaryHierarchy()` doesn't reach it.
  - Workspace tab titles, note tabs, Remote Desktop titles and the sidebar LLM gauge were tap-only. They now expose the button trait and the same action to VoiceOver. The tab reads as `AXButton` with its selection state in the VM accessibility tree.
  - Inspector section headers use the legible gray instead of system secondary (3.2:1 on inspector glass), and Chromium status messages wrap at word boundaries instead of hyphenating ("avail- / able").
  - The Notes gutter and color-chip buttons respond to VoiceOver presses, and the Walkie transcript has a Share button.
  - The Chromium wallet popup shows the real Rabby UI. It opens Chrome-style in its own CEF-owned window, because CEF forces Alloy style on a browser hosted inside an `NSView`. Windows an extension opens on its own are hidden and closed, and the popup can't navigate outside the extension.
  - Quit paths, run in the VM: ⌘Q with Chromium panes ends with `exit_type` Normal. A logout exits at once, and a cancelled logout followed by ⌘Q also ends Normal. If Chromium hangs the main thread during a quit, a backstop ends the process (6.5s in the VM).
  - After one unclean exit, Chromium kept `profile.exit_type` at "Crashed" forever, because CEF never shows Chrome's "Restore pages?" prompt. That brought the previous session's session cookies back on every launch. A clean shutdown now records "Normal" before `CefShutdown`; a kill, logout or backstop exit still reads as a crash. This cause is inferred from the VM runs; there was no Chromium source to read.
- Widgets: tinted (accented), clear (vibrant) and StandBy night modes can't be set in the simulator, so every widget family was rendered offline in each mode (293 renders). The fixes from those renders: accent-group status text in tinted mode, the Actions title, Build Activity captions, the Kneeboard snapshot gradient, and the Mirror status line, which now sits in its own strip in accented and vibrant modes (9.8–16.3:1, and 5.6:1 in StandBy night). In tinted mode the mirrored still renders in full color, like a photo: `.accentedDesaturated` flattened a bright window into a near-solid tinted plate, so the Mac screen it mirrors was no longer recognizable.

Not capturable here:
- USB Device stream and wireless live stream, for the reasons above.
- Tinted Home Screen and StandBy on device; the offline renders approximate the system compositor.
- The sidebar LLM gauge's button role on screen: it needs a coding agent under tmux, and the VM has no tmux without a download.
- VoiceOver itself; the button traits were checked in the accessibility tree.

Left open:
- When a terminal has keyboard focus, the first click into a Chromium page field doesn't take keyboard focus (predates this branch).
- White text on the system prominent blue button measures 3.8–4.0:1 app-wide; it's the platform's style.

Verification: `build-ci.sh`, `test.sh all` (PilotTests 876 passed with 2 CEF skips, SharedTests 232, PlotterTests 4), `lint-swift.sh --all` (0 violations in 359 files), `app-icon-tool.swift validate`, `check-docs.sh`, the Copilot (1/1) and Plotter (2/2) UI tests on the iOS 27.2 simulators, the Chromium configuration build, and an XcodeGen drift check all pass.

### Open items from round 1 (resolved above unless noted)

- Glass buttons sit inside floating glass panels in the RemoteComputerPicker (Close, Connect, Open Local Network Settings) and the Chromium find popover. This matches how system popovers and sheets behave on 26, but it is technically glass on glass. Simplifying it would mean the panel buttons use pressable or plain styles, which works against brief item 1. This needs a product decision.
- The sidebar rename field (liquidGlassField) and the sidebar status cluster (glass circles) sit on the macOS 26 glass sidebar. This is the same layering the system uses for the sidebar search field, but it should be checked visually.
- Many .compatGlassButtonStyle() call sites, such as Setup navigation, Runners Retry, Docker Retry/Open Docker Desktop, Editor 'Find File…', Notes 'New Note' and Settings buttons, rely on the automatic border shape. Others set .buttonBorderShape(.capsule) explicitly. If macOS 26 resolves .automatic glass to a rounded rectangle at some control sizes, those buttons will look inconsistent. Forcing capsule inside compatGlassButtonStyle would override the outer .circle shape on icon buttons, because the innermost environment value wins, so it would need to be added per call site.
- Pane tab close/hide buttons are only roughly concentric with the capsule tab: 18pt circles in a 28pt capsule with an 8pt horizontal inset, when 5pt would be exact. Using a 4pt inset gets closer but crowds the title when not hovering.
- TerminalFastCommandToolbarActions play/stop buttons, which were not in this diff, have no explicit accessibility labels and rely on SF Symbol names plus .help.
- DockerContainerRow actions are drawn at 0.001 opacity until hover, so keyboard and VoiceOver users reach invisible buttons. The context menu duplicates the actions. This was in place before the pass and was not changed.
- Nothing has been compiled. The Verify phase must build Pilot and look at it in light and dark mode at narrow widths: the 180pt sidebar with five status circles, the Extendo empty-panes layout, and the Docker filter field.
- LiquidGlassChipButtonStyle has press feedback but no hover wash on pointer platforms (macOS/iPadOS pointer); it relies on interactive glass. Consider adding the HoverHighlight-style `onHover` wash for BTN-5 parity with LiquidGlassPressableButtonStyle. Not changed, because this foundation helper is used by other sweepers' scopes.
- Toolbar device-status glyphs use system green for connected (about 2.2:1 against light backgrounds). They are non-text icons, and the meaning is also carried by symbol fill and VoiceOver; left for product review.
- The model-loading banner's large Cancel glass button is somewhat taller than its neighboring single-line status capsule; worth a visual check on device for height parity.
- Not built or run (per instructions); the Verify phase must compile Copilot, Plotter and Pilot, since SettingsView is shared.
- GlassCircleButtonStyle (Plotter ContentView) fixes the glyph box at 34pt, and ConnectionStatusBadge hard-codes circleDiameter = 48. Two consequences: (a) the circles do not scale with Dynamic Type, so title3 glyphs can overflow the 34pt box at accessibility sizes (TYPE-4); (b) the 48pt badge only matches the .glass circle buttons if the system's regular glass padding is exactly 7pt, which can only be checked on device or in a screenshot. Fixing this needs a @ScaledMetric box shared by the button style and the badge, plus visual verification. It was left for a pass that can run the app.
- GlassEffectContainer(spacing: 8) wraps an HStack(spacing: 8), so the three circles sit exactly at the merge threshold and may draw liquid bridges between them. The code says this blending is intended; it needs a screenshot to confirm it reads as a cluster, not as smeared shapes.
- The UIKit annotation toolbar uses directionalLayoutMargins of 2/4pt (the 2pt vertical margin is off the 4pt grid, LAY-3) and a fixed 44pt button size that does not grow with Dynamic Type. This is pre-existing and was left alone, because the toolbar's 48pt height is matched to the SwiftUI circles.
- Not visually verified: Cockpit (Pilot) live app: running it with -demoMode and capturing the window needs Screen Recording permission (TCC), so it was skipped. Only the headless capture-pilot-scenes.py harness was used.
- Not visually verified: Cockpit glass cannot be judged from the harness. As docs/cockpit-snapshots.md says, it swaps native Liquid Glass for opaque stand-ins, and it renders AppKit controls offscreen. The result: system segmented pickers (Agentic Use range and metric, inspector tabs) look like squared older-style controls; the Runners scope-chip NSScrollView shows as a solid white bar; the SceneKit runner fleet comes out blank, which makes the legend look illegible in dark mode. All of these are harness artifacts, not app defects, and were not changed.
- Not visually verified: Walkie and Kneeboard dashboards show only empty states: demo mode seeds workspaces but not dashboard or build snapshots, so populated widget cards, followed-build rows and an enabled Start Live Activity button could not be seen.
- Not visually verified: Kneeboard AI Usage tab: the driver tapped "Usage" but the segment is labeled "AI Usage", so that one screen was skipped. It uses the same layout as Actions and Runners.
- Not visually verified: Walkie recording and transcript HUD, model-download banner, pairing alerts and SecureMessagingView: these need a live peer or a speech model, and demo mode hides the walkie HUD.
- Not visually verified: Trigger (Wingman, watchOS), widgets and Live Activities: not captured in this pass.
- Not visually verified: `simctl openurl` deep links (walkie://...) open a system "Open in Walkie?" dialog, so they were not used. Screens were reached instead with a scratch XCUITest driver at /private/tmp/claude-501/-Users-joeblau-Developer-joeblau-src-made/b8189dda-678d-455a-844b-c5425ab4ef4d/scratchpad/uidriver, which drives the installed apps by bundle ID and is not part of the repo.


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

- ~~Glass pass for Agentic Use and the runner fleet scene~~ — done in the
  follow-up: fleet legend and camera controls float as glass; Agentic Use
  refresh, empty-state, and "View All Models" actions use glass button styles.
- Loading skeletons (MOT-5) and illustrated empty states (MOT-6): new design
  work rather than cleanup.
- Pairing alert wording ("Reject") and Walkie's "Remove Download" /
  "Regenerate & re-sync" confirmations: reviewed and kept as-is by the owner.
- ~~Ink color swatches lack accessibility labels~~ — now buttons named by color.
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
