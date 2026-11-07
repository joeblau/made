#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_ROOT/made.xcodeproj"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drone-launchd-smoke.XXXXXX")"
DERIVED_DATA="$BUILD_DIR/DerivedData"
PRODUCTS="$DERIVED_DATA/Build/Products/Debug"
ROOT="$BUILD_DIR/worker"
LABEL="app.blau.drone.smoke.$$"
DOMAIN="gui/$(id -u)"
SECRET="pairing-material-that-must-never-be-printed"
MANUAL_ROOT="$(mktemp -d /tmp/drone-stop.XXXXXX)"
manual_pid=""

cleanup() {
  if [[ -n "$manual_pid" ]]; then
    kill -KILL "$manual_pid" >/dev/null 2>&1 || true
    wait "$manual_pid" 2>/dev/null || true
  fi
  rm -rf "$MANUAL_ROOT"
  /bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

DISABLE_SWIFTLINT=1 xcodebuild build -quiet \
  -project "$PROJECT" \
  -scheme DroneTools \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "${TMPDIR:-/tmp}/blau-source-packages" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO

# Direct shutdown must complete without launchd's eventual SIGKILL fallback.
/usr/bin/env -u BLAU_DRONE_WORKSPACE -u BLAU_DRONE_PERMISSIONS \
  BLAU_DRONE_ROOT="$MANUAL_ROOT" "$PRODUCTS/droned" &
manual_pid=$!
for _ in {1..100}; do
  [[ -S "$MANUAL_ROOT/run/control.sock" ]] && break
  sleep 0.02
done
[[ -S "$MANUAL_ROOT/run/control.sock" ]]
kill -TERM "$manual_pid"
for _ in {1..100}; do
  if ! kill -0 "$manual_pid" 2>/dev/null; then break; fi
  sleep 0.02
done
if kill -0 "$manual_pid" 2>/dev/null; then
  echo "droned did not exit after graceful SIGTERM" >&2
  exit 1
fi
wait "$manual_pid"
manual_pid=""
[[ ! -e "$MANUAL_ROOT/run/control.sock" ]]

export BLAU_DRONE_ROOT="$ROOT"
export BLAU_DRONE_LABEL="$LABEL"
export BLAU_DRONE_LOG_LIMIT=1024
DRONE="$PRODUCTS/drone"

status_output() {
  "$DRONE" status 2>/dev/null || true
}

wait_for_state() {
  local expected="$1"
  local output=""
  for _ in {1..150}; do
    output="$(status_output)"
    if [[ "$output" == *"state=$expected"* ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep 0.1
  done
  printf 'Timed out waiting for state=%s; last status:\n%s\n' "$expected" "$output" >&2
  return 1
}

worker_pid() {
  status_output | awk -F= '$1 == "pid" { print $2 }'
}

[[ "$("$DRONE" --version)" == *"protocol 1; execution disabled"* ]]
"$DRONE" install
wait_for_state listening >/dev/null
first_pid="$(worker_pid)"
[[ -n "$first_pid" ]]
kill -0 "$first_pid"

mkdir -p "$ROOT/state/pairings"
printf '%s' "$SECRET" > "$ROOT/state/pairings/test-peer"
chmod 600 "$ROOT/state/pairings/test-peer"
paired_status="$(wait_for_state paired)"
[[ "$paired_status" != *"$SECRET"* ]]
[[ "$paired_status" != *"test-peer"* ]]
"$DRONE" doctor >/dev/null

"$DRONE" install
wait_for_state paired >/dev/null
"$DRONE" install
wait_for_state paired >/dev/null
[[ "$(< "$ROOT/state/pairings/test-peer")" == "$SECRET" ]]
[[ "$(stat -f %Lp "$ROOT/state/pairings/test-peer")" == 600 ]]

reinstall_pid="$(worker_pid)"
"$DRONE" restart
for _ in {1..150}; do
  restarted_pid="$(worker_pid)"
  [[ -n "$restarted_pid" && "$restarted_pid" != "$reinstall_pid" ]] && break
  sleep 0.1
done
[[ -n "$restarted_pid" && "$restarted_pid" != "$reinstall_pid" ]]

kill -KILL "$restarted_pid"
recovered_pid=""
for _ in {1..200}; do
  candidate="$(worker_pid)"
  if [[ -n "$candidate" && "$candidate" != "$restarted_pid" ]]; then
    recovered_pid="$candidate"
    break
  fi
  sleep 0.1
done
[[ -n "$recovered_pid" ]]
kill -0 "$recovered_pid"
wait_for_state paired >/dev/null

"$DRONE" stop
wait_for_state stopped >/dev/null
if kill -0 "$recovered_pid" 2>/dev/null; then
  echo "droned remained after stop" >&2
  exit 1
fi
[[ ! -e "$ROOT/run/control.sock" ]]

"$DRONE" start
wait_for_state paired >/dev/null
running_pid="$(worker_pid)"
"$DRONE" doctor >/dev/null
log_bytes=0
for log_file in "$ROOT"/logs/*; do
  [[ -f "$log_file" ]] || continue
  size="$(stat -f %z "$log_file")"
  (( log_bytes += size ))
done
(( log_bytes <= 2048 ))

"$DRONE" uninstall
wait_for_state stopped >/dev/null
if kill -0 "$running_pid" 2>/dev/null; then
  echo "droned remained after uninstall" >&2
  exit 1
fi
[[ ! -e "$ROOT/LaunchAgents/$LABEL.plist" ]]
[[ ! -e "$ROOT/current" ]]
[[ ! -e "$ROOT/releases" ]]
[[ "$(< "$ROOT/state/pairings/test-peer")" == "$SECRET" ]]
[[ -f "$ROOT/logs/droned.log" || -f "$ROOT/logs/droned.log.1" ]]
if /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "launchd job remained after uninstall" >&2
  exit 1
fi

printf 'Drone launchd smoke test passed: repeated install, lifecycle, crash recovery, state preservation, and log bounds.\n'
