#!/usr/bin/env bash
# Exercise build-ci.sh/test.sh orchestration without invoking a compiler:
# shared per-platform derived data, pinned policy flags, and the guarantee that
# test-without-building only follows a successful build-for-testing of the same
# products in the same invocation.
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

# Every released Apple commit has passed lint and unit tests on its own CI run:
# ci.yml runs every gate for each main commit, and apple-release.yml refuses a
# tag until such a run of that exact commit has passed both Apple gates.
workflows="$APPLE_ROOT/../.github/workflows"
command -v jq >/dev/null || fail "jq is required to exercise the release CI gate"
python3 - "$workflows/ci.yml" <<'PY' || fail "ci.yml does not run every gate for each main commit"
import re, sys
text = open(sys.argv[1]).read()
on = re.search(r"^on:\n((?:[ \t]+.*\n|\n)*)", text, re.M).group(1)
assert re.search(r"^  push:\n    branches:\n      - main\n", on, re.M), "push to main"
assert "cancel-in-progress: ${{ github.event_name == 'pull_request' }}" in text, "main runs cancelled"
assert "group: ci-${{ github.event.pull_request.number || github.sha }}" in text, "per-commit group"
assert re.search(r"id: filter-all\n\s+if: \$\{\{ github.event_name != 'pull_request' \}\}", text), "filter-all"
assert re.search(r"id: filter\n\s+if: \$\{\{ github.event_name == 'pull_request' \}\}", text), "paths filter"
PY
gate="$work/release-ci-gate.sh"
python3 - "$workflows/apple-release.yml" 'Require passing Apple CI for the release commit' > "$gate" <<'PY' ||
import sys
lines = open(sys.argv[1]).read().split("\n")
start = next(i for i, line in enumerate(lines) if line.strip() == "- name: " + sys.argv[2])
run = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |")
indent = len(lines[run]) - len(lines[run].lstrip())
body = []
for line in lines[run + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) <= indent:
        break
    body.append(line)
width = min(len(l) - len(l.lstrip()) for l in body if l.strip())
print("\n".join(l[width:] for l in body))
PY
  fail "apple-release.yml has no release-commit CI gate"
release_repo="$work/release-repo"
git init -q "$release_repo"
git -C "$release_repo" -c user.name=ci -c user.email=ci@example.invalid -c commit.gpgsign=false \
  commit -q --allow-empty -m release
git -C "$release_repo" -c tag.gpgsign=false tag v1.2.3
release_sha="$(git -C "$release_repo" rev-parse HEAD)"
cat > "$work/tools/gh" <<'TOOL'
#!/bin/bash
count="$(cat "$GATE_DIR/calls" 2>/dev/null || echo 0)"
echo $((count + 1)) > "$GATE_DIR/calls"
case "$2" in
  */actions/workflows/ci.yml/runs\?head_sha=*)
    if [[ -f "$GATE_DIR/runs.pending" && ! -f "$GATE_DIR/seen" ]]; then
      touch "$GATE_DIR/seen"
      cat "$GATE_DIR/runs.pending"
    else
      cat "$GATE_DIR/runs"
    fi ;;
  */actions/runs/*/jobs\?filter=latest*) cat "$GATE_DIR/jobs" ;;
  *) exit 1 ;;
esac
TOOL
chmod +x "$work/tools/gh"
run_json() { # event status conclusion [head_sha]
  printf '{"id":4242,"event":"%s","status":"%s","conclusion":%s,"head_sha":"%s","head_repository":{"full_name":"example/repo"}}' \
    "$1" "$2" "$3" "${4:-$release_sha}"
}
jobs_json() { # apple-lint conclusion, apple-build-test conclusion
  printf '{"jobs":[{"name":"apple-lint","conclusion":"%s"},{"name":"apple-build-test","conclusion":"%s"},{"name":"complete","conclusion":"success"}]}' "$1" "$2"
}
run_gate() { # runs-json jobs-json [pending-runs-json]
  local dir
  dir="$(mktemp -d "$work/gate.XXXXXX")"
  printf '{"workflow_runs":[%s]}' "$1" > "$dir/runs"
  printf '%s' "$2" > "$dir/jobs"
  [[ -z "${3:-}" ]] || printf '{"workflow_runs":[%s]}' "$3" > "$dir/runs.pending"
  (
    cd "$release_repo"
    GATE_DIR="$dir" GITHUB_REPOSITORY=example/repo RELEASE_TAG=v1.2.3 \
      RELEASE_CI_WAIT_SECONDS="${GATE_WAIT:-0}" RELEASE_CI_GRACE_SECONDS=0 RELEASE_CI_POLL_SECONDS=0 \
      bash -eo pipefail "$gate"
  ) >/dev/null 2>&1
}
run_gate "$(run_json push completed '"success"')" "$(jobs_json success success)" ||
  fail "a passing main CI run of the release commit must satisfy the gate"
run_gate "$(run_json workflow_dispatch completed '"success"')" "$(jobs_json success success)" ||
  fail "a passing manual CI run of the release commit must satisfy the gate"
if run_gate "$(run_json pull_request completed '"success"')" "$(jobs_json success success)"; then
  fail "a pull-request merge preview must not stand in for the release commit"
fi
if run_gate "$(run_json push completed '"success"' 0000000000000000000000000000000000000000)" "$(jobs_json success success)"; then
  fail "a CI run of another commit must not satisfy the gate"
fi
if run_gate "" "$(jobs_json success success)"; then
  fail "a release commit with no CI run must be refused"
fi
if run_gate "$(run_json push completed '"failure"')" "$(jobs_json success failure)"; then
  fail "a failed CI run of the release commit must be refused"
fi
if run_gate "$(run_json push completed '"success"')" "$(jobs_json success skipped)"; then
  fail "a CI run that skipped the unit tests must be refused"
fi
if run_gate "$(run_json push completed '"success"')" "$(jobs_json skipped success)"; then
  fail "a CI run that skipped Swift lint must be refused"
fi
GATE_WAIT=30 run_gate "$(run_json push completed '"success"')" "$(jobs_json success success)" \
  "$(run_json push in_progress null)" ||
  fail "the gate must wait for an in-progress CI run of the release commit"
rm -f "$work/tools/gh"

printf 'Apple CI script orchestration checks passed.\n'
