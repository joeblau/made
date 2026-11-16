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
#   - puts a pinned, SHA-256 verified CMake (the CEF wrapper build needs it)
#     on PATH, cached once per machine;
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

# CMake: the minis don't ship it. Both runners on a mini share the cache, so
# extract privately and rename into place; a runner that loses the race uses
# the winner's identical copy.
CMAKE_VERSION="4.4.5"
CMAKE_SHA256="679e77a96b9ef9484cc6c1445255fc4f84206b48a65420efbedf16bdab55fbff"
cmake_root="$HOME/Library/Caches/blau-ci/cmake/$CMAKE_VERSION"
if [[ ! -x "$cmake_root/CMake.app/Contents/bin/cmake" ]]; then
  staging="$(mktemp -d "$RUNNER_TEMP/cmake.XXXXXX")"
  archive="$staging/cmake.tar.gz"
  curl --fail --silent --show-error --location --retry 3 --output "$archive" \
    "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-macos-universal.tar.gz"
  echo "${CMAKE_SHA256}  ${archive}" | shasum -a 256 --check --strict
  tar -xzf "$archive" -C "$staging"
  mkdir -p "$(dirname "$cmake_root")"
  mv "$staging/cmake-${CMAKE_VERSION}-macos-universal" "$cmake_root" 2>/dev/null || true
  rm -rf "$staging"
fi
"$cmake_root/CMake.app/Contents/bin/cmake" --version | sed -n '1p'
echo "$cmake_root/CMake.app/Contents/bin" >> "$GITHUB_PATH"

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
