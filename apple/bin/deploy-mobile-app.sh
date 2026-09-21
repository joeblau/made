#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_ROOT/made.xcodeproj"
DERIVED_ROOT="${BLAU_DEVICE_DERIVED_DATA:-${TMPDIR:-/tmp}/blau-device-builds}"
PACKAGES="${BLAU_SOURCE_PACKAGES:-${TMPDIR:-/tmp}/blau-source-packages}"

fail() {
  printf 'Mobile deployment error: %s\n' "$*" >&2
  exit 1
}

usage() {
  local status="${1:-2}"
  cat >&2 <<'EOF'
Usage: deploy-mobile-app.sh <walkie|kneeboard> [options]

Builds, installs, and launches a development-signed app on a physical device.

Options:
  --device <name-or-id>  Select a device when more than one is available.
  --skip-build           Install the existing Debug device build.
  --no-launch            Install the app without launching it.
  -h, --help             Show this help.

Examples:
  bun walkie
  bun kneeboard --device "My iPad"
EOF
  exit "$status"
}

[[ $# -ge 1 ]] || usage
app="$1"
shift

case "$app" in
  walkie)
    display_name="Walkie"
    scheme="Copilot"
    product="Copilot"
    bundle_id="app.blau.copilot"
    device_type="iPhone"
    ;;
  kneeboard)
    display_name="Kneeboard"
    scheme="Plotter"
    product="Plotter"
    bundle_id="app.blau.plotter"
    device_type="iPad"
    ;;
  *) usage ;;
esac

requested_device="${BLAU_IOS_DEVICE:-}"
skip_build=0
launch=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || usage
      requested_device="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --no-launch)
      launch=0
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *) usage ;;
  esac
done

for tool in jq xcodebuild xcrun; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

device_list="$(mktemp "${TMPDIR:-/tmp}/blau-devices.XXXXXX")"
cleanup() {
  rm -f "$device_list"
}
trap cleanup EXIT

# CoreDevice remembers disconnected hardware and lists simulators alongside real
# devices. Filter before choosing so a stale pairing or similarly named
# simulator can never become an install target.
# A reachable device reports a composite state such as "available (paired)",
# so match the prefix; "State = 'available'" never matches anything.
device_filter="Platform = 'iOS' AND Reality = 'physical' AND State BEGINSWITH 'available' AND Model BEGINSWITH '$device_type'"
if ! xcrun devicectl list devices \
  --filter "$device_filter" \
  --quiet \
  --timeout 15 \
  --json-output "$device_list"; then
  fail "could not query available $device_type devices"
fi
jq -e '.result.devices | type == "array"' "$device_list" >/dev/null \
  || fail "CoreDevice returned an invalid device list"

device_names=()
device_ids=()
device_core_ids=()
while IFS=$'\t' read -r name device_id core_id; do
  [[ -n "$device_id" ]] || continue
  device_names+=("$name")
  device_ids+=("$device_id")
  device_core_ids+=("$core_id")
done < <(
  jq -r '.result.devices[]? | [
    (.properties.state.name // .deviceProperties.name // "Unnamed device"),
    (.properties.hardware.udid // .hardwareProperties.udid // .identifier),
    .identifier
  ] | @tsv' "$device_list"
)

device_count="${#device_ids[@]}"
if [[ "$device_count" -eq 0 ]]; then
  fail "no available physical $device_type found; connect, unlock, and enable Developer Mode on the device"
fi

selected_index=""
if [[ -n "$requested_device" ]]; then
  for ((index = 0; index < device_count; index++)); do
    if [[ "$requested_device" == "${device_names[$index]}" \
      || "$requested_device" == "${device_ids[$index]}" \
      || "$requested_device" == "${device_core_ids[$index]}" ]]; then
      selected_index="$index"
      break
    fi
  done
  [[ -n "$selected_index" ]] \
    || fail "the requested $device_type is not available: $requested_device"
elif [[ "$device_count" -eq 1 ]]; then
  selected_index=0
else
  printf 'More than one %s is available:\n' "$device_type" >&2
  for ((index = 0; index < device_count; index++)); do
    printf '  %s (%s)\n' "${device_names[$index]}" "${device_ids[$index]}" >&2
  done
  fail "choose one with --device <name-or-UDID>"
fi

device_name="${device_names[$selected_index]}"
device_id="${device_ids[$selected_index]}"
derived_data="$DERIVED_ROOT/$scheme"
app_path="$derived_data/Build/Products/Debug-iphoneos/$product.app"

if [[ "$skip_build" -eq 0 ]]; then
  printf 'Building %s for %s\n' "$display_name" "$device_name"
  "$APPLE_ROOT/bin/install-xcodegen.sh" generate \
    --spec "$APPLE_ROOT/project.yml" \
    --project "$APPLE_ROOT"

  DISABLE_SWIFTLINT=1 xcodebuild build \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "platform=iOS,id=$device_id" \
    -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    CODE_SIGN_STYLE=Automatic
fi

[[ -d "$app_path" ]] \
  || fail "no device build at $app_path; run again without --skip-build"

printf 'Installing %s on %s\n' "$display_name" "$device_name"
xcrun devicectl device install app \
  --device "$device_id" \
  --timeout 120 \
  "$app_path"

if [[ "$launch" -eq 1 ]]; then
  printf 'Launching %s on %s\n' "$display_name" "$device_name"
  xcrun devicectl device process launch \
    --device "$device_id" \
    --terminate-existing \
    --timeout 30 \
    "$bundle_id"
fi

printf 'Deployed %s to %s\n' "$display_name" "$device_name"
