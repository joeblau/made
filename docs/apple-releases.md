# Apple releases

The `Apple Release` GitHub Actions workflow turns a `vMAJOR.MINOR.PATCH` tag
on `main` into one coordinated Apple release:

- Cockpit (the `Pilot` target) is built as a universal Chromium-enabled macOS
  app, signed with Developer ID, notarized, stapled, and attached to a GitHub
  Release as a disk image and ZIP, each with a SHA-256 checksum, and a signed
  Sparkle appcast. The disk image is separately signed, notarized, and stapled.
- Walkie, including Trigger, is uploaded to App Store Connect for TestFlight.
- Kneeboard, including Kneeboard widgets, is uploaded to App Store Connect for
  TestFlight.
- The public GitHub Release is created only after the notarized macOS artifact
  and both TestFlight uploads succeed.

The semantic version comes from the tag. `GITHUB_RUN_NUMBER` and
`GITHUB_RUN_ATTEMPT` form the Apple build number, so retrying a workflow does
not reuse a build number that App Store Connect may already have accepted.

## One-time Apple setup

Create the following identifiers and capabilities in Certificates,
Identifiers & Profiles before the first release:

- `app.blau.copilot`
- `app.blau.copilot.watchkitapp`
- `app.blau.plotter`
- `app.blau.plotter.widgets`
- the `group.app.blau.plotter` App Group, assigned to Plotter and
  PlotterWidgets

## Installation and first launch

The website's macOS download button opens the latest public app release. It
remains usable before the first disk-image release; older releases supply a
ZIP. Each new release includes `Cockpit.dmg`, containing `Cockpit.app`, an
Applications shortcut, and installation instructions. The stable direct URL is
`https://github.com/joeblau/made/releases/latest/download/Cockpit.dmg` once the
first release with this asset is published. Never point the website at an
asset that has not been published yet.

Cockpit requires **macOS 26 or later** and ships for Apple silicon and Intel.
Users drag the app to Applications, launch it there, and eject the disk image.
End users do not need the repository, Bun, Homebrew, or Xcode to use the built-in
terminal, editor, notes, and browser.

First launch presents setup before restoring workspace views or starting
companion discovery and automatic updates. Progress survives relaunches.
Permissions and tools are optional; finishing with skipped items is remembered.
**Cockpit > Set Up Cockpit…** and **Settings > General > Setup** reopen the flow.

| Setup item | Behavior |
| --- | --- |
| Local Network | Explicit Bonjour probe, with denial and timeout states. Companion discovery starts only after setup completes and the user enables it. |
| Accessibility | Explicit request for Walkie's mouse control; status refreshes on return from System Settings. |
| Screen Recording | Explicit request for Kneeboard mirroring; background connections never request it. A relaunch may be needed. |
| Camera and microphone | Current authorization is read without prompting; requests occur only on Enable. Denied access links to System Settings; restricted access stays disabled. |
| Developer tools | Bounded checks for Git/CLT, tmux, authenticated GitHub CLI, installed iOS simulators, Android tools, and a running Docker engine. Missing tools have copyable commands and official instructions. |
| Project folder | Native folder picker grants access up front and creates a workspace in that folder when setup finishes. |
| Updates | Uses Sparkle's persisted automatic-check preference. The updater starts after setup. |

Camera and audio-input entitlements are required by the hardened runtime and
are included in the release signature. Website permissions remain scoped to
their origin. Pairing fingerprints, USB trust, and Android debugging approvals
must be approved for each actual device; setup does not preapprove them. macOS
may also require new approval after access is revoked or system policy changes.
No Full Disk Access or blanket Automation permission is required.

Before tagging, run the normal CI lane and test a notarized build on a clean
Mac user account: mount the DMG, copy to Applications, launch, allow and deny
permissions, quit partway through setup, resume, finish with skipped items,
relaunch without prompts, reopen setup, and pair a real companion. Verify both
Apple silicon and Intel artifacts in the release gates. Local unsigned tests
cannot validate Gatekeeper or persistent TCC grants.

For a packaging-only smoke test, run
`apple/bin/package-macos-dmg.sh /path/to/Cockpit.app /tmp/Cockpit.dmg`, then
mount the image read-only and check the app, Applications link, and instructions.
This does not sign or notarize a local build; the release workflow does both.

## App Store Connect records

Create App Store Connect app records for Walkie (`app.blau.copilot`) and
Kneeboard (`app.blau.plotter`). Apple must know those top-level apps before a
CI upload can be associated with TestFlight.

Create a team App Store Connect API key under **Users and Access >
Integrations > Team Keys**. Use an Admin key so headless Xcode automatic
signing, provisioning, cloud-managed distribution signing, TestFlight upload,
and `notarytool` are authorized. The private `.p8` file can only be downloaded
once. Individual API keys do not support the provisioning endpoints or
`notarytool`, so they cannot replace the team key in this workflow.

Create a **Developer ID Application** certificate for Cockpit. Export the
certificate and its private key from Keychain Access as a password-protected
`.p12`. An Apple Distribution certificate is not stored in GitHub: Xcode uses
the team API key and Apple's cloud-managed distribution signing for the App
Store uploads.

Apple references:

- [Create an App Store Connect API key](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)
- [Create a Developer ID certificate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Upload builds to App Store Connect](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)

## GitHub environment and secrets

Create an `apple-release` GitHub environment. A required reviewer is
recommended because a matching tag uploads binaries to Apple and publishes a
download. Store these environment secrets:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | The 10-character Apple Developer team ID. |
| `APP_STORE_CONNECT_KEY_ID` | The team API key ID. |
| `APP_STORE_CONNECT_ISSUER_ID` | The team API issuer UUID. |
| `APP_STORE_CONNECT_PRIVATE_KEY_P8_BASE64` | Base64-encoded contents of the downloaded `AuthKey_*.p8`. |
| `MACOS_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate and private key. |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |
| `MACOS_SIGNING_IDENTITY` | Full identity, for example `Developer ID Application: Example, Inc. (TEAMID1234)`. |
| `SPARKLE_PRIVATE_KEY` | Private Ed25519 key exported by Sparkle's `generate_keys` tool. Do not base64-encode it again. |

Encode the two files without introducing line wrapping:

```bash
base64 -i AuthKey_KEYID.p8 | pbcopy
base64 -i DeveloperIDApplication.p12 | pbcopy
```

The Sparkle private key is distinct from every Apple credential. Its matching
public key is committed as `SUPublicEDKey` in Cockpit's Info.plist. Keep an
encrypted backup of the private key outside GitHub; GitHub secrets cannot be
read back after creation.

Use a GitHub ruleset to restrict creation and deletion of tags matching `v*`
to release maintainers. The workflow also refuses tags whose target commit is
not reachable from `main`.

## Cut a release

Run the normal pull-request CI on the intended commit, merge it to `main`, and
then push the version tag:

```bash
git switch main
git pull --ff-only
git tag -s v1.2.3 -m "made 1.2.3"
git push origin v1.2.3
```

The first made release for a pinned Chromium version reproduces the verified
runtime from its locked upstream archives. Later releases reuse the immutable
`chromiumkit-<release-id>` GitHub Release when one exists and verify its
release attestation and asset bytes before installation.

## Cockpit updates

Cockpit uses Sparkle 2 for updates outside the Mac App Store. Each semantic app
release is explicitly marked as GitHub's latest release and publishes:

- `made-<version>-macOS.zip`
- `made-<version>-macOS.zip.sha256`
- `Cockpit.dmg`
- `Cockpit.dmg.sha256`
- `appcast.xml`

The appcast points at the immutable, versioned GitHub Release URL rather than a
mutable asset URL. The release workflow signs both the update enclosure and the
feed with `SPARKLE_PRIVATE_KEY`; Cockpit verifies them with its embedded public
key and verifies the Developer ID signature before installation. ChromiumKit
support releases are explicitly prevented from replacing the semantic app
release as GitHub's latest release.

The disk image is created after appcast generation so the signed feed continues
to select only the versioned ZIP. Checksums are generated after stapling, and
publication requires all five assets. The release notes include installation
steps and the minimum macOS version.

The first release containing Sparkle must still be installed manually. Once
that version is running, later semantic releases appear automatically and can
also be requested from **Cockpit > Check for Updates…**.

Cockpit enables `SUEnableInstallerLauncherService` and embeds Sparkle's signed
`Installer.xpc`. This is intentional for our unsandboxed app: Sparkle 2.9.5's
in-process launcher dispatches synchronous `SMJobRemove` calls to the main
queue. A live hang captured on macOS 27 showed Cockpit indefinitely waiting
there. Running the launcher in its XPC service keeps that wait outside the UI
process. Keep the service enabled when updating Sparkle or changing packaging;
the normal recommendation to remove XPC services from unsandboxed apps does
not apply to this isolation requirement. Feed and update signature verification
remain enabled.

`SparkleInstallerIsolationTests` connects to the built service, suspends only
that test host's helper, verifies that the main queue still responds, and then
resumes the helper and checks its reply. It uses nonexistent bundle paths so
it cannot install an update. `PrivacyManifestTests` also checks the built
configuration and executable. `ProcessRunnerTests` cover a separate hang in
which a descendant retains stdout/stderr after the direct child exits; output
collection must remain cancellable and subject to the command's deadline.

Terminal status polling must also stay off the main thread. A second live
sample found the workspace activity gauge inside `tmux`'s synchronous
`waitUntilExit`. `TerminalRuntimeCache` now supplies recent snapshots, coalesces
background refreshes, expires stale process IDs, and discards replies after a
session is removed. Runtime lookup, foreground-command inspection and terminal
teardown use `ProcessRunner` with one-second deadlines. The cache regression
tests include an unresponsive `tmux` substitute while the main actor continues.

Successful upload makes each mobile build appear in App Store Connect after
Apple finishes processing it. Assigning tester groups, completing export
compliance, submitting an external beta for review, and promoting a build to
the App Store remain explicit App Store Connect operations.

If both TestFlight jobs succeed but Cockpit fails, merge the Cockpit fix and run
**Apple Release** manually from `main`. Supply the unchanged release tag and
the failed release run ID. The workflow verifies that both TestFlight jobs in
that run succeeded for the exact tagged commit, then runs only Cockpit and
publishes the GitHub Release. This recovery path never moves the tag or uploads
the mobile builds again.

Do not move or reuse a release tag. If a release needs another binary, make a
new version tag. A workflow retry receives a new build number automatically.
