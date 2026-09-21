# Chromium update and emergency runbook

This runbook governs the CEF/Chromium runtime embedded by Pilot. Chromium is a
fast-moving security dependency, so a passing application build is not by
itself evidence that a pinned runtime remains supported.

The release owner is the maintainer operating the protected
`chromiumkit-release` GitHub environment. A second reviewer owns the security
and rollback sign-off. Neither role may approve its own exception to the
response windows below.

## Supported channel and monitoring

Pilot ships only a CEF build marked `stable` for both `macosarm64` and
`macosx64`. Both minimal archives must report the same CEF version, Chromium
version, CEF commit, and sandbox compatibility revision. Beta, development,
canary, floating, architecture-mismatched, and republished inputs are not
release candidates.

The release owner checks these sources every business day and again before
each Pilot release:

- [CEF Automated Builds](https://cef-builds.spotifycdn.com/index.html) and its
  `index.json` feed for a newer matching stable macOS build.
- [Chrome Releases](https://chromereleases.googleblog.com/) for desktop stable
  security fixes affecting the pinned Chromium milestone.
- [Chromium Security](https://www.chromium.org/Home/chromium-security/) for
  security guidance and the canonical stable-channel security-note source.
- [Chromium Dash](https://chromiumdash.appspot.com/schedule) for upcoming
  branch and stable dates.

The read-only `ChromiumKit Upstream Support` workflow runs the same check each
weekday. It fails when the two macOS CEF feeds disagree, the lock is not their
latest stable build, or stable desktop Chrome has advanced beyond the embedded
patch. Scheduled automation is an alert, not an acknowledgment; the release
owner still records and classifies the finding.

Record each finding in the Chromium update issue: observation time in UTC,
pinned CEF and Chromium versions, latest stable desktop Chromium version,
latest matching stable CEF version for both architectures, applicable
security severities, owner, response class, and deadline. Never copy
confidential vulnerability details into a public issue.

Normal cadence is one reviewed stable CEF update per Chromium milestone and
within 14 calendar days of a newer stable CEF patch. These emergency windows
override that cadence:

| Class | Trigger | Begin response | Supported build or disablement |
| --- | --- | ---: | ---: |
| Critical | Known exploitation, critical severity, sandbox escape, or a flaw on Pilot's reachable paths | 4 hours | 48 hours |
| High | Other high-severity fix in the pinned milestone | 1 business day | 7 calendar days |
| Routine | Medium/low fix or newer stable CEF without an applicable high-severity fix | 3 business days | 14 calendar days |

If a suitable stable CEF build is not available by the deadline, Chromium is
unsupported for new Pilot releases. Keep the existing WebKit browser
available, remove or disable the Chromium entry point in the supported build,
and state the affected Pilot and Chromium versions in the release notes. Do
not silently extend a deadline or move to a beta CEF build.

## Triage and compatibility decision

Open or update one tracking issue and attach links to the public upstream
release material. Determine whether the fix touches browser, renderer, GPU,
network, media, PDF, downloads, file selection, permissions, storage, or
sandbox behavior used by Pilot. Treat uncertain reachability as affected.

Before accepting a candidate:

1. Confirm the CEF feed reports the exact same stable build for arm64 and
   x86_64 and capture each archive's URL, size, SHA-1, independently computed
   SHA-256, CEF commit, Chromium commit, and sandbox compatibility commit.
2. Review upstream API changes and reconcile every helper role, resource,
   command-line switch, entitlement, permission callback, and profile change.
3. Decide profile compatibility in both directions. Migrations must remain
   readable by the rollback runtime or be versioned behind a separate,
   reversible migration. A destructive Chromium profile migration blocks
   release.
4. Review proxy, DNS, certificate trust, client-certificate, and enterprise
   policy behavior. Pilot uses CEF defaults unless a separately reviewed
   policy is checked in; it does not inherit a system Chrome profile or Chrome
   enterprise policy.
5. Re-review the browser policy boundary: navigation, popups, external
   schemes, downloads, file input, permissions, DevTools, profile deletion,
   diagnostics redaction, and Annotate IPC. Annotate stays unavailable in
   Chromium until its main-frame/current-navigation/single-use confirmation
   boundary is implemented and reviewed.

## Rebuild and test

Change the complete lock and its mirrored diagnostics constants in one review.
Increment the made release suffix even when returning to an older CEF version;
an immutable release ID is never reused.

Run the artifact-free gates first:

```sh
bash apple/bin/package-chromiumkit.sh manifest
bash apple/bin/test-chromiumkit-update-rollback.sh
apple/bin/test.sh all
```

Then package twice from one checksummed cache and compare every emitted asset,
install the verified runtime, and run the native engine gate for both
architectures:

```sh
export CEF_DOWNLOAD_CACHE="$TMPDIR/blau-cef-cache"
bash apple/bin/package-chromiumkit.sh build "$TMPDIR/chromium-one"
bash apple/bin/package-chromiumkit.sh build "$TMPDIR/chromium-two"
for asset in \
  ChromiumKitCEF.runtime.zip \
  ChromiumKitCEF.release.json \
  ChromiumKitCEF.checksums.txt; do
  cmp "$TMPDIR/chromium-one/$asset" "$TMPDIR/chromium-two/$asset"
done
apple/bin/update-chromiumkit-artifact.sh \
  --release-directory "$TMPDIR/chromium-one"
for architecture in arm64 x86_64; do
  BLAU_CHROMIUM_TEST_ARCHITECTURE="$architecture" \
    apple/bin/test-chromium-runtime.sh
done
```

The protected `ChromiumKit Signed Release` workflow is the release authority.
It rebuilds the inputs, enforces size and runtime budgets, archives a universal
Pilot, validates every nested signature and entitlement, notarizes and
staples, publishes an immutable release, verifies GitHub's release
attestation, and downloads the published assets for a fresh byte comparison.
Its protected-environment approval is the second security sign-off. Before
spending build or signing time, `verify-chromiumkit-support.sh` also requires
the lock to equal the latest matching stable CEF build for both macOS
architectures and requires that embedded Chromium patch to equal current
desktop stable Chrome. There is no release override for a stale runtime.

## Rollback

Rollback is a new forward release containing the prior known-good Chromium
runtime. Never delete or mutate the critical release, move its tag, replace an
asset, mix CEF revisions, or distribute a locally copied archive.

1. Identify the prior immutable release and verify it and its assets with
   `gh release verify` and `gh release verify-asset`.
2. Create a rollback branch from the affected Pilot release. Restore the prior
   lock, bridge compatibility changes, helper layout, entitlements, budgets,
   and diagnostics constants as one unit.
3. Increment the made release suffix to a new unused ID. Preserve any
   unrelated application fixes required by the current Pilot release.
4. Run all artifact-free, two-architecture real-engine, reproducibility,
   archive, signing, notarization, and publication gates above.
5. Confirm the rollback runtime can open a copied candidate profile. Do not
   use a maintainer's real browser profile for the test.
6. Publish the rollback under its new immutable tag, verify the attestation
   and fresh download, then update the incident and Pilot release notes.

The installer verifies a candidate completely before touching the active
runtime. It moves the prior directory aside on the same filesystem and
restores it on an interrupted or failed swap. The offline drill additionally
proves that a corrupt critical update leaves release A unchanged and that an
A → B → A sequence restores A byte-for-byte.

## Critical-update drill

Run this drill before first supported Chromium distribution, at least every
six months, and whenever signing, notarization, release immutability, helper
layout, or installer transaction logic changes:

1. Select an already published, supported Chromium release as A.
2. Produce candidate B through the protected workflow and verify its immutable
   release, signed/notarized archive, attestation, and downloaded bytes.
3. Exercise B on a copied profile and record the real-engine and performance
   results for both architectures.
4. Declare a simulated critical regression. Follow the rollback procedure to
   produce new signed/notarized release C containing A's complete Chromium
   runtime under a new release ID.
5. Verify C's immutable attestation and fresh download, install C, rerun the
   two-architecture smoke gate, and confirm profile readability and zero
   residual helpers.

Attach the A, B, and C tags and commit SHAs; workflow run URLs; release
attestation results; notarization submission IDs; archive-validation output;
artifact hashes; performance measurements; profile-compatibility result;
start, decision, publish, and recovery times; reviewers; and follow-up actions
to the drill issue. A dry run that does not produce both B and C signed
artifacts does not satisfy the drill.

## Incident completion and end of support

Keep the incident open until the supported release or explicit disablement is
available, published bytes have been independently verified, and affected
versions and user action are documented. Record detection-to-triage,
triage-to-decision, decision-to-publication, and publication-to-confirmation
times against the response class.

A pinned runtime reaches end of support when any of these is true:

- its critical or high response deadline expires without a suitable stable CEF
  build;
- either macOS architecture disappears or no longer has the same stable CEF
  identity;
- the required CEF/Xcode/macOS combination cannot pass signing,
  notarization, sandbox, real-engine, or performance gates;
- rollback profile compatibility cannot be maintained;
- upstream no longer publishes security fixes for its Chromium milestone.

At end of support, stop distributing Chromium-enabled Pilot builds, keep
WebKit available, preserve profiles unless the user explicitly clears them,
publish the exact last-supported versions, and open a replacement or removal
decision. Re-enable Chromium only after a new stable lock completes this full
runbook and security review.
