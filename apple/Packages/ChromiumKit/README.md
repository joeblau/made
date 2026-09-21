# ChromiumKit

ChromiumKit is Pilot's opt-in Chromium Embedded Framework (CEF) bridge. Debug
and Release clean checkouts build Pilot's existing WebKit browser without
downloading or linking CEF. The explicit Chromium entry point resolves and
verifies the locked inputs, builds the matching wrapper, installs the runtime,
and selects the `Chromium` Xcode configuration.

See the repository's [Chromium browser design and operations guide][browser-doc]
for the panel architecture and policies, and the
[Chromium update and emergency runbook][update-runbook] for monitoring,
response deadlines, signed drills, rollback, and end of support.

## Immutable upstream pin

The authoritative machine-readable lock is
[`cef-artifacts.json`](cef-artifacts.json). It pins:

- CEF `150.0.14+g7c1aa68+chromium-150.0.7871.129`
- CEF commit `7c1aa68455db1f1fad159c2b83070ad318212b3d`
- Chromium commit `e69b30bba288603e514cffb4c79c359cac68e923`
- Sandbox compatibility commit `6c5b35ad81055c14`
- Xcode `26.x`

| Architecture | Bytes | SHA-1 | SHA-256 |
| --- | ---: | --- | --- |
| arm64 | 124572272 | `47baa745213c938861861f0f3f65c6dd03e7254e` | `293048b4f49e0853f2e13394ef3d57d55da7733340e51407e38d826b8ab5a200` |
| x86_64 | 130699221 | `c0591785a04404e2301cb1e216b6508231445dde` | `a5c202571d18ee0ab2f65771c3b00baad5e954e5cf9c69bd9ad42bdb9016ec80` |

The URLs are versioned HTTPS assets. Floating branches, `latest` aliases, and
unverified mirrors are not accepted.

The app assembly copies the artifact's exact `LICENSE.txt` and `CREDITS.html`
to `made.app/Contents/Resources/Chromium/CEF`. Archive validation rejects a
missing or modified legal-notice copy.

## Validate without downloading

The manifest gate is safe for ordinary CI and clean developer checkouts:

```sh
bash apple/bin/package-chromiumkit.sh manifest
```

`ChromiumArtifactManifestTests` independently checks the schema, immutable
source identity, helper layout, sandbox policy, entitlements, byte sizes, and
hash shapes without using the network.

The offline installer drill uses tiny fixture releases to prove corrupt-update
rejection and byte-identical rollback without downloading CEF:

```sh
bash apple/bin/test-chromiumkit-update-rollback.sh
```

## Install and build

Install the two verified upstream distributions and assemble the ignored local
artifact:

```sh
apple/bin/update-chromiumkit-artifact.sh
```

Downloads are cached by release ID and SHA-256 below
`~/Library/Caches/app.blau/ChromiumKit/`. The installer verifies the exact byte
count, SHA-1, and SHA-256 before extraction. It stages the complete candidate
beside the destination, moves the prior runtime aside on the same filesystem,
and restores that directory if the swap fails. It creates:

```text
apple/Packages/ChromiumKit/Artifacts/CEF/
├── Chromium Embedded Framework.framework
├── include/
├── lib/libcef_dll_wrapper.a
├── LICENSE.txt
├── CREDITS.html
├── cef-artifacts.json
└── ChromiumKitCEF.release.json
```

Pilot builds the Objective-C++ source as a configuration-scoped static
`ChromiumKit` target. Debug and Release always compile its unavailable bridge;
only the explicit `Chromium` configuration defines the CEF implementation.
This selection is made by Xcode build settings instead of SwiftPM manifest
environment, whose cached package graph could otherwise leak a prior Chromium
selection into a later Debug build.

Every Chromium build runs `verify-installed-chromiumkit.sh` before compiling.
The verifier requires the installed lock to be byte-identical to the checked-in
lock, validates the release receipt's CEF identity, source archives,
architectures, tool provenance, exact required-file set, per-file hashes, and
installed byte count. App assembly repeats the same gate. Copying a framework
or headers into `Artifacts/CEF` by hand therefore cannot enable a successful
Chromium build; use the installer so checked artifacts generate the receipt.
`Package.swift` remains available for standalone bridge consumers and applies
the same explicit opt-in and receipt checks, but it is not Pilot's
configuration selector.

From a clean checkout, resolve and build the explicit Chromium configuration
with one command:

```sh
apple/bin/build-pilot-chromium.sh
```

Debug and Release intentionally remain artifact-free and continue using
the stub bridge and WebKit. The opt-in environment is intentionally scoped to
the Chromium build command.

The built product lands in a hash-named DerivedData directory that a Clean
Build Folder erases. To keep a Chromium-enabled Pilot at a stable path for
day-to-day use, build and install it in one step:

```sh
apple/bin/install-pilot-chromium.sh
```

It selects an installed Xcode 26 when `xcode-select` points elsewhere, refuses
to install a bundle without the embedded framework, helper bundles, or a valid
signature, and swaps the destination atomically so an interrupted copy cannot
replace a working app with a partial one. The destination defaults to
`/Applications/made.app` and is overridable with `--destination` or
`BLAU_PILOT_INSTALL_PATH`. Pass `--skip-build` to install the current build as
is, or `--quit-running` to ask a copy already running from the destination to
quit and wait up to 30 seconds for it, rather than refusing the install. The
quit is a request, never a forced kill, so the running app keeps ownership of
its unsaved editor and SwiftData state; `bun cockpit` passes the flag. This
installs a development-signed build for local use; distribution still goes
through the signed, notarized release workflow.

## Run the real engine smoke test

After installing the pinned runtime, exercise native rendering, offline
navigation and JavaScript, history, helper launch, two-browser isolation, URL
restoration, renderer termination/recovery, live navigation/popup/permission/
file-chooser/download policy callbacks, managed-profile clearing, and clean CEF
shutdown:

```sh
apple/bin/test-chromium-runtime.sh
```

The hosted XCTest uses an Apple Development identity so Pilot and its embedded
dependencies have one team identity under hardened runtime. Set
`BLAU_CHROMIUM_TEST_CODE_SIGN_IDENTITY` and
`BLAU_CHROMIUM_TEST_DEVELOPMENT_TEAM` to override the local defaults. Ordinary
invocations run the host architecture; set
`BLAU_CHROMIUM_TEST_ARCHITECTURE=x86_64` to run the x86_64 slice under Rosetta.
Result bundles land in a temporary directory (one per architecture); set
`BLAU_CHROMIUM_TEST_RESULT_ROOT` to choose the directory — on failure the
script prints the recorded test failures from the bundle, which is the only
failure detail available under `-quiet`.
The protected release workflow runs both architecture slices. Ordinary
Debug and Release suites skip this one real-engine test and continue using the
stub bridge. Runtime and artifact limits are pinned in
[`performance-budgets.json`](performance-budgets.json); changing a limit is a
reviewed release-policy change. The runtime gate includes a bounded
shutdown-to-zero-helper cleanup measurement for both architectures.
The signed Chromium release workflow runs the same gate before archiving and
notarization. Publication requires GitHub immutable releases to be enabled,
then verifies GitHub's signed release attestation, every local release asset
against that attestation, and a fresh download against the locally produced
bytes and checksum manifest. The protected environment must provide
`GITHUB_RELEASE_POLICY_TOKEN`, a fine-grained token with read-only repository
Administration permission, for the pre-publication immutability check. Asset
publication continues to use the job-scoped `GITHUB_TOKEN`. The workflow also
runs `verify-chromiumkit-support.sh` before building: both macOS architectures
must agree on the latest stable CEF identity, the lock must match it, and its
Chromium patch must match current desktop stable Chrome. A stale runtime cannot
be released by override. The read-only `ChromiumKit Upstream Support` workflow
runs that gate every weekday so upstream movement becomes a failing signal
before the next release attempt.

## Reproduce the artifact

The package command requires Xcode 26 and writes only to an empty output
directory. Reusing one immutable download cache avoids a second network
transfer while still rebuilding from fresh extracted sources:

```sh
export CEF_DOWNLOAD_CACHE="$TMPDIR/blau-cef-cache"
bash apple/bin/package-chromiumkit.sh build "$TMPDIR/chromium-one"
bash apple/bin/package-chromiumkit.sh build "$TMPDIR/chromium-two"

cmp \
  "$TMPDIR/chromium-one/ChromiumKitCEF.runtime.zip" \
  "$TMPDIR/chromium-two/ChromiumKitCEF.runtime.zip"
cmp \
  "$TMPDIR/chromium-one/ChromiumKitCEF.release.json" \
  "$TMPDIR/chromium-two/ChromiumKitCEF.release.json"
```

The packager builds `libcef_dll_wrapper` from each checksummed distribution,
converts the upstream framework to the Xcode 26 `Versions/A` layout, creates
universal arm64/x86_64 Mach-O and wrapper files, normalizes archive metadata,
and emits installed-file hashes, tool versions, compressed/installed sizes,
release metadata, and checksums. The manual
`chromiumkit-bootstrap.yml` workflow performs the same double-package check.

## Validate an archive

Validate framework layout, architectures, the manifest-derived five-helper
set, signatures, JIT entitlements, signing order, and mandatory
`--no-sandbox` rejection:

```sh
apple/bin/validate-chromium-archive.sh path/to/Pilot.xcarchive
```

After notarization and stapling, require Gatekeeper and stapler validation:

```sh
apple/bin/validate-chromium-archive.sh \
  --require-notarization \
  path/to/made.app
```

Nested code is signed inside-out: framework Mach-O files and dylibs, the
framework, then helper bundles. Xcode signs Pilot last. `codesign --deep` is
forbidden because it hides missing or incorrectly entitled nested code.

## Upgrade

1. Select a single published CEF version compatible with the required Xcode
   and macOS deployment targets.
2. Record both architecture-specific URLs, exact byte sizes, SHA-1 values,
   SHA-256 values, CEF commit, Chromium commit, and sandbox compatibility
   commit in `cef-artifacts.json`.
3. Reconcile the helper list and per-process entitlements with that exact CEF
   release. Do not assume a helper count from a previous release.
4. Run manifest tests, package twice from a shared immutable cache, and compare
   every release asset.
5. Build and validate a signed universal archive, then complete the browser
   integration and release checklist in the operations guide.

Never update a URL or version without updating its byte count and both hashes.
Never replace an asset beneath an existing release ID.

## Roll back

Restore the prior checked-in manifest and associated bridge changes, run the
manifest gate, and reinstall. Because cache entries include the release ID and
SHA-256, the previous immutable archives can be reused without accepting the
new release's files. Rebuild using `Chromium`, validate the resulting archive,
and republish under a new made release identifier if distribution is needed.
Rollback does not require deleting browser profiles; profile migrations must
remain backward-compatible or be guarded independently.

[browser-doc]: ../../../docs/chromium-browser.md
[update-runbook]: ../../../docs/chromium-update-runbook.md
