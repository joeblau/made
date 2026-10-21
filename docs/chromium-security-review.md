# Chromium security review record

This document is the engineering review record of the Chromium browser policy
boundary for the initial supported Chromium release. It records what was
reviewed and the conclusions; it is not a human sign-off. The protected
release workflow's environment approval remains the second security sign-off
described in the
[Chromium update and emergency runbook](chromium-update-runbook.md).

Review date: 2026-07-29

Release under review: `150.0.14-g7c1aa68-chromium-150.0.7871.129-blau.1`

## Scope

The review covers the policy boundary between web content and Pilot for the
optional Chromium engine: navigation, popups, external schemes, downloads,
file selection, origin permissions, DevTools, command-line switches, profile
location and deletion, diagnostics redaction, bridge-level CEF enforcement,
helper sandboxing and entitlements, and the Browser Annotate capability. It
covers release ID `150.0.14-g7c1aa68-chromium-150.0.7871.129-blau.1` only;
any CEF update re-opens it (see Re-review triggers).

## Reviewed components and verdicts

### Navigation, popup, and external-scheme policy — enforced

`apple/Sources/Pilot/Browser/ChromiumSecurityPolicy.swift`
(`ChromiumNavigationPolicy`) allows `http`/`https` and `about:blank` only,
blocks popups and new surfaces without a trusted user gesture, confines
managed popups to new Pilot panes, and restricts external schemes to
`facetime`, `facetime-audio`, `mailto`, `sms`, and `tel`, each requiring a
trusted gesture and a user-confirmed alert before macOS opens the URL. No
disposition permits CEF to create an unmanaged window; the bridge's
`OnBeforePopup` always cancels the CEF-side popup after delivering a typed
delegate callback.

### Download and file-selection policy — enforced

`ChromiumUserInteractionPolicy` honors downloads, file choosers, context
menus, print, and save-page only while the pane is active and selected.
Download URLs must be credential-free `http`/`https`; suggested filenames are
validated for emptiness, `.`/`..`, control characters, path separators, and a
255-byte UTF-8 limit. Save panels retain macOS collision confirmation.
Completed downloads receive Launch Services web-download quarantine metadata
(agent, type, and time only; source URLs omitted), and a file that cannot be
quarantined is removed and reported interrupted.

### Origin permission policy — enforced, default-deny

Privileged permissions resolve to deny until a user decision exists for the
exact canonical origin, and decisions are session-only. CEF requests
containing any permission bit Pilot does not type are denied in full; USB,
serial, and Bluetooth remain denied because the pinned CEF callback does not
identify them. CEF's single clipboard bit requires both clipboard-read and
clipboard-write decisions. An allow for an origin that is not potentially
trustworthy (non-HTTPS, non-loopback) is recorded as deny.

### DevTools policy — enforced

`ChromiumDevToolsPolicy.productionDefault` opens the managed local inspector
only for a trusted user action and exposes no remote debugging endpoint.
`ChromiumSwitchPolicy` rejects sandbox-disablement, certificate-bypass,
web-security-bypass, remote-debugging, and profile-escape switches, and the
bridge disables external command-line argument ingestion entirely.

### Certificate, authentication, and client-certificate handling — fail-closed

In `apple/Packages/ChromiumKit/Sources/ChromiumKit/ChromiumRequestPolicy.mm`,
`GetAuthCredentials` returns false (origin and proxy challenges are canceled
without collecting credentials), `OnCertificateError` returns false (invalid
certificates are canceled with no bypass path), and
`OnSelectClientCertificate` continues with no certificate rather than opening
CEF's picker. ChromiumKit injects only `disable-chrome-login-prompt` into the
browser process so Chrome runtime routes authentication challenges to this
fail-closed handler. Each rejection delivers a typed callback that Pilot
turns into a redacted diagnostic. The real-engine gate exercises an HTTP
authentication challenge and a test-only self-signed LibreSSL endpoint and
requires the corresponding rejection callbacks; the URLSession trust override
exists only in the fixture unit test and never reaches CEF or production
code.

### Profile policy — enforced

`apple/Sources/Pilot/Browser/ChromiumProfilePolicy.swift` constructs the only
permitted persistent profile locations under Pilot's Application Support
`Pilot/Chromium/Profiles` root, rejects symlinks inside the managed root and
candidate paths, and validates identifiers as path-safe. Clearing is
serialized by `ChromiumProfileAccessCoordinator`, refused while the engine
is running, and restricted to directories that pass the managed-location
check before and after recreation. One shared `default` profile is the
chosen semantics (see the profile semantics decision in
[chromium-browser.md](chromium-browser.md)).

### Diagnostics redaction — enforced

`apple/Sources/Pilot/Browser/ChromiumDiagnostics.swift` records only the
event kind, an integer error code, a canonical `scheme://host[:port]` origin
(ASCII, length-bounded), redaction markers, and bounded counts: at most 64
reported headers and 4,096 page-content bytes, with truncation flagged.
Credentials, URL paths, queries, fragments, headers, local paths, and page
content never enter the record.

### Bridge window and menu enforcement — enforced

The bridge hosts Chromium as a native child window (`CefWindowInfo` child
path) with windowless rendering disabled; CEF never creates an unmanaged
application window. Context menus are cleared unless the pane is active and
selected, and Find, Print, View Source, and all custom menu commands are
removed from any menu that is presented.

### Helper sandboxing and entitlements — enforced at packaging and validation

`apple/Packages/ChromiumKit/cef-artifacts.json` requires the Chromium sandbox
(`chromiumSandboxRequired`), defines five helpers (base, alerts, GPU, plugin,
renderer) with fixed bundle identifiers under `app.blau.pilot.helper` and
`LSUIElement`, and grants entitlements only to the GPU and renderer roles
(`com.apple.security.cs.allow-jit`); base, alerts, and plugin helpers ship
entitlement-free. The manifest also pins the inside-out nested signing order
and forbids `--deep`. `apple/bin/validate-chromium-archive.sh` rejects any
deviation: unexpected helpers or Mach-O code, entitlement drift, non-universal
binaries, missing hardened runtime, a helper that accepts `--no-sandbox`, and
(with `--require-notarization`) missing timestamps, staple, or `spctl`
assessment.

### Browser Annotate — capability-denied

`BrowserEngine.supports(_:)` in `apple/Sources/Pilot/Workspace.swift` reports
`.annotation` (along with `.appearanceOverride` and `.websiteDataReset`) as
unsupported for Chromium, so Annotate commands are inert in Chromium panes.
The decision: Annotate stays disabled for Chromium until its page-to-native
channel preserves the existing main-frame, current-navigation, single-use
grant and confirmation boundary on the CEF script-injection surface, and that
port is separately reviewed. This matches the recorded policy in
[chromium-browser.md](chromium-browser.md) and the runbook's triage step,
which repeats the same condition for every CEF update.

## Residual risks and accepted trade-offs

- Origin and proxy authentication challenges are always canceled, so sites
  requiring HTTP authentication are unreachable in Chromium panes. Accepted:
  Pilot does not collect or store web credentials.
- Client-certificate requests continue with no certificate, so
  mutual-TLS sites are unreachable. Accepted over opening CEF's certificate
  picker against Pilot's keychain.
- Permission decisions are session-only and are lost on relaunch. Accepted:
  persistence would require a reviewed store with its own clearing semantics.
- USB, serial, and Bluetooth are denied categorically rather than mediated.
  Accepted because the pinned CEF permission callback cannot identify them;
  revisiting requires a CEF upgrade with identifiable kinds and re-review.
- DevTools is limited to the managed local inspector with no remote endpoint;
  developers needing remote debugging have no supported path. Accepted.
- The idle watchdog message-pump turn budget constrains the pump
  implementation but does not bound renderer resource use on hostile pages
  beyond the documented CPU and memory budgets in
  [benchmarks/chromium.md](benchmarks/chromium.md).

## Re-review triggers

This record must be re-opened and a new dated review completed when any of
the following occurs:

- a CEF update is accepted — the runbook's triage step already requires
  re-review of navigation, popups, external schemes, downloads, file input,
  permissions, DevTools, profile deletion, diagnostics redaction, and
  Annotate IPC on every candidate;
- any helper role, entitlement, command-line switch, or permission callback
  changes;
- the profile model changes (per-workspace or ephemeral profiles), per the
  profile semantics decision;
- Annotate or another currently denied capability is proposed for Chromium;
- the bridge moves to off-screen rendering or otherwise changes the
  page-to-native rendering boundary;
- signing, notarization, or archive-validation policy changes.

At end of support for a pinned runtime, this record remains as the review of
the last supported release; re-enabling Chromium requires a fresh review per
the runbook.
