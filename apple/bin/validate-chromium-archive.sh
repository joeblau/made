#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_ROOT="$APPLE_ROOT/Packages/ChromiumKit"
MANIFEST="${BLAU_CHROMIUM_MANIFEST:-$PACKAGE_ROOT/cef-artifacts.json}"
REQUIRE_NOTARIZATION=0
ALLOW_AD_HOC=0

fail() {
  printf 'Chromium archive validation error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-notarization)
      REQUIRE_NOTARIZATION=1
      shift
      ;;
    --allow-ad-hoc)
      ALLOW_AD_HOC=1
      shift
      ;;
    --*)
      fail "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done
[[ $# == 1 ]] ||
  fail "usage: validate-chromium-archive.sh [--require-notarization] [--allow-ad-hoc] <made.app|xcarchive>"
[[ "$REQUIRE_NOTARIZATION" == 0 || "$ALLOW_AD_HOC" == 0 ]] ||
  fail "--require-notarization cannot be combined with --allow-ad-hoc"

input="$1"
if [[ "$input" == *.xcarchive ]]; then
  APP="$input/Products/Applications/made.app"
else
  APP="$input"
fi
[[ -d "$APP/Contents" ]] || fail "Pilot application was not found"

for tool in awk cmp codesign file find grep jq lipo plutil readlink sed sort; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "missing required tool: $tool"
done
jq -e '.schemaVersion == 1 and .security.chromiumSandboxRequired == true' \
  "$MANIFEST" >/dev/null || fail "invalid Chromium artifact manifest"

work="$(mktemp -d "${TMPDIR:-/tmp}/blau-chromium-validation.XXXXXX")"
trap 'rm -rf "$work"' EXIT

sorted_architectures() {
  lipo -archs "$1" | tr ' ' '\n' | LC_ALL=C sort |
    tr '\n' ' ' | sed 's/ $//'
}

signature_details() {
  local path="$1"
  local output="$2"
  codesign -d --verbose=4 "$path" > /dev/null 2> "$output"
}

verify_signature() {
  local path="$1"
  local label="$2"
  local expected_team="$3"
  local details="$work/signature-$RANDOM.txt"
  codesign --verify --strict --verbose=2 "$path"
  signature_details "$path" "$details"
  grep -Eq '^CodeDirectory .*flags=.*runtime' "$details" ||
    fail "$label is not hardened-runtime signed"
  if [[ -n "$expected_team" ]]; then
    [[ "$(sed -n 's/^TeamIdentifier=//p' "$details")" == "$expected_team" ]] ||
      fail "$label signing team differs from Pilot"
  fi
  if [[ "$REQUIRE_NOTARIZATION" == 1 ]]; then
    grep -q '^Timestamp=' "$details" ||
      fail "$label lacks a trusted signing timestamp"
  fi
}

canonical_entitlements() {
  local path="${1:-}"
  local dump="$work/entitlements-$RANDOM.plist"
  if [[ -z "$path" ]]; then
    printf '{}\n'
    return
  fi
  codesign -d --entitlements :- "$path" > "$dump" 2>/dev/null || true
  if [[ ! -s "$dump" ]]; then
    printf '{}\n'
  else
    plutil -convert json -o - "$dump" | jq -cS .
  fi
}

expected_entitlements() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    printf '{}\n'
  else
    plutil -convert json -o - "$path" | jq -cS .
  fi
}

verify_exact_entitlements() {
  local signed_path="$1"
  local expected_path="${2:-}"
  local label="$3"
  local actual expected
  actual="$(canonical_entitlements "$signed_path")"
  expected="$(expected_entitlements "$expected_path")"
  [[ "$actual" == "$expected" ]] ||
    fail "$label entitlements differ from reviewed policy"
}

app_details="$work/app-signature.txt"
codesign --verify --strict --verbose=2 "$APP"
signature_details "$APP" "$app_details"
grep -Eq '^CodeDirectory .*flags=.*runtime' "$app_details" ||
  fail "Pilot is not hardened-runtime signed"
app_team="$(sed -n 's/^TeamIdentifier=//p' "$app_details")"
if [[ -z "$app_team" && "$ALLOW_AD_HOC" == 0 ]]; then
  fail "Pilot lacks a signing team"
fi
if [[ "$REQUIRE_NOTARIZATION" == 1 ]]; then
  grep -q '^Timestamp=' "$app_details" ||
    fail "Pilot lacks a trusted signing timestamp"
fi
verify_exact_entitlements "$APP" \
  "$APPLE_ROOT/Sources/Pilot/Pilot.entitlements" Pilot

framework_name="$(basename "$(jq -r '.artifactLayout.framework' "$MANIFEST")")"
framework="$APP/Contents/Frameworks/$framework_name"
executable="$(jq -r '.artifactLayout.frameworkExecutable' "$MANIFEST")"
[[ -d "$framework" ]] || fail "CEF framework is missing"

expected_top="$work/expected-frameworks.txt"
{
  printf '%s\n' "$framework_name"
  jq -r '.helperLayout.helpers[].bundleName' "$MANIFEST"
} | LC_ALL=C sort > "$expected_top"
additional_frameworks="$work/additional-frameworks.txt"
: > "$additional_frameworks"
find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print |
  while IFS= read -r path; do basename "$path"; done |
  LC_ALL=C sort |
  while IFS= read -r entry; do
    if grep -Fxq "$entry" "$expected_top"; then
      continue
    fi
    [[ "$entry" == *.framework &&
       -d "$APP/Contents/Frameworks/$entry" ]] ||
      fail "Contents/Frameworks contains an unexpected entry: $entry"
    printf '%s\n' "$APP/Contents/Frameworks/$entry" \
      >> "$additional_frameworks"
  done
while IFS= read -r entry; do
  [[ -e "$APP/Contents/Frameworks/$entry" ]] ||
    fail "required Chromium framework entry is missing: $entry"
done < "$expected_top"

[[ "$(readlink "$framework/$executable")" == \
    "Versions/A/$executable" ]] || fail "invalid CEF executable symlink"
[[ "$(readlink "$framework/Libraries")" == \
    "Versions/A/Libraries" ]] || fail "invalid CEF Libraries symlink"
[[ "$(readlink "$framework/Resources")" == \
    "Versions/A/Resources" ]] || fail "invalid CEF Resources symlink"
[[ "$(readlink "$framework/Versions/Current")" == "A" ]] ||
  fail "invalid CEF Current symlink"
[[ "$(sorted_architectures "$framework/Versions/A/$executable")" == \
    "arm64 x86_64" ]] || fail "CEF executable is not universal"

expected_signing_paths="$work/expected-signing-paths.txt"
allowed_code="$work/allowed-code.txt"
: > "$expected_signing_paths"
: > "$allowed_code"
while IFS= read -r additional_framework; do
  [[ -n "$additional_framework" ]] || continue
  label="embedded framework $(basename "$additional_framework")"
  verify_signature "$additional_framework" "$label" "$app_team"
  verify_exact_entitlements "$additional_framework" "" "$label"
  found_macho=0
  sparkle_macho_paths="$work/sparkle-macho-paths.txt"
  : > "$sparkle_macho_paths"
  while IFS= read -r binary; do
    if file "$binary" | grep -q 'Mach-O'; then
      found_macho=1
      [[ "$(sorted_architectures "$binary")" == "arm64 x86_64" ]] ||
        fail "non-universal binary in $label: $binary"
      verify_signature "$binary" "$label nested binary" "$app_team"
      relative_framework_path="${binary#"$additional_framework/"}"
      if [[ "$(basename "$additional_framework")" == \
            "Sparkle.framework" && "$relative_framework_path" == \
            "Versions/B/Autoupdate" ]]; then
        [[ "$(canonical_entitlements "$binary")" == \
          '{"com.apple.application-identifier":"org.sparkle-project.Sparkle.Autoupdate"}' ]] ||
          fail "Sparkle Autoupdate entitlements differ from reviewed policy"
      else
        verify_exact_entitlements "$binary" "" "$label nested binary"
      fi
      if [[ "$(basename "$additional_framework")" == \
            "Sparkle.framework" ]]; then
        printf '%s\n' "$relative_framework_path" >> "$sparkle_macho_paths"
      fi
      printf '%s\n' "${binary#"$APP/"}" >> "$allowed_code"
    fi
  done < <(find "$additional_framework" -type f -print | LC_ALL=C sort)
  [[ "$found_macho" == 1 ]] || fail "$label contains no Mach-O payload"
  if [[ "$(basename "$additional_framework")" == "Sparkle.framework" ]]; then
    sparkle_version="$(jq -r '
      .pins[] | select(.identity == "sparkle") | .state.version
    ' "$APPLE_ROOT/made.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")"
    [[ -n "$sparkle_version" && "$sparkle_version" != "null" ]] ||
      fail "Sparkle is missing from Package.resolved"
    [[ "$(plutil -extract CFBundleShortVersionString raw \
      "$additional_framework/Resources/Info.plist")" == "$sparkle_version" ]] ||
      fail "embedded Sparkle version differs from Package.resolved"
    cat > "$work/expected-sparkle-macho-paths.txt" <<'SPARKLE_PATHS'
Versions/B/Autoupdate
Versions/B/Sparkle
Versions/B/Updater.app/Contents/MacOS/Updater
Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader
Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer
SPARKLE_PATHS
    cmp "$work/expected-sparkle-macho-paths.txt" \
      "$sparkle_macho_paths" >/dev/null ||
      fail "embedded Sparkle executable layout differs from reviewed policy"
  fi
done < "$additional_frameworks"
while IFS= read -r binary; do
  if file "$binary" | grep -q 'Mach-O'; then
    [[ "$(sorted_architectures "$binary")" == "arm64 x86_64" ]] ||
      fail "non-universal CEF library: $binary"
    verify_signature "$binary" "CEF nested binary" "$app_team"
    verify_exact_entitlements "$binary" "" "CEF nested binary"
    printf '%s\n' "${binary#"$APP/"}" >> "$expected_signing_paths"
    printf '%s\n' "${binary#"$APP/"}" >> "$allowed_code"
  fi
done < <(find "$framework/Versions/A" -type f -print | LC_ALL=C sort)
verify_signature "$framework" "CEF framework" "$app_team"
verify_exact_entitlements "$framework" "" "CEF framework"
printf '%s\n' "${framework#"$APP/"}" >> "$expected_signing_paths"

bundle_id_base="$(jq -r '.helperLayout.bundleIdentifierBase' "$MANIFEST")"
expected_lsui_element="$(jq -r '.helperLayout.lsUIElement' "$MANIFEST")"
while IFS= read -r helper; do
  role="$(jq -r '.role' <<<"$helper")"
  bundle_name="$(jq -r '.bundleName' <<<"$helper")"
  executable_name="$(jq -r '.executableName' <<<"$helper")"
  id_suffix="$(jq -r '.bundleIdentifierSuffix' <<<"$helper")"
  entitlements="$(jq -r '.entitlements // empty' <<<"$helper")"
  helper_path="$APP/Contents/Frameworks/$bundle_name"
  plist="$helper_path/Contents/Info.plist"
  binary="$helper_path/Contents/MacOS/$executable_name"
  [[ -x "$binary" ]] || fail "$role helper executable is missing"
  [[ "$(plutil -extract CFBundleExecutable raw "$plist")" == \
      "$executable_name" ]] || fail "$role helper executable metadata differs"
  [[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == \
      "$bundle_id_base$id_suffix" ]] || fail "$role helper bundle ID differs"
  [[ "$(plutil -extract LSUIElement raw "$plist")" == \
      "$expected_lsui_element" ]] ||
    fail "$role helper LSUIElement differs from the manifest"
  [[ "$(sorted_architectures "$binary")" == "arm64 x86_64" ]] ||
    fail "$role helper is not universal"
  verify_signature "$helper_path" "$role helper" "$app_team"
  if [[ -n "$entitlements" ]]; then
    verify_exact_entitlements "$helper_path" "$APPLE_ROOT/$entitlements" \
      "$role helper"
  else
    verify_exact_entitlements "$helper_path" "" "$role helper"
  fi
  printf '%s\n' "${helper_path#"$APP/"}" >> "$expected_signing_paths"
  printf '%s\n' "${binary#"$APP/"}" >> "$allowed_code"

  set +e
  "$binary" --no-sandbox >/dev/null 2>&1
  rejection_status=$?
  set -e
  [[ "$rejection_status" == 64 ]] ||
    fail "$role helper did not reject --no-sandbox"
done < <(jq -c '.helperLayout.helpers[]' "$MANIFEST")

app_executable="$(plutil -extract CFBundleExecutable raw \
  "$APP/Contents/Info.plist")"
app_binary="$APP/Contents/MacOS/$app_executable"
[[ "$(sorted_architectures "$app_binary")" == "arm64 x86_64" ]] ||
  fail "Pilot executable is not universal"
printf '%s\n' "${app_binary#"$APP/"}" >> "$allowed_code"

actual_code="$work/actual-code.txt"
while IFS= read -r candidate; do
  if file "$candidate" | grep -q 'Mach-O'; then
    printf '%s\n' "${candidate#"$APP/"}"
  fi
done < <(find "$APP" -type f -print | LC_ALL=C sort) |
  LC_ALL=C sort -u > "$actual_code"
LC_ALL=C sort -u "$allowed_code" -o "$allowed_code"
cmp "$allowed_code" "$actual_code" >/dev/null ||
  fail "Pilot contains unexpected mutable Mach-O code"

signing_manifest="$APP/Contents/Resources/ChromiumRuntimeSigning.json"
[[ -f "$signing_manifest" ]] || fail "nested-signing manifest is missing"
legal_resources="$APP/Contents/Resources/Chromium/CEF"
while IFS= read -r key; do
  source_notice="$PACKAGE_ROOT/$(jq -r ".artifactLayout.$key" "$MANIFEST")"
  bundled_notice="$legal_resources/$(basename "$source_notice")"
  [[ -f "$source_notice" ]] ||
    fail "installed Chromium $key input is missing"
  [[ -f "$bundled_notice" ]] ||
    fail "bundled Chromium $key notice is missing"
  cmp "$source_notice" "$bundled_notice" >/dev/null ||
    fail "bundled Chromium $key notice differs from the pinned artifact"
done <<'NOTICE_KEYS'
license
credits
NOTICE_KEYS
jq -e --arg releaseID "$(jq -r '.releaseID' "$MANIFEST")" '
  .schemaVersion == 1 and
  .manifestReleaseID == $releaseID and
  .pilotSignedLastBy == "Xcode CodeSign action" and
  (all(.operations[];
    (.arguments | index("--deep")) == null and
    (.arguments | index("--options")) != null and
    (.arguments | index("runtime")) != null
  ))
' "$signing_manifest" >/dev/null ||
  fail "nested-signing metadata violates signing policy"
if [[ "$REQUIRE_NOTARIZATION" == 1 ]]; then
  jq -e 'all(.operations[]; (.arguments | index("--timestamp")) != null)' \
    "$signing_manifest" >/dev/null ||
    fail "nested-signing metadata lacks trusted timestamps"
fi
jq -r '.operations[].path' "$signing_manifest" > "$work/actual-signing-paths.txt"
cmp "$expected_signing_paths" "$work/actual-signing-paths.txt" >/dev/null ||
  fail "nested code was not signed in deterministic inside-out order"

# Strict outer verification after all nested checks proves Pilot's current
# resource seal was created after the current nested signatures.
codesign --verify --strict --verbose=2 "$APP"

if [[ "$REQUIRE_NOTARIZATION" == 1 ]]; then
  command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"
  command -v spctl >/dev/null 2>&1 || fail "spctl is required"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

printf 'Chromium runtime validation passed: %s\n' "$APP"
