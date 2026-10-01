#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_ROOT="$APPLE_ROOT/Packages/ChromiumKit"
MANIFEST="${BLAU_CHROMIUM_MANIFEST:-$PACKAGE_ROOT/cef-artifacts.json}"

usage() {
  printf '%s\n' \
    'Usage: assemble-chromium-runtime.sh <Cockpit.app> <helper-template.app> [signing-identity]' >&2
  exit 2
}

fail() {
  printf 'Chromium runtime assembly error: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 2 && $# -le 3 ]] || usage
APP="$1"
HELPER_TEMPLATE="$2"
IDENTITY="${3:-${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}}"
[[ -d "$APP/Contents" ]] || fail "invalid Pilot bundle: $APP"
[[ -d "$HELPER_TEMPLATE/Contents" ]] ||
  fail "invalid helper template: $HELPER_TEMPLATE"
[[ -n "$IDENTITY" ]] || fail "a signing identity is required"

case " ${OTHER_CODE_SIGN_FLAGS:-} " in
  *" --deep "*|*" --deep") fail "codesign --deep is forbidden" ;;
esac

for tool in codesign ditto file find jq lipo plutil; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "missing required tool: $tool"
done

"$APPLE_ROOT/bin/verify-installed-chromiumkit.sh"

artifact_root="$PACKAGE_ROOT/$(jq -r '.artifactLayout.root' "$MANIFEST")"
framework_name="$(basename "$(jq -r '.artifactLayout.framework' "$MANIFEST")")"
source_framework="$artifact_root/$framework_name"
source_license="$PACKAGE_ROOT/$(jq -r '.artifactLayout.license' "$MANIFEST")"
source_credits="$PACKAGE_ROOT/$(jq -r '.artifactLayout.credits' "$MANIFEST")"
[[ -d "$source_framework" ]] ||
  fail "CEF artifact is not installed; run update-chromiumkit-artifact.sh"
[[ -f "$source_license" ]] || fail "CEF license is missing"
[[ -f "$source_credits" ]] || fail "Chromium third-party notices are missing"

work="$(mktemp -d "${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}/blau-chromium-assembly.XXXXXX")"
trap 'rm -rf "$work"' EXIT
staged="$work/Frameworks"
mkdir -p "$staged"
ditto "$source_framework" "$staged/$framework_name"

template_executable="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleExecutable' "$HELPER_TEMPLATE/Contents/Info.plist")"
bundle_id_base="$(jq -r '.helperLayout.bundleIdentifierBase' "$MANIFEST")"
ls_ui_element="$(jq -r \
  'if .helperLayout.lsUIElement then "YES" else "NO" end' "$MANIFEST")"
while IFS= read -r helper; do
  bundle_name="$(jq -r '.bundleName' <<<"$helper")"
  executable_name="$(jq -r '.executableName' <<<"$helper")"
  id_suffix="$(jq -r '.bundleIdentifierSuffix' <<<"$helper")"
  helper_path="$staged/$bundle_name"
  ditto "$HELPER_TEMPLATE" "$helper_path"
  rm -rf "$helper_path/Contents/_CodeSignature"
  mv "$helper_path/Contents/MacOS/$template_executable" \
    "$helper_path/Contents/MacOS/$executable_name"
  plutil -replace CFBundleExecutable -string "$executable_name" \
    "$helper_path/Contents/Info.plist"
  plutil -replace CFBundleName -string "${bundle_name%.app}" \
    "$helper_path/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$bundle_id_base$id_suffix" \
    "$helper_path/Contents/Info.plist"
  plutil -replace LSUIElement -bool "$ls_ui_element" \
    "$helper_path/Contents/Info.plist"
done < <(jq -c '.helperLayout.helpers[]' "$MANIFEST")

frameworks="$APP/Contents/Frameworks"
mkdir -p "$frameworks"
rm -rf "$frameworks/$framework_name"
ditto "$staged/$framework_name" "$frameworks/$framework_name"
while IFS= read -r bundle_name; do
  rm -rf "$frameworks/$bundle_name"
  ditto "$staged/$bundle_name" "$frameworks/$bundle_name"
done < <(jq -r '.helperLayout.helpers[].bundleName' "$MANIFEST")

timestamp_argument="--timestamp=none"
if [[ "${BLAU_CHROMIUM_CODESIGN_TIMESTAMP:-NO}" == "YES" ||
      "${ACTION:-}" == "install" ]]; then
  timestamp_argument="--timestamp"
fi
operations="$work/signing-operations.jsonl"
: > "$operations"
record_signing() {
  local path="$1"
  local entitlements="${2:-}"
  jq -nc --arg path "${path#"$APP/"}" \
    --arg identity "$IDENTITY" \
    --arg entitlements "$entitlements" \
    --arg timestamp "$timestamp_argument" \
    '{
      path: $path,
      identity: $identity,
      entitlements: (if $entitlements == "" then null else $entitlements end),
      arguments: ["--force", "--sign", $identity, "--options", "runtime", $timestamp]
    }' >> "$operations"
}

framework="$frameworks/$framework_name"
while IFS= read -r binary; do
  if file "$binary" | grep -q 'Mach-O'; then
    codesign --force --sign "$IDENTITY" --options runtime \
      "$timestamp_argument" "$binary"
    record_signing "$binary"
  fi
done < <(find "$framework/Versions/A" -type f -print | LC_ALL=C sort)
codesign --force --sign "$IDENTITY" --options runtime \
  "$timestamp_argument" "$framework"
record_signing "$framework"

while IFS= read -r helper; do
  bundle_name="$(jq -r '.bundleName' <<<"$helper")"
  entitlements="$(jq -r '.entitlements // empty' <<<"$helper")"
  helper_path="$frameworks/$bundle_name"
  arguments=(--force --sign "$IDENTITY" --options runtime "$timestamp_argument")
  if [[ -n "$entitlements" ]]; then
    [[ -f "$APPLE_ROOT/$entitlements" ]] ||
      fail "missing helper entitlements: $entitlements"
    arguments+=(--entitlements "$APPLE_ROOT/$entitlements")
  fi
  codesign "${arguments[@]}" "$helper_path"
  record_signing "$helper_path" "$entitlements"
done < <(jq -c '.helperLayout.helpers[]' "$MANIFEST")

legal_resources="$APP/Contents/Resources/Chromium/CEF"
rm -rf "$legal_resources"
mkdir -p "$legal_resources"
ditto "$source_license" "$legal_resources/$(basename "$source_license")"
ditto "$source_credits" "$legal_resources/$(basename "$source_credits")"
jq -sS \
  --arg manifestReleaseID "$(jq -r '.releaseID' "$MANIFEST")" \
  '{
    schemaVersion: 1,
    manifestReleaseID: $manifestReleaseID,
    operations: .,
    pilotSignedLastBy: "Xcode CodeSign action"
  }' "$operations" \
  > "$APP/Contents/Resources/ChromiumRuntimeSigning.json"

printf 'Assembled and nested-signed Chromium runtime in %s\n' "$APP"
