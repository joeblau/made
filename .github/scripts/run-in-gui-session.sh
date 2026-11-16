#!/usr/bin/env bash
# Runs a command inside the logged-in user's GUI (Aqua) launchd session.
#
# Usage: .github/scripts/run-in-gui-session.sh <command> [args...]
#
# The Blau enterprise's Mac mini runners are LaunchDaemons: they run as the
# console user but in launchd's System session, where XCTest cannot reach
# testmanagerd ("Failed to establish communication with the test runner").
# The same user is logged in at the console, and launchd lets a user submit
# jobs to their own gui/<uid> domain without sudo. This script submits the
# command there as a one-shot job with the caller's environment and working
# directory, streams its output, and exits with its status.
#
# When the caller already runs in an Aqua session (GitHub-hosted runners, a
# developer's terminal) the command is exec'd directly.
set -euo pipefail

[[ $# -gt 0 ]] || { echo "usage: run-in-gui-session.sh <command> [args...]" >&2; exit 2; }

if [[ "$(launchctl managername 2>/dev/null)" == "Aqua" ]]; then
  exec "$@"
fi

uid="$(id -u)"
domain="gui/$uid"
if ! launchctl print "$domain" >/dev/null 2>&1; then
  echo "::error::$(id -un) has no GUI login session on $(hostname -s); XCTest needs the runner user logged in at the console (enable auto-login)." >&2
  exit 1
fi

umask 077
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gui-session.XXXXXX")"
label="app.blau.ci.gui-session.$$.$RANDOM"
plist="$work/$label.plist"
log="$work/output.log"
status_file="$work/status"
tail_pid=""

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  [[ -z "$tail_pid" ]] || kill "$tail_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The job re-creates this shell's exported environment (the snapshot can hold
# secrets, hence the 0700 directory removed on exit) and stops itself if this
# script dies without cleaning up, e.g. when the runner is killed.
export -p > "$work/env.sh"
# shellcheck disable=SC2016  # the job script expands these, not this shell
{
  echo '#!/bin/bash'
  printf 'source %q\n' "$work/env.sh"
  printf 'cd %q || exit 1\n' "$PWD"
  printf '( while kill -0 %q 2>/dev/null; do sleep 5; done; kill -TERM 0 ) &\n' "$$"
  echo 'watchdog=$!'
  printf '%q ' "$@"
  echo
  echo 'status=$?'
  echo '{ kill "$watchdog"; wait "$watchdog"; } 2>/dev/null'
  printf 'echo "$status" > %q\n' "$status_file.tmp"
  printf 'mv %q %q\n' "$status_file.tmp" "$status_file"
} > "$work/job.sh"

: > "$log"
/usr/libexec/PlistBuddy \
  -c "Add :Label string $label" \
  -c "Add :ProgramArguments array" \
  -c "Add :ProgramArguments:0 string /bin/bash" \
  -c "Add :ProgramArguments:1 string $work/job.sh" \
  -c "Add :StandardOutPath string $log" \
  -c "Add :StandardErrorPath string $log" \
  -c "Add :RunAtLoad bool true" \
  -c "Add :ProcessType string Interactive" \
  "$plist" >/dev/null

launchctl bootstrap "$domain" "$plist"
tail -n +1 -f "$log" &
tail_pid=$!

while [[ ! -f "$status_file" ]]; do
  if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
    # The job is gone; give its last writes a moment to land.
    sleep 1
    [[ -f "$status_file" ]] && break
    echo "::error::The GUI-session job exited without reporting a status." >&2
    exit 1
  fi
  sleep 1
done

# Let tail flush the final lines before it is stopped.
sleep 1
exit "$(cat "$status_file")"
