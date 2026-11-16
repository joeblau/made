#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATER="$APPLE_ROOT/bin/update-chromiumkit-artifact.sh"
VERIFIER="$APPLE_ROOT/bin/verify-installed-chromiumkit.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/blau-chromiumkit-rollback.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'ChromiumKit rollback drill error: %s\n' "$*" >&2
  exit 1
}

write_lock() {
  local release_id="$1"
  local output="$2"
  jq -nS --arg release_id "$release_id" '{
    schemaVersion: 1,
    releaseID: $release_id,
    cef: {
      version: ("fixture-" + $release_id),
      commit: ("cef-" + $release_id),
      chromiumCommit: ("chromium-" + $release_id),
      sandboxCompatibilityCommit: ("sandbox-" + $release_id),
      requiredXcodeMajorVersion: 27
    },
    sourceArchives: [
      {
        architecture: "arm64",
        distributionDirectory: ("fixture-" + $release_id + "-arm64"),
        url: "https://example.invalid/arm64",
        bytes: 1,
        sha1: "0000000000000000000000000000000000000000",
        sha256:
          "0000000000000000000000000000000000000000000000000000000000000000"
      },
      {
        architecture: "x86_64",
        distributionDirectory: ("fixture-" + $release_id + "-x86_64"),
        url: "https://example.invalid/x86_64",
        bytes: 1,
        sha1: "1111111111111111111111111111111111111111",
        sha256:
          "1111111111111111111111111111111111111111111111111111111111111111"
      }
    ],
    artifactLayout: {
      root: "Artifacts/CEF",
      framework:
        "Artifacts/CEF/Chromium Embedded Framework.framework",
      headers: "Artifacts/CEF/include",
      wrapperLibrary: "Artifacts/CEF/lib/libcef_dll_wrapper.a",
      license: "Artifacts/CEF/LICENSE.txt",
      credits: "Artifacts/CEF/CREDITS.html",
      receipt: "Artifacts/CEF/ChromiumKitCEF.release.json",
      frameworkExecutable: "Chromium Embedded Framework",
      architectures: ["arm64", "x86_64"]
    }
  }' > "$output"
}

make_release() {
  local lock="$1"
  local marker="$2"
  local output="$3"
  local runtime="$work/runtime-$marker"
  local cef="$runtime/CEF"
  local archive="$output/ChromiumKitCEF.runtime.zip"
  local receipt="$output/ChromiumKitCEF.release.json"
  local archive_sha archive_bytes installed_bytes installed_files

  mkdir -p \
    "$cef/Chromium Embedded Framework.framework/Versions/A" \
    "$cef/include" \
    "$cef/lib" \
    "$output"
  printf 'framework-%s\n' "$marker" \
    > "$cef/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
  printf 'header-%s\n' "$marker" > "$cef/include/cef_app.h"
  printf 'wrapper-%s\n' "$marker" > "$cef/lib/libcef_dll_wrapper.a"
  printf 'license-%s\n' "$marker" > "$cef/LICENSE.txt"
  printf 'credits-%s\n' "$marker" > "$cef/CREDITS.html"
  cp "$lock" "$cef/cef-artifacts.json"

  installed_files="$(
    jq -n \
      --arg framework "$(shasum -a 256 \
        "$cef/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework" |
        awk '{print $1}')" \
      --arg header "$(shasum -a 256 "$cef/include/cef_app.h" |
        awk '{print $1}')" \
      --arg wrapper "$(shasum -a 256 "$cef/lib/libcef_dll_wrapper.a" |
        awk '{print $1}')" \
      --arg license "$(shasum -a 256 "$cef/LICENSE.txt" |
        awk '{print $1}')" \
      --arg credits "$(shasum -a 256 "$cef/CREDITS.html" |
        awk '{print $1}')" \
      --arg lock_sha "$(shasum -a 256 "$cef/cef-artifacts.json" |
        awk '{print $1}')" \
      '{
        "Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework":
          $framework,
        "include/cef_app.h": $header,
        "lib/libcef_dll_wrapper.a": $wrapper,
        "LICENSE.txt": $license,
        "CREDITS.html": $credits,
        "cef-artifacts.json": $lock_sha
      }'
  )"
  (
    cd "$runtime"
    find CEF -print | LC_ALL=C sort | zip -X -q "$archive" -@
  )
  archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
  archive_bytes="$(stat -f '%z' "$archive")"
  installed_bytes="$(find "$cef" -type f -exec stat -f '%z' {} + |
    awk '{ total += $1 } END { print total + 0 }')"
  jq -nS \
    --arg artifact_sha "$archive_sha" \
    --argjson artifact_bytes "$archive_bytes" \
    --argjson installed_bytes "$installed_bytes" \
    --argjson installed_files "$installed_files" \
    --slurpfile lock "$lock" \
    '{
      schemaVersion: 1,
      releaseID: $lock[0].releaseID,
      artifact: "ChromiumKitCEF.runtime.zip",
      artifactSHA256: $artifact_sha,
      artifactBytes: $artifact_bytes,
      installedBytes: $installed_bytes,
      installedFiles: $installed_files,
      cef: $lock[0].cef,
      sourceArchives: $lock[0].sourceArchives,
      architectures: $lock[0].artifactLayout.architectures,
      toolVersions: {
        cmake: "fixture",
        xcode: "fixture",
        zip: "fixture"
      }
    }' > "$receipt"
  (
    cd "$output"
    shasum -a 256 \
      ChromiumKitCEF.runtime.zip \
      ChromiumKitCEF.release.json \
      > ChromiumKitCEF.checksums.txt
  )
}

refresh_release_checksums() {
  local release="$1"
  (
    cd "$release"
    shasum -a 256 \
      ChromiumKitCEF.runtime.zip \
      ChromiumKitCEF.release.json \
      > ChromiumKitCEF.checksums.txt
  )
}

package_root="$work/ChromiumKit"
release_a="$work/release-a"
release_b="$work/release-b"
mkdir -p "$package_root"
write_lock "rollback-a" "$work/lock-a.json"
write_lock "critical-b" "$work/lock-b.json"
make_release "$work/lock-a.json" "a" "$release_a"
make_release "$work/lock-b.json" "b" "$release_b"

cp "$work/lock-a.json" "$package_root/cef-artifacts.json"
"$UPDATER" \
  --package-root "$package_root" \
  --release-directory "$release_a"
"$VERIFIER" --package-root "$package_root"
cp -R "$package_root/Artifacts/CEF" "$work/expected-a"

printf 'tampering\n' >> "$package_root/Artifacts/CEF/include/cef_app.h"
if "$VERIFIER" --package-root "$package_root"; then
  fail "the installed-runtime verifier accepted a changed receipt file"
fi
cp "$work/expected-a/include/cef_app.h" \
  "$package_root/Artifacts/CEF/include/cef_app.h"
"$VERIFIER" --package-root "$package_root"

cp "$work/lock-b.json" "$package_root/cef-artifacts.json"
cp -R "$release_b" "$work/corrupt-b"
printf 'corruption\n' >> "$work/corrupt-b/ChromiumKitCEF.runtime.zip"
if "$UPDATER" \
  --package-root "$package_root" \
  --release-directory "$work/corrupt-b"; then
  fail "a corrupted critical update was accepted"
fi
diff -qr "$work/expected-a" "$package_root/Artifacts/CEF" >/dev/null ||
  fail "a rejected critical update changed the installed release"

cp -R "$release_b" "$work/wrong-size-b"
jq '.artifactBytes += 1' \
  "$work/wrong-size-b/ChromiumKitCEF.release.json" \
  > "$work/wrong-size-b/ChromiumKitCEF.release.next.json"
mv "$work/wrong-size-b/ChromiumKitCEF.release.next.json" \
  "$work/wrong-size-b/ChromiumKitCEF.release.json"
refresh_release_checksums "$work/wrong-size-b"
if "$UPDATER" \
  --package-root "$package_root" \
  --release-directory "$work/wrong-size-b"; then
  fail "a release with a false archive byte count was accepted"
fi
diff -qr "$work/expected-a" "$package_root/Artifacts/CEF" >/dev/null ||
  fail "a false archive byte count changed the installed release"

cp -R "$release_b" "$work/unsafe-b"
printf 'outside CEF\n' > "$work/unexpected-member"
(
  cd "$work"
  zip -q "$work/unsafe-b/ChromiumKitCEF.runtime.zip" unexpected-member
)
unsafe_sha="$(shasum -a 256 \
  "$work/unsafe-b/ChromiumKitCEF.runtime.zip" | awk '{print $1}')"
unsafe_bytes="$(stat -f '%z' \
  "$work/unsafe-b/ChromiumKitCEF.runtime.zip")"
jq --arg sha "$unsafe_sha" --argjson bytes "$unsafe_bytes" \
  '.artifactSHA256 = $sha | .artifactBytes = $bytes' \
  "$work/unsafe-b/ChromiumKitCEF.release.json" \
  > "$work/unsafe-b/ChromiumKitCEF.release.next.json"
mv "$work/unsafe-b/ChromiumKitCEF.release.next.json" \
  "$work/unsafe-b/ChromiumKitCEF.release.json"
refresh_release_checksums "$work/unsafe-b"
if "$UPDATER" \
  --package-root "$package_root" \
  --release-directory "$work/unsafe-b"; then
  fail "a release with an out-of-root archive member was accepted"
fi
diff -qr "$work/expected-a" "$package_root/Artifacts/CEF" >/dev/null ||
  fail "an unsafe archive member changed the installed release"

"$UPDATER" \
  --package-root "$package_root" \
  --release-directory "$release_b"
"$VERIFIER" --package-root "$package_root"
[[ "$(jq -r '.releaseID' \
  "$package_root/Artifacts/CEF/ChromiumKitCEF.release.json")" == \
  "critical-b" ]] || fail "the critical update was not installed"

cp "$work/lock-a.json" "$package_root/cef-artifacts.json"
"$UPDATER" \
  --package-root "$package_root" \
  --release-directory "$release_a"
"$VERIFIER" --package-root "$package_root"
diff -qr "$work/expected-a" "$package_root/Artifacts/CEF" >/dev/null ||
  fail "rollback did not restore the prior release byte-for-byte"

printf '%s\n' \
  'ChromiumKit critical-update rollback drill passed: rejected malformed releases, installed B, restored A.'
