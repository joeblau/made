# CodeEditSourceEditor native presentation adaptation

This directory contains the `Sources` and license from
[CodeEditSourceEditor 0.15.2](https://github.com/CodeEditApp/CodeEditSourceEditor/tree/0.15.2),
revision `424453d2232c9912933a3b5a1f3d3df669404ed0`. The upstream MIT license
and copyright notices are retained in `LICENSE.md` and source headers.

The cockpit uses the public AppKit `TextViewController` directly. Upstream
0.15.2 instantiates SwiftUI hosting views inside that controller, even when
the caller does not use its SwiftUI `SourceEditor` wrapper. This adaptation
replaces those runtime presentations while retaining the text engine,
syntax providers, layout, indentation, find model, and undo behavior.

Local changes:

- `Find/PanelView/NativeFindPanelView.swift` replaces `FindPanelHostingView`
  with native search and replacement fields, buttons, menus, keyboard handling,
  and accessible match status. `FindViewController` installs this view above
  the text view. Its toggle code uses native panel geometry, idempotent hide,
  and the system Reduce Motion preference.
- `Controller/TextViewController+NativeFind.swift` exposes AppKit actions for
  showing find/replace, match navigation, and searching the selection.
  `TextViewController+FindPanelTarget.swift` offsets the clip origin when panel
  height changes so visible text stays below the find or replace rows.
- `SupportingViews/BezelNotification.swift` uses an `NSVisualEffectView` and
  `NSImageView` for the search wrap notification.
- `CodeSuggestion/TableView/NativeCodeSuggestionLabelView.swift` renders native
  completion rows. `SuggestionViewController` uses it, and `CodeSuggestionEntry`
  supplies native image/color hooks with compatible defaults.
- `Package.swift` pins the same production dependency versions as the app's
  original resolution: CodeEditTextView 0.12.1, CodeEditLanguages 0.1.20,
  CodeEditSymbols 0.2.3, and TextFormation 0.9.0. Upstream test/plugin dependencies
  are omitted because their targets are not vendored.

Unused SwiftUI source wrappers remain for source compatibility. No source
in this package instantiates `NSHostingView` or `NSHostingController`. The app
does not use those wrappers. Native integration and find/replace regression
tests live in `apple/Tests/PilotTests/AppKitEditorTests.swift`.

When updating upstream, compare this directory against the tagged revision,
reapply the changes above, rerun the native editor tests and cockpit boundary
check, and verify that no new hosted presentation is reachable from
`TextViewController`. Do not replace this package with the unmodified remote
package until upstream supplies a fully native presentation path.
