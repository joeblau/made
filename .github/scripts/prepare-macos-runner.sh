#!/usr/bin/env bash
# Prepares a macOS job on the Blau enterprise's self-hosted Mac minis.
#
# Usage: .github/scripts/prepare-macos-runner.sh <xcode-major>
#
# The minis carry several Xcodes and run two runners per machine under one
# user, so every job:
#   - selects the newest installed Xcode with the requested major version
#     (DEVELOPER_DIR, which xcodebuild, xcrun, and xcode-select -p honor);
#   - gets its own TMPDIR under RUNNER_TEMP, which the runner empties after
#     each job, so concurrent jobs never share derived data;
#   - unless the job set BLAU_SOURCE_PACKAGES itself, keeps SwiftPM checkouts
#     in a per-runner directory that persists between jobs. SwiftPM records
#     absolute paths, so these can't round-trip through actions/cache between
#     runners with different workspaces.
set -euo pipefail

major="${1:?usage: prepare-macos-runner.sh <xcode-major>}"
[[ "$major" =~ ^[0-9]+$ ]] || { echo "::error::Xcode major must be a number, got '$major'"; exit 2; }
: "${GITHUB_ENV:?GITHUB_ENV is unset; run this from a GitHub Actions step}"
: "${RUNNER_TEMP:?RUNNER_TEMP is unset; run this from a GitHub Actions step}"

best=""
best_version=""
for app in /Applications/Xcode*.app; do
  [[ -d "$app/Contents/Developer" ]] || continue
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)" || continue
  [[ "${version%%.*}" == "$major" ]] || continue
  if [[ -z "$best" || "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -n 1)" == "$version" ]]; then
    best="$app"
    best_version="$version"
  fi
done

if [[ -z "$best" ]]; then
  echo "::error::No Xcode $major.x is installed in /Applications on $(hostname -s)."
  ls -d /Applications/Xcode*.app 2>/dev/null || echo "No Xcode apps found."
  exit 1
fi

job_tmp="$RUNNER_TEMP/tmp"
mkdir -p "$job_tmp"
{
  echo "DEVELOPER_DIR=$best/Contents/Developer"
  echo "TMPDIR=$job_tmp/"
  echo "BLAU_DERIVED_DATA=$job_tmp/blau-apple-ci"
  if [[ -z "${BLAU_SOURCE_PACKAGES:-}" ]]; then
    runner_id="${RUNNER_NAME:-$(hostname -s)}"
    echo "BLAU_SOURCE_PACKAGES=$HOME/Library/Caches/blau-ci/${runner_id//[^A-Za-z0-9._-]/_}/source-packages"
  fi
} >> "$GITHUB_ENV"
echo "Selected $best ($best_version) on $(hostname -s); job TMPDIR is $job_tmp"
