# Chromium troubleshooting

This guide covers maintainer and operator diagnosis of the optional Chromium
browser engine in Pilot. Architecture and policy background lives in the
[Chromium browser architecture](chromium-browser.md) document; update,
rollback, and incident procedures live in the
[Chromium update and emergency runbook](chromium-update-runbook.md). This
document describes symptoms and their causes rather than duplicating those
procedures.

## The Chromium browser entry point is disabled

New Chromium panes are gated by `ChromiumBrowserCreationPolicy`
(`apple/Sources/Pilot/Browser/ChromiumDiagnostics.swift`), which permits
creation only when all of these hold:

- the verified CEF runtime is installed and loadable
  (`ChromiumEngine.isRuntimeAvailable`);
- the process-wide engine is in a state that can start or is running (not
  shutting down, shut down, or failed);
- no initialization failure has been recorded
  (`ChromiumDiagnosticsCenter.runtimeStatus` is not `.unavailable`);
- no profile clear is in progress
  (`ChromiumProfileAccessCoordinator.isClearing`).

The menu item and launcher (`Commands/PilotPaneCommands.swift`,
`WorkspacePaneLauncher.swift`) consult the same policy, so a disabled entry
point means one of the four conditions above failed. Open Pilot Settings and
read the Chromium diagnostics section (`ChromiumDiagnosticsSettings.swift`):
the Runtime row shows Not started, Starting, Running, Unavailable, or
Renderer terminated, and the last initialization failure is listed with
redacted detail. If the
runtime is not installed, run `apple/bin/update-chromiumkit-artifact.sh`
followed by `apple/bin/verify-installed-chromiumkit.sh`. If a clear is in
progress, wait for it to finish; creation is blocked until the detached
filesystem work completes.

## "Chromium is unavailable in this build" in a pane

A restored or newly created Chromium pane shows "Chromium is unavailable in
this build. WebKit browsers remain available." with a Retry button when the
engine could not start: the managed profile directory could not be created or
failed the managed-location check, the engine threw during start, or the
engine was not running after start (`ChromiumBrowserView.swift`). The pane
records a `launchRejected` diagnostic with the error code and marks the
runtime unavailable, which also disables further Chromium creation.

Retry recreates the pane's surface (`requestRuntimeRetry` bumps a request ID
that rebuilds the host view), which re-runs profile setup and engine start.
Check that the pinned runtime is installed and verified (see the install
section below) and that Application Support is writable. Pilot deliberately
does not migrate the pane to WebKit; the user can open a WebKit pane
separately.

## The renderer stopped

"The Chromium renderer stopped. Reload to try again." appears with a Retry
button when CEF reports renderer termination. Pilot records a
`rendererTerminated` diagnostic (termination status code and redacted
origin), resets loading and history state for that pane, and shows the
recoverable surface (`ChromiumBrowserView.swift`,
`ChromiumDiagnosticsCenter`). Retry reloads the existing browser. The
Settings diagnostics section shows the runtime as Renderer terminated until
the next successful load, and lists the last termination with redactions.

## Navigation failed or was blocked

"Chromium could not load this page." (with Retry) follows a CEF load error;
a `navigationFailed` diagnostic records the error code and redacted origin.
"Chromium blocked this navigation." (without Retry) means
`ChromiumNavigationPolicy` denied the target: a popup or new-surface request
without a trusted user gesture, a scheme outside `http`, `https`, and
`about:blank`, or an external scheme (`facetime`, `facetime-audio`, `mailto`,
`sms`, `tel`) reached without a trusted gesture. External schemes with a
trusted gesture produce a confirmation alert before Pilot asks macOS to open
the URL. Canceled authentication challenges (origin or proxy), rejected
certificates, and client-certificate requests are fail-closed in the bridge
and surface as navigation failures with typed rejection callbacks; Pilot
never collects credentials and never offers a certificate bypass.

## Installing or verifying the runtime fails

`apple/bin/update-chromiumkit-artifact.sh` verifies a candidate completely
before touching the active runtime: it checks the release checksums, requires
the receipt's release ID, archive SHA-256, byte count, CEF identity, source
archives, and architectures to match the checked-in lock
(`cef-artifacts.json`), rejects archive members outside `CEF/` or containing
`..`, rejects absolute or escaping symlinks, compares the installed
`cef-artifacts.json` byte-for-byte with the lock, hashes every receipt-listed
file, and compares the installed byte count. A failure at any step aborts
before the swap, so the active runtime is unchanged. After verification it
moves the prior directory aside on the same filesystem and restores it if the
swap fails or is interrupted.

`apple/bin/verify-installed-chromiumkit.sh` fails when the runtime is not
installed, the installed lock differs from the checked-in lock, the receipt
does not match the lock, any receipt-listed file is missing or hashes
differently, or the installed byte count differs. The offline drill
`apple/bin/test-chromiumkit-update-rollback.sh` exercises exactly these
rejections (tampered installed file, corrupted archive, false archive byte
count, out-of-root archive member) and proves byte-identical A → B → A
restoration.

A mismatch means the installed runtime does not correspond to the checked-in
lock: re-run the installer from a verified release directory, or follow the
runbook's rollback procedure if the checked-in lock itself must move back.

## Rolling back a bad update

Rollback is a new forward release containing the prior known-good runtime;
Pilot never deletes, mutates, or re-tags an existing release and never mixes
components from different CEF revisions. The complete procedure, including
verification of the prior immutable release and its attestation, is the
Rollback section of the
[Chromium update and emergency runbook](chromium-update-runbook.md).

## Clear browsing data is refused

The Settings "Clear Chromium Browsing Data" button is disabled with an
explanatory caption unless clearing is available
(`ChromiumBrowsingDataController.availability`):

- "Close Chromium and relaunch Pilot before clearing its browsing data."
  — the process-wide engine is running. Clearing is blocked while any
  Chromium state is live because the engine owns the profile on disk.
- "Pilot is already clearing Chromium browsing data." — a clear is in
  progress; the profile access coordinator serializes all profile access and
  rejects overlapping operations.
- "Pilot could not resolve its managed Chromium profile." — the managed
  profile directory failed the location check (for example a symlink inside
  the managed root). Pilot refuses to delete anything outside the managed
  `Pilot/Chromium/Profiles` root under Application Support.

A successful clear removes the managed profile directory (cookies, cache,
storage, history) and recreates it empty, verifying the managed-location
check again after recreation.

## Permissions, downloads, and file panels behave unexpectedly

These behaviors are policy, not faults:

- Camera, microphone, geolocation, notifications, clipboard, MIDI SysEx, and
  file-system access are denied until the user allows them for the exact
  canonical origin in a session-only decision. A single prompt covers each
  unresolved kind in a request; CEF exposes clipboard as one bit, so Pilot
  requires both clipboard-read and clipboard-write decisions. A request
  containing any permission bit Pilot does not type is denied in full, and
  USB, serial, and Bluetooth are always denied because the pinned CEF
  callback does not identify them. An allow for an insecure non-loopback
  origin is recorded as deny.
- Downloads, file choosers, context menus, print, and save-page are only
  honored while the Chromium pane is both active and selected; otherwise the
  bridge cancels them. Download URLs must be credential-free `http`/`https`,
  and suggested filenames are validated (no empty, `.`, `..`, control
  characters, path separators, or names over 255 UTF-8 bytes).
- Completed downloads receive Launch Services web-download quarantine
  metadata containing agent, type, and time only; source URLs are
  deliberately omitted. If quarantine cannot be applied, Pilot removes the
  downloaded file and reports the download as interrupted. Expect Gatekeeper
  to assess quarantined downloads on first open.
- Save panels keep the macOS collision confirmation, and all panels are
  native and cancellable.

## Archive validation or notarization fails on a release build

`apple/bin/validate-chromium-archive.sh` fails the release when the assembled
application has a missing or unexpected helper, a non-universal binary, a
helper bundle identifier or `LSUIElement` mismatch, entitlements that differ
from the reviewed policy, a missing or non-hardened-runtime signature, a
signing team that differs from Pilot's, a helper that does not reject
`--no-sandbox` (exit 64), unexpected mutable Mach-O code anywhere in the
bundle, missing or altered `LICENSE.txt`/`CREDITS.html` copies, nested
signing that used `--deep` or omitted runtime options, or signing performed
out of the deterministic inside-out order. With `--require-notarization` it
additionally requires trusted signing timestamps, a stapled ticket, and a
passing `spctl` assessment.

Treat every failure as a blocking defect in the archive, not a warning to
override: the protected release workflow runs this validation before
notarization, and publication is fail-closed on GitHub release attestation
and a fresh-download byte comparison. Reproduce locally against the same
xcarchive, fix the input (helper layout, entitlements, signing script, or
manifest), and rebuild. Budget failures from packaging or the runtime probe
are covered in [Chromium performance baselines](benchmarks/chromium.md).
