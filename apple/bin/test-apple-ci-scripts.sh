#!/usr/bin/env bash
# Exercise build-ci.sh/test.sh orchestration without invoking a compiler:
# shared per-platform derived data, pinned policy flags, and the guarantee that
# test-without-building only follows a successful build-for-testing of the same
# products in the same invocation. Also proves the committed-project check
# rejects every kind of XcodeGen drift, including never-committed new files.
set -euo pipefail
APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/apple-ci-scripts-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/apple/bin/lib" "$work/tools"
cp "$APPLE_ROOT/bin/build-ci.sh" "$APPLE_ROOT/bin/test.sh" "$APPLE_ROOT/bin/benchmark-ci.sh" "$work/apple/bin/"
cp "$APPLE_ROOT/bin/lib/xcodebuild-ci.sh" "$APPLE_ROOT/bin/lib/xcodebuild-benchmark.sh" "$work/apple/bin/lib/"
export CI_TEST_LOG="$work/calls"
export CI_TEST_ACTIONS="$work/actions"
export PATH="$work/tools:$PATH"
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"
unset BLAU_DERIVED_DATA BLAU_SOURCE_PACKAGES BLAU_CI_BENCHMARK_DIR BLAU_CI_BENCHMARK_XCODEBUILD
export IOS_SIMULATOR_UDID=00000000-0000-0000-0000-000000000000
export IPAD_SIMULATOR_UDID=11111111-1111-1111-1111-111111111111

cat > "$work/tools/xcodebuild" <<'TOOL'
#!/bin/bash
if [[ "${1:-}" == -version ]]; then
  printf 'Xcode 27.1\nBuild version 17B100\n'
  exit 0
fi
printf 'xcodebuild DISABLE_SWIFTLINT=%s %s\n' "${DISABLE_SWIFTLINT:-}" "$*" >> "$CI_TEST_LOG"
action="$1"
derived=""
scheme=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == -derivedDataPath ]] && derived="$2"
  [[ "$1" == -scheme ]] && scheme="$2"
  shift
done
printf '%s %s\n' "$action" "$scheme" >> "$CI_TEST_ACTIONS"
if [[ "$action" == "${CI_TEST_FAIL_ACTION:-}" ]]; then
  [[ "$action" == test ]] && mkdir -p "$derived/Logs/Test/failed.xcresult"
  exit 65
fi
if [[ "$action" == build-for-testing ]]; then
  mkdir -p "$derived/Build/Products"
  touch "$derived/Build/Products/${scheme}_iphonesimulator27.0-arm64-x86_64.xctestrun"
fi
if [[ "$action" != test-without-building ]]; then
  case "$scheme" in
    Pilot|PilotTests|Copilot|SharedTests|DroneTests) printf 'SwiftCompile normal arm64 %s.swift\n' "$scheme" ;;
  esac
  case "$scheme" in
    Pilot|DroneTools|Copilot|SharedTests|PlotterTests|DroneTests) printf 'CompileC %s.c\n' "$scheme" ;;
  esac
  [[ "$scheme" == Plotter ]] && printf 'SwiftCompile normal arm64 Plotter.swift\n'
fi
[[ "$scheme" == "${CI_TEST_SLEEP_SCHEME:-}" ]] && sleep 1
exit 0
TOOL
cat > "$work/tools/xcrun" <<'TOOL'
#!/bin/bash
printf 'xcrun %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/app-icon-tool.swift" <<'TOOL'
#!/bin/bash
printf 'icons %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/fetch-runner-model.sh" <<'TOOL'
#!/bin/bash
printf 'runner-model %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/fetch-mockup-models.sh" <<'TOOL'
#!/bin/bash
printf 'mockup-models %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/benchmark-annexb.sh" <<'TOOL'
#!/bin/bash
printf 'benchmark-annexb %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/check-annexb-parity.sh" <<'TOOL'
#!/bin/bash
printf 'annexb-parity %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/check-android-stream-live.sh" <<'TOOL'
#!/bin/bash
printf 'android-stream-live %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/check-cockpit-ui-boundary.py" <<'TOOL'
import os
from pathlib import Path
with Path(os.environ["CI_TEST_LOG"]).open("a") as log:
    log.write("cockpit-ui-boundary\n")
raise SystemExit(int(os.environ.get("CI_TEST_BOUNDARY_FAILURE", "0")))
TOOL
cat > "$work/apple/bin/test-drone-protocol.sh" <<'TOOL'
#!/bin/bash
printf 'drone-protocol\n' >> "$CI_TEST_LOG"
TOOL
for proof in drone-launchd drone-supervisor drone-revocation drone-connection drone-session \
  drone-jobs drone-job-tools drone-terminal drone-tools drone-worker; do
  cat > "$work/apple/bin/test-$proof.sh" <<'TOOL'
#!/bin/bash
printf '%s%s\n' "${0##*/}" "${*:+ $*}" >> "$CI_TEST_LOG"
TOOL
done
chmod +x "$work/tools/"* "$work/apple/bin/"*.sh "$work/apple/bin/app-icon-tool.swift"

fail() { printf 'apple CI script test: %s\n' "$*" >&2; exit 1; }
calls() { grep -c -- "$1" "$CI_TEST_LOG" || true; }
expect_calls() {
  local count
  count="$(calls "$2")"
  [[ "$count" == "$1" ]] || fail "expected $1 call(s) matching '$2', saw $count"
}
expect_actions() {
  local actual
  actual="$(cat "$CI_TEST_ACTIONS")"
  [[ "$actual" == "$1" ]] || fail "unexpected xcodebuild actions: $actual"
}
reset_log() {
  : > "$CI_TEST_LOG"
  : > "$CI_TEST_ACTIONS"
}

root="$TMPDIR/blau-apple-ci"
macos="-derivedDataPath $root/macos-debug "
simulator="-derivedDataPath $root/ios-simulator-debug "
generic="-destination generic/platform=iOS Simulator"

# The CI lane: build every application, then run every hosted suite.
reset_log
"$work/apple/bin/build-ci.sh"
"$work/apple/bin/test.sh" all
expect_calls 1 '^icons validate$'
expect_calls 1 '^benchmark-annexb --typecheck$'
expect_calls 1 '^annexb-parity --typecheck$'
expect_calls 1 '^android-stream-live --typecheck$'
expect_calls 1 '^runner-model verify$'
expect_calls 1 '^mockup-models verify$'
expect_calls 2 '^cockpit-ui-boundary$'
expect_calls 1 '^drone-protocol$'
expect_calls 1 '^test-drone-launchd.sh$'
expect_calls 1 '^test-drone-supervisor.sh$'
expect_calls 1 '^test-drone-revocation.sh$'
expect_calls 1 '^test-drone-connection.sh$'
expect_calls 1 '^test-drone-session.sh$'
expect_calls 1 '^test-drone-jobs.sh$'
expect_calls 1 '^test-drone-job-tools.sh$'
expect_calls 1 '^test-drone-terminal.sh$'
expect_calls 1 '^test-drone-tools.sh$'
expect_calls 1 '^test-drone-worker.sh$'
expect_calls 1 '^test-drone-worker.sh --tool-replay-authorization$'
expect_calls 10 '^xcodebuild '
expect_calls 10 '^xcodebuild DISABLE_SWIFTLINT=1 .* -quiet -project .*-configuration Debug .*-onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation .* CODE_SIGNING_ALLOWED=NO$'
expect_calls 0 'Chromium'
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build .*${macos}.*-scheme Pilot -destination platform=macOS,arch=$(uname -m) "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build .*${macos}.*-scheme DroneTools -destination platform=macOS,arch=$(uname -m) "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 test .*${macos}.*-scheme PilotTests -destination platform=macOS,arch=$(uname -m) "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 test .*${macos}.*-scheme DroneTests -destination platform=macOS,arch=$(uname -m) "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build .*${simulator}.*-scheme Copilot ${generic} "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build .*${simulator}.*-scheme Plotter ${generic} "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build-for-testing .*${simulator}.*-scheme SharedTests ${generic} "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 test-without-building .*${simulator}.*-scheme SharedTests -destination platform=iOS Simulator,id=$IOS_SIMULATOR_UDID "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build-for-testing .*${simulator}.*-scheme PlotterTests ${generic} "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 test-without-building .*${simulator}.*-scheme PlotterTests -destination platform=iOS Simulator,id=$IPAD_SIMULATOR_UDID "
expect_actions 'build Pilot
build DroneTools
build Copilot
build Plotter
test PilotTests
build-for-testing SharedTests
test-without-building SharedTests
build-for-testing PlotterTests
test-without-building PlotterTests
test DroneTests'
expect_calls 0 '^xcrun xcresulttool'

# Standalone suites still build what they need.
reset_log
"$work/apple/bin/test.sh" pilot
expect_calls 1 '^cockpit-ui-boundary$'
expect_calls 1 '^xcodebuild '
expect_calls 1 '^xcodebuild DISABLE_SWIFTLINT=1 test .*-scheme PilotTests '
reset_log
"$work/apple/bin/test.sh" shared
expect_calls 2 '^xcodebuild '
expect_actions 'build-for-testing SharedTests
test-without-building SharedTests'
[[ "$(find "$root/ios-simulator-debug/Build/Products" -name 'SharedTests_*.xctestrun' | wc -l | tr -d ' ')" == 1 ]] ||
  fail "expected one current SharedTests test-run description"
reset_log
"$work/apple/bin/test.sh" plotter
expect_calls 2 '^xcodebuild '
expect_actions 'build-for-testing PlotterTests
test-without-building PlotterTests'
[[ "$(find "$root/ios-simulator-debug/Build/Products" -name 'PlotterTests_*.xctestrun' | wc -l | tr -d ' ')" == 1 ]] ||
  fail "expected one current PlotterTests test-run description"

# A failed build-for-testing never falls through to test-without-building,
# and a stale description from an earlier run is not left to be executed.
reset_log
if CI_TEST_FAIL_ACTION=build-for-testing "$work/apple/bin/test.sh" shared; then
  fail "a failed build-for-testing must fail test.sh"
fi
expect_calls 0 ' test-without-building '
[[ -z "$(find "$root/ios-simulator-debug/Build/Products" -name 'SharedTests_*.xctestrun')" ]] ||
  fail "a stale SharedTests test-run description survived a failed build"

# Failure summaries cover this run's result bundles only.
mkdir -p "$root/macos-debug/Logs/Test/earlier.xcresult"
touch -t 200001010000 "$root/macos-debug/Logs/Test/earlier.xcresult"
reset_log
if CI_TEST_FAIL_ACTION="test" "$work/apple/bin/test.sh" pilot; then
  fail "a failed test run must fail test.sh"
fi
expect_calls 1 '^xcrun xcresulttool get test-results summary --path .*/failed.xcresult$'
expect_calls 0 'earlier.xcresult'
[[ -z "$(find "$root" -maxdepth 1 -name '.test-run.*')" ]] || fail "run marker was not removed"

# Unknown suites are rejected before any build.
reset_log
status=0
"$work/apple/bin/test.sh" bogus 2>/dev/null || status=$?
[[ "$status" == 2 ]] || fail "unknown suite exited $status, expected 2"
expect_calls 0 '^xcodebuild '

# A presentation regression fails before any application or hosted-test build.
reset_log
if CI_TEST_BOUNDARY_FAILURE=1 "$work/apple/bin/build-ci.sh"; then
  fail "a failed Cockpit boundary check must fail build-ci.sh"
fi
expect_calls 1 '^cockpit-ui-boundary$'
expect_calls 0 '^xcodebuild '
expect_calls 0 '^icons '
reset_log
if CI_TEST_BOUNDARY_FAILURE=1 "$work/apple/bin/test.sh" pilot; then
  fail "a failed Cockpit boundary check must fail the hosted Pilot test lane"
fi
expect_calls 1 '^cockpit-ui-boundary$'
expect_calls 0 '^xcodebuild '

# An explicit root relocates both scripts together.
reset_log
BLAU_DERIVED_DATA="$work/custom" "$work/apple/bin/build-ci.sh"
BLAU_DERIVED_DATA="$work/custom" "$work/apple/bin/test.sh" pilot
expect_calls 3 "-derivedDataPath $work/custom/macos-debug "

# The opt-in benchmark strips quiet logging, counts every platform's compile
# tasks, and retains the same build-for-testing/test-without-building order.
reset_log
evidence="$work/benchmark evidence"
(
  cd "$work"
  CI_TEST_SLEEP_SCHEME=PilotTests "$work/apple/bin/benchmark-ci.sh" "$evidence"
)
expect_calls 10 '^xcodebuild '
expect_calls 0 ' -quiet '
canonical_evidence="$(cd "$evidence" && pwd)"
[[ "$(grep -cF -- "-derivedDataPath $canonical_evidence/derived-data/" "$CI_TEST_LOG" || true)" == 10 ]] ||
  fail "benchmark did not isolate DerivedData: $(cat "$CI_TEST_LOG")"
expect_actions 'build Pilot
build DroneTools
build Copilot
build Plotter
test PilotTests
build-for-testing SharedTests
test-without-building SharedTests
build-for-testing PlotterTests
test-without-building PlotterTests
test DroneTests'
awk -F '\t' '
  $1 == "build" {
    build = ($2 == 6 && $3 == 4 && $4 == 5 && $5 == 9 && $7 == 0)
  }
  $1 == "test" {
    test = ($2 == 4 && $3 == 2 && $4 == 1 && $5 == 3 && $6 >= 1 && $7 == 0)
  }
  END { exit !(build && test) }
' "$evidence/totals.tsv" || fail "incorrect benchmark phase totals: $(cat "$evidence/totals.tsv")"
awk -F '\t' '
  $1 == "build" { build = ($3 == 0) }
  $1 == "test" { test = ($2 >= 1 && $3 == 0) }
  END { exit !(build && test) }
' "$evidence/steps.tsv" || fail "incorrect complete-step wall times: $(cat "$evidence/steps.tsv")"
awk -F '\t' '
  NR > 1 && $8 != 0 { exit 1 }
  $2 == "test-without-building" && ($3 == "SharedTests" || $3 == "PlotterTests") && $6 == 0 { mobile += 1 }
  END { exit mobile != 2 }
' "$evidence/commands.tsv" || fail "mobile test-without-building benchmark records are incorrect"
while IFS=$'\t' read -r phase _ _ _ _ _ _ status log; do
  [[ "$phase" == phase ]] && continue
  [[ -f "$evidence/$log" ]] || fail "missing non-quiet benchmark log: $log"
done < "$evidence/commands.tsv"
[[ "$(wc -l < "$evidence/commands.tsv" | tr -d ' ')" == 11 ]] || fail "expected ten benchmark command records"
status=0
(cd "$work" && "$work/apple/bin/benchmark-ci.sh" "$evidence") 2>/dev/null || status=$?
[[ "$status" == 2 ]] || fail "an existing evidence directory must reject a non-clean run"
expect_calls 10 '^xcodebuild '

# Benchmark logging preserves xcodebuild's failure status, so a failed mobile
# build cannot fall through to execution of test-without-building.
reset_log
failed_evidence="$work/failed-benchmark"
status=0
(cd "$work" && CI_TEST_FAIL_ACTION=build-for-testing "$work/apple/bin/benchmark-ci.sh" "$failed_evidence") >/dev/null 2>&1 || status=$?
[[ "$status" == 65 ]] || fail "benchmark hid a build-for-testing failure: $status"
expect_calls 0 ' test-without-building '
awk -F '\t' '
  $2 == "build-for-testing" && $3 == "SharedTests" && $8 == 65 { failed = 1 }
  END { exit !failed }
' "$failed_evidence/commands.tsv" || fail "failed benchmark command was not recorded"
awk -F '\t' '$1 == "build" { exit $7 == 1 ? 0 : 1 }' "$failed_evidence/totals.tsv" ||
  fail "failed benchmark phase total was not recorded"

# The committed-project check fails on any drift between apple/made.xcodeproj
# and what pinned XcodeGen generates, including a generated scheme that was
# never committed, which `git diff --exit-code` cannot see.
repo="$work/xcodegen-repo"
mkdir -p "$repo/apple/bin"
cp "$APPLE_ROOT/bin/install-xcodegen.sh" "$repo/apple/bin/"
cp "$APPLE_ROOT/../.gitignore" "$repo/.gitignore"
xcodegen_version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$APPLE_ROOT/bin/install-xcodegen.sh")"
[[ -n "$xcodegen_version" ]] || fail "could not read the pinned XcodeGen version"
xcodegen_cache="$work/xdg-cache"
mkdir -p "$xcodegen_cache/blau/xcodegen/$xcodegen_version/xcodegen/bin"
cat > "$xcodegen_cache/blau/xcodegen/$xcodegen_version/xcodegen/bin/xcodegen" <<'TOOL'
#!/bin/bash
set -euo pipefail
printf 'xcodegen %s\n' "$*" >> "$CI_TEST_LOG"
project=apple/made.xcodeproj
mkdir -p "$project/xcshareddata/xcschemes" "$project/project.xcworkspace" "$project/xcuserdata"
printf 'objects\n' > "$project/project.pbxproj"
printf 'workspace\n' > "$project/project.xcworkspace/contents.xcworkspacedata"
printf 'Pilot\n' > "$project/xcshareddata/xcschemes/Pilot.xcscheme"
printf 'Copilot\n' > "$project/xcshareddata/xcschemes/Copilot.xcscheme"
# Per-user state is gitignored and never counts as drift.
printf 'local\n' > "$project/xcuserdata/state.plist"
case "${CI_TEST_XCODEGEN_DRIFT:-}" in
  new-scheme) printf 'Wingman\n' > "$project/xcshareddata/xcschemes/Wingman.xcscheme" ;;
  modified) printf 'changed\n' >> "$project/project.pbxproj" ;;
  removed-scheme) rm "$project/xcshareddata/xcschemes/Copilot.xcscheme" ;;
  '') ;;
  *) exit 64 ;;
esac
TOOL
chmod +x "$xcodegen_cache/blau/xcodegen/$xcodegen_version/xcodegen/bin/xcodegen"
repo_git() {
  git -C "$repo" -c user.name=ci-test -c user.email=ci-test@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
check_committed() {
  (
    cd "$repo/apple"
    CI_TEST_XCODEGEN_DRIFT="${1:-}" XDG_CACHE_HOME="$xcodegen_cache" \
      bin/install-xcodegen.sh check-committed
  ) >/dev/null 2>&1
}
repo_git init -q
(cd "$repo" && CI_TEST_XCODEGEN_DRIFT='' "$xcodegen_cache/blau/xcodegen/$xcodegen_version/xcodegen/bin/xcodegen")
repo_git add -A
repo_git commit -qm 'generated project'
[[ -z "$(repo_git ls-files -- apple/made.xcodeproj/xcuserdata)" ]] ||
  fail "per-user Xcode state was committed; .gitignore no longer excludes it"
reset_log
check_committed || fail "a committed project that matches XcodeGen must pass"
expect_calls 1 '^xcodegen generate --spec apple/project.yml --project apple$'
for drift in new-scheme modified removed-scheme; do
  reset_log
  if check_committed "$drift"; then
    fail "the committed-project check accepted XcodeGen drift: $drift"
  fi
  expect_calls 1 '^xcodegen generate --spec apple/project.yml --project apple$'
  if [[ "$drift" == new-scheme ]]; then
    repo_git diff --quiet --exit-code -- apple/made.xcodeproj ||
      fail "expected the untracked scheme to be invisible to git diff"
  fi
  repo_git checkout -q -- apple/made.xcodeproj
  repo_git clean -qf -- apple/made.xcodeproj
  [[ -z "$(repo_git status --porcelain -- apple/made.xcodeproj)" ]] ||
    fail "could not restore the committed project after $drift"
done
status=0
(cd "$repo/apple" && XDG_CACHE_HOME="$xcodegen_cache" bin/install-xcodegen.sh check-committed extra) \
  >/dev/null 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "check-committed with extra arguments exited $status, expected 2"

# Every workflow step that regenerates the project to verify it uses the check
# above, never the tracked-files-only `git diff`.
workflows="$APPLE_ROOT/../.github/workflows"
if grep -n 'git diff --exit-code -- apple/made.xcodeproj' "$workflows"/*.yml; then
  fail "a workflow verifies apple/made.xcodeproj with git diff, which ignores new files"
fi
[[ "$(grep -c 'apple/bin/install-xcodegen.sh check-committed$' "$workflows/ci.yml")" == 1 ]] ||
  fail "ci.yml must verify the committed Xcode project with check-committed"
[[ "$(grep -c 'apple/bin/install-xcodegen.sh check-committed$' "$workflows/apple-release.yml")" == 2 ]] ||
  fail "both apple-release.yml project steps must verify with check-committed"

printf 'Apple CI script orchestration checks passed.\n'
