# Chromium browser architecture

Status: Accepted for implementation

Date: 2026-07-28

Tracking: [#184](https://github.com/joeblau/made/issues/184) and
[#185](https://github.com/joeblau/made/issues/185)

## Decision

Pilot will embed Chromium through the Chromium Embedded Framework (CEF). The
existing WebKit browser remains available while Chromium is introduced as an
explicit browser engine on the existing `PaneKind.browser`.

This is a conditional **go** decision for the pinned CEF revision. Chromium may
ship only through the opt-in `Chromium` configuration after both architecture
probes, the signed archive validator, and notarization pass. A failed gate is a
no-go for Chromium publication and does not affect the artifact-free WebKit
build.

The integration has these boundaries:

- `BrowserState` persists an engine discriminator. Existing records resolve to
  WebKit; users explicitly create Chromium panes during rollout.
- Pilot browser chrome, start-page discovery, workspace layout, and shared
  commands remain Swift.
- A narrow Objective-C++ `ChromiumKit` module owns all CEF and C++ types.
- Pilot builds that module as a configuration-scoped static framework so
  Debug/Release deterministically compile the unavailable bridge even after a
  prior Chromium build. The Chromium-only prebuild gate verifies the installed
  lock, receipt, required hashes, and byte count before compiling CEF code.
- CEF uses native child-window hosting in an `NSView`. Off-screen rendering is
  not used unless the Xcode 26 feasibility probe proves native hosting cannot
  satisfy Pilot's split-pane lifecycle.
- CEF is initialized once in the browser process. Browser instances are owned
  by panes and close asynchronously before process-wide shutdown.
- The AppKit main run loop drives CEF through
  `CefBrowserProcessHandler::OnScheduleMessagePumpWork`. The pump follows CEF's
  external-pump contract: every callback replaces the pending one-shot wake-up,
  and Pilot honors CEF's requested delay. Because the pinned native macOS host
  does not always request a following turn, a compare-and-swap watchdog is
  reserved only when CEF schedules nothing while processing the current turn.
  It backs off from 50 ms to 100 ms, and any CEF callback invalidates it before
  execution. This retains native-host liveness without the former continuous
  30 Hz safety cadence.
- CEF subprocess work runs in the separate, process-specific helper app bundles
  required by the pinned distribution. Release builds keep Chromium sandboxing
  enabled.
- Chromium data lives under Pilot's Application Support directory. It never
  uses a workspace directory or imports a system Chrome profile.

CEF's process, message-loop, and macOS application-layout requirements are
documented in the
[CEF general usage guide](https://chromiumembedded.github.io/cef/general_usage).
The upstream
[cef-project](https://github.com/chromiumembedded/cef-project)
is the reference implementation for build and helper behavior.

Retina and backing-scale correctness holds by construction. The bridge hosts
Chromium as a native child window inside Pilot's `NSView` subtree
(`CefWindowInfo.SetAsChild`), with windowless rendering disabled and no
off-screen bitmap or render-handler path in ChromiumKit. AppKit therefore
scales Chromium content to the window's backing scale factor exactly as it
does the rest of the view hierarchy, and the bridge deliberately contains no
scale-factor code. Native hosting passed the Retina probe during the Xcode 26
feasibility proof. A future move to off-screen rendering would lose this
property and require explicit scale-factor plumbing through the render
handler, which is one reason off-screen rendering remains a rejected
alternative.

## Pinned upstream inputs

Normal builds must never resolve a floating CEF channel. The artifact manifest
is authoritative and contains these exact inputs:

| Field | Value |
| --- | --- |
| CEF version | `150.0.14+g7c1aa68+chromium-150.0.7871.129` |
| CEF commit | `7c1aa68455db1f1fad159c2b83070ad318212b3d` |
| Chromium commit | `e69b30bba288603e514cffb4c79c359cac68e923` |
| Sandbox compatibility ID | `6c5b35ad81055c14` |
| Release date | 2026-07-20 |

### macOS arm64

- Archive:
  `cef_binary_150.0.14+g7c1aa68+chromium-150.0.7871.129_macosarm64_minimal.tar.bz2`
- URL:
  `https://cef-builds.spotifycdn.com/cef_binary_150.0.14%2Bg7c1aa68%2Bchromium-150.0.7871.129_macosarm64_minimal.tar.bz2`
- Size: `124572272` bytes
- Upstream SHA-1: `47baa745213c938861861f0f3f65c6dd03e7254e`
- Acceptance SHA-256:
  `293048b4f49e0853f2e13394ef3d57d55da7733340e51407e38d826b8ab5a200`

### macOS x86_64

- Archive:
  `cef_binary_150.0.14+g7c1aa68+chromium-150.0.7871.129_macosx64_minimal.tar.bz2`
- URL:
  `https://cef-builds.spotifycdn.com/cef_binary_150.0.14%2Bg7c1aa68%2Bchromium-150.0.7871.129_macosx64_minimal.tar.bz2`
- Size: `130699221` bytes
- Upstream SHA-1: `c0591785a04404e2301cb1e216b6508231445dde`
- Acceptance SHA-256:
  `a5c202571d18ee0ab2f65771c3b00baad5e954e5cf9c69bd9ad42bdb9016ec80`

The upstream index publishes the size and SHA-1. Pilot additionally requires
the independently computed SHA-256 above. Fetching fails before extraction if
the size, SHA-1, or SHA-256 differs.

## Xcode 26 feasibility gate

The pinned distribution's macOS README requires Xcode 26 consumers to convert
the supplied unversioned framework into a `Versions/A` framework layout with
relative symlinks. The packaging script owns that conversion so local and CI
builds cannot diverge.

The gate is complete only when both architectures prove all of the following:

- `Chromium Embedded Framework.framework` compiles and loads with Xcode 26.
- A native child view loads an offline page and executes JavaScript.
- Renderer and GPU helpers launch from the assembled app bundle.
- Helpers retain their process-specific entitlements and effective sandbox.
- Two browser instances navigate and close independently.
- CEF message work is scheduled without idle busy polling.
- An archive passes nested signature and hardened-runtime validation.

No production Chromium creation action is enabled when the verified CEF-backed
bridge is absent, the engine can no longer start, initialization has failed, or
the managed profile is being cleared. Restored Chromium panes retain their
engine identity and show the recoverable unavailable surface instead of being
silently migrated. The failure path leaves Chromium diagnostics and existing
WebKit panes usable.

Run the real-engine gate on Apple silicon after installing the pinned runtime:

```sh
apple/bin/test-chromium-runtime.sh
```

The command builds the `Chromium` configuration with Xcode 26 and runs one
hosted XCTest against the assembled, signed application. It requires an Apple
Development signing identity because XCTest injects into Pilot while hardened
runtime and library validation remain enabled. Override the local identity and
team when necessary with `BLAU_CHROMIUM_TEST_CODE_SIGN_IDENTITY` and
`BLAU_CHROMIUM_TEST_DEVELOPMENT_TEAM`.

The test serves only the checked-in offline fixture and verifies navigation and
JavaScript, back/forward history, two independent browser lifecycles, final-URL
restoration in a recreated host, intentional renderer termination and recovery,
renderer/GPU process roles from Pilot's bundle, active browser counts, and
process-wide CEF shutdown. It also drives trusted native clicks through CEF to
prove script-popup blocking, managed popup interception, default-denied media
and geolocation permissions, file chooser and download cancellation, prohibited
local-file navigation, hostile-message isolation, and post-shutdown clearing of
the managed Chromium profile. The protected release workflow runs the probe as both
arm64 and x86_64 (under Rosetta on its Apple-silicon runner). A local slice can
be selected with `BLAU_CHROMIUM_TEST_ARCHITECTURE`; the default is the host
architecture. The ordinary Pilot suite compiles the same test as an explicit
skip so clean artifact-free Debug and Release test runs remain deterministic.

`apple/Packages/ChromiumKit/performance-budgets.json` pins the release ID,
compressed and installed runtime size ceilings, and architecture-specific
startup/first-navigation, idle process-tree CPU, and resident-memory limits.
Both architectures also have an idle Pilot-watchdog message-pump turn limit
and a shutdown-to-zero-helper cleanup limit. CEF-requested turns are diagnostic
but do not count against that limit; the budget specifically rejects a
regression to high-frequency Pilot-owned polling even if host CPU happens to
remain under its ceiling. The x86_64 startup limit includes cold Rosetta
translation.
Packaging fails when either size grows past its ceiling; the real-engine test
fails when a runtime metric exceeds its limit. CPU is calculated from
cumulative process time across two snapshots, not an instantaneous `ps`
percentage. Budget changes therefore require an explicit reviewed diff
alongside a CEF update.
The manual signed Chromium release workflow runs the same probe after importing
its signing identity and installing the verified runtime, so a regression
blocks archive notarization and publication.

Publication is also fail-closed on GitHub release immutability. After the
notarized archive and deterministic runtime assets are uploaded, the workflow
requires GitHub's signed release attestation, verifies every local asset
against it, downloads all published assets into a fresh directory, and
byte-compares them with the release inputs. The protected release environment
supplies a separate fine-grained, read-only repository Administration token
for the preflight setting check; the job-scoped token remains responsible for
asset publication.

## Artifact and bundle layout

The repository stores source, manifests, checksums, and reproduction scripts,
not the CEF archive itself. A clean build downloads an immutable published
artifact or uses an explicitly supplied, checksum-identical local cache.

The assembled application follows CEF's required layout:

```text
made.app/
  Contents/
    Frameworks/
      Chromium Embedded Framework.framework/
      Pilot Helper.app/
      Pilot Helper (Renderer).app/
      Pilot Helper (GPU).app/
      ...additional helpers required by the pinned CEF distribution...
```

The manifest, not ad hoc build-script conditionals, defines required helpers.
Helper bundle names come from the manifest rather than from the app's
executable name: ChromiumKit passes the base helper path to CEF explicitly
(`browser_subprocess_path`), so the `Pilot Helper` bundles keep working inside
`made.app`, and renaming them is a ChromiumKit lock change with its own
immutable runtime release rather than an app-target setting.
Archive validation rejects missing helpers, unexpected helpers, mismatched
architectures, incorrect bundle identifiers, unsafe entitlements, invalid
signatures, and production sandbox-disable switches.

## ChromiumKit boundary

Swift code receives an Objective-C-compatible API with these concepts:

- A process-wide engine service that starts with an explicit profile directory
  and shuts down after every browser closes.
- An `NSView` browser host with load, back, forward, reload, stop, focus, zoom,
  DevTools, native mouse-click injection for trusted adapters, and close
  commands.
- Typed callbacks for URL, title, loading, progress, history capability,
  navigation failure, renderer termination, and browser close.
- Explicit created, closing, and closed states.
- A Swift protocol and fake implementation for tests that do not need CEF.

CEF reference-counted pointers, command-line parsing, threads, and process
messages remain private to Objective-C++.

The ordinary artifact-free test suite uses that fake boundary to verify exact
navigation, zoom, DevTools, find, print, save, and close command ordering. It
also replays typed callbacks in a deterministic sequence and proves that
closing while creation is pending detaches the delegate before a late created
callback can revive the pane. The real-engine gate separately exercises the
same boundary against CEF.

Pilot's screenshot demo factory also includes one Chromium pane with an empty
URL. The ordinary suite pins that fixture shape and its blank, non-loading
state, so demo capture covers Chromium without depending on a public website
or mutable network response.

## Rejected alternatives

- Raw Chromium embedding was rejected because it has no supported narrow
  embedding API and would make Pilot own substantially more browser-process,
  build, and update machinery.
- Electron was rejected because its application-shell and Node.js runtime
  duplicate Pilot's native AppKit/SwiftUI shell and broaden the page-to-native
  trust boundary.
- Replacing WebKit outright was rejected because it would silently migrate
  existing panes and make the large CEF runtime mandatory for normal builds.
- Off-screen rendering was rejected for the initial implementation because
  native child-window hosting passed the Xcode 26, split-pane, Retina, helper,
  and lifecycle probes with less input and compositing code.

## License obligations

The exact upstream `LICENSE.txt` and Chromium `CREDITS.html` selected by the
artifact manifest must remain byte-identical across architecture inputs. The
packager preserves both in the immutable runtime artifact, the app assembler
copies them to `made.app/Contents/Resources/Chromium/CEF`, and archive
validation rejects missing or changed copies.

## Storage and security policy

- Persistent browser data uses a Pilot-owned Chromium directory under
  Application Support.
- Profile clearing is restricted to that managed directory and is allowed only
  after the process-wide engine has shut down.
- WebKit, Chromium, and system Chrome data remain isolated.
- Chromium command-line switches use a reviewed allowlist. Release validation
  rejects sandbox disablement, certificate bypass, or broadly exposed remote
  debugging.
- Chromium uses its normal macOS proxy, DNS, and platform trust behavior
  without Pilot-injected proxy rules, DNS mappings, trust roots, or Chrome
  enterprise policy. External command-line ingestion is disabled. ChromiumKit
  injects only `disable-chrome-login-prompt` into the browser process so Chrome
  runtime routes authentication challenges to CEF's fail-closed handler instead
  of owning a credential prompt. Origin and proxy authentication challenges are
  canceled instead of collecting credentials;
  invalid certificates are canceled with no bypass; and client-certificate
  requests continue with no certificate rather than opening CEF's default
  certificate picker. Only bounded, redacted rejection diagnostics cross the
  ChromiumKit boundary. The offline real-engine gate exercises both an HTTP
  authentication challenge and a dedicated local LibreSSL endpoint with a
  test-only self-signed certificate, and requires the corresponding typed
  rejection callbacks. A URLSession trust override exists only in the fixture
  unit test to prove that endpoint is healthy; CEF and production code never
  receive that override, and the test does not install a trust root.
- Privileged web permissions are denied until an origin-specific user decision
  exists. ChromiumKit types camera, microphone, geolocation, notification,
  clipboard, MIDI SysEx, and file-system-access callbacks. Pilot maps them to
  session-only decisions for the exact canonical origin; a CEF request that
  contains any unknown permission bit is denied in full. CEF exposes clipboard
  as one bit, so Pilot requires both clipboard-read and clipboard-write
  decisions. USB, serial, and Bluetooth remain denied because this pinned CEF
  callback does not identify them.
- DevTools is user-initiated and must not leave a persistent externally
  reachable debugging endpoint.
- Downloads and file selection use native, cancellable panels. Save panels
  retain macOS collision confirmation. Completed downloads receive explicit
  Launch Services web-download quarantine metadata containing agent, type, and
  time only; source/origin URLs are omitted to avoid persisting credentials or
  query data. If quarantine cannot be applied, Pilot removes the file and
  reports the download as interrupted.
- Popups never create unmanaged application windows.
- Browser Annotate is disabled for Chromium until its page-to-native channel
  preserves the existing main-frame, current-navigation, single-use grant and
  confirmation boundary.
- URLs, credentials, headers, local paths, and page-controlled content are
  redacted or bounded before entering logs or diagnostics.

### Profile semantics decision

Pilot supports exactly one Chromium profile model: a single shared persistent
profile. The alternatives the tracking issue asked to evaluate were decided
as follows.

- **Shared persistent profile — chosen.** All Chromium panes in every
  workspace use one profile with the identifier `default`, rooted at
  `Application Support/Pilot/Chromium/Profiles/default`.
  `ChromiumProfilePolicy` enforces the boundary: profile identifiers are
  path-safe (at most 64 UTF-8 bytes of ASCII letters, digits, `-`, `_`), the
  location helper refuses any path outside the managed root and rejects
  symlinks inside it, and the engine receives only URLs produced by that
  helper. The profile is isolated from WebKit data and system Chrome, and it
  is never inside a workspace directory.
- **Per-workspace profiles — deferred.** `ChromiumProfileIdentifier` and
  `ChromiumProfileLocation.directory(for:)` already support additional
  identifiers, but Pilot intentionally uses only `default`. CEF is
  initialized once per process with a single root cache path, so per-workspace
  profiles would require either multiple engine lifecycles or a CEF
  request-context isolation layer Pilot does not currently build. Workspace
  separation is already provided at the pane level, and no requirement has
  justified the added migration, clearing, and rollback complexity of
  per-workspace storage.
- **Ephemeral (incognito) profiles — rejected for now.** The audited
  lifecycle assumes one persistent managed directory: creation policy,
  diagnostics, and clearing are all built around it, and the pinned engine
  configuration points CEF's root cache path at that directory. An ephemeral
  profile would bypass the managed-clear path and widen the audit surface
  (cleanup on close, crash residue, interaction with the download and
  quarantine policy) for a capability no workflow currently needs.
- **Adding either later** requires, at minimum: minting and recording
  non-default `ChromiumProfileIdentifier` values (keyed by workspace for
  per-workspace profiles), extending engine startup to select or isolate a
  profile per context, extending `ChromiumProfileAccessCoordinator` to
  serialize and clear multiple profiles, and updating the rollback profile
  compatibility rules in the runbook. Ephemeral profiles additionally need a
  defined teardown and residue-cleanup story.

Clearing behaves the same regardless of these future directions: the
`ChromiumProfileAccessCoordinator` serializes all profile access, refuses to
clear while the process-wide engine is running, refuses overlapping clears,
and deletes only directories that pass the managed-location check.

## Wallet extensions

Chromium panes can host side-loaded wallet extensions (Rabby, Backpack). Pilot
implements no wallet: it holds no keys, derives no addresses, signs nothing, and
speaks no chain protocol. The extension is ordinary third-party browser code
that keeps its own secrets in its own extension storage. Pilot supplies exactly
two things — the directories Chromium loads, and a button that opens each
extension's action popup.

### Loading

CEF 150 removed `CefRequestContext::LoadExtension` and there is no replacement;
programmatic extension management remains open upstream
(chromiumembedded/cef#3450). The only route is Chrome's `--load-extension`
switch, appended in `ChromiumApp::OnBeforeCommandLineProcessing`. App-appended
switches are still honored under `command_line_args_disabled`, which blocks only
external and OS-provided arguments.

The directories are supplied by Pilot through
`ChromiumEngine.setExtensionDirectories(_:)` before `start(profileDirectory:)`,
never hardcoded in the bridge. CEF reads the command line once during
initialization, so the call has to precede engine start.

`WalletExtensionRegistry` discovers them, searching
`PILOT_WALLET_EXTENSIONS_DIR` (a development override) and then
`Application Support/Pilot/Extensions`.

### Identifiers are derived, never stored

Chrome computes an unpacked extension's identifier from its **absolute load
path**: the first 16 bytes of the path's SHA-256, hex-encoded, with each hex
digit mapped `0…f` → `a…p`. That identifier is the `chrome-extension://` origin
the extension's pages are served from.

Pilot therefore derives the identifier from the same path it hands to CEF. A
hardcoded identifier is a latent defect rather than a shortcut: it breaks on
every machine whose path differs, and it keeps *resolving* after a directory
moves — addressing an origin that no longer exists, with no error. The
regression test pins the derivation against two identifiers Chrome actually
assigned.

### Trust boundary

- A wallet extension is third-party code with broad privileges inside Chromium.
  Installing one is a deliberate user act, equivalent to installing it in
  Chrome; Pilot neither audits nor sandboxes it beyond what Chromium does.
- `manifest.json` is untrusted input. Its size is bounded before reading, its
  name is sanitized, and its `default_popup` is rejected outright when absolute,
  containing `..`, or carrying a scheme — that string becomes a URL path.
- A path containing a comma cannot be expressed in the switch value and is
  dropped rather than silently splitting into two bogus directories.
- `ChromiumNavigationPolicy` allows `chrome-extension:` only for same-pane
  navigation and denies every new surface, so extension pages cannot open
  unmanaged windows.

### Why the popup is a separate window

Each wallet's action popup renders in a floating `NSPanel` above the browser
view, not inside page content. This mirrors Chrome, where extension popups are
deliberately outside page-controlled space: a page that could draw over a
wallet's UI could forge a connection prompt or a signing confirmation. The panel
takes key focus because importing a key means typing into it, and it denies
popup requests from its own content.

### Known limits

Wallet buttons appear only in Chromium panes — WebKit cannot host the extensions
and renders nothing rather than a disabled control. Because Chromium itself ships
only in the `Chromium` configuration, wallets are absent from clean Debug and
Release builds for the same reason the engine is.

## Update and rollback

Every CEF update changes the lock manifest in review and regenerates the
published artifacts from immutable upstream inputs. The update must:

1. Record the new CEF and Chromium revisions, archive sizes, SHA-1 values, and
   independently computed SHA-256 values.
2. Rebuild the wrapper and all helper variants for both architectures.
3. Run the offline real-engine suite and archive validator.
4. Compare artifact size, startup, first navigation, idle CPU, and memory
   against the recorded budgets.
5. Produce a signed release candidate before changing the supported version.

Rollback selects the prior complete lock manifest and its immutable artifacts.
Mixing a framework, wrapper, helper, resources, or sandbox library from
different CEF revisions is forbidden.

The complete
[Chromium update and emergency runbook](chromium-update-runbook.md) defines
stable-channel selection, daily monitoring, response deadlines, compatibility
and security gates, signed critical-update drills, forward rollback releases,
evidence retention, and end-of-support disablement. The artifact-free
`test-chromiumkit-update-rollback.sh` gate proves corrupt-update rejection and
byte-identical A → B → A restoration. The installer verifies before replacing
the active runtime and restores the prior directory if its same-filesystem
swap fails.

## Out of scope

The initial Chromium panel does not provide Chrome profile import, Chrome Sync,
extension-store installation, a password manager, Widevine/DRM, or
proprietary-codec builds.

Pilot also implements no wallet of its own: no key storage, no signing, no
EIP-1193 provider, no chain RPC. Wallet support means hosting a side-loaded
extension that does those things itself, as described above.
