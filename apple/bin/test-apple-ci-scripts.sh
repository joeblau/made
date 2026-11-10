#!/usr/bin/env bash
# Exercise build-ci.sh/test.sh orchestration without invoking a compiler:
# shared per-platform derived data, pinned policy flags, and the guarantee that
# test-without-building only follows a successful build-for-testing of the same
# products in the same invocation. Also exercises the Apple Release ordering
# guard that keeps GitHub's latest release on the highest version and build,
# and proves the committed-project check rejects every kind of XcodeGen drift,
# including never-committed new files.
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

# Every Apple release job builds exactly the commit release-metadata validated
# (#423): release-metadata exports that SHA, every other checkout pins it and
# is immediately followed by a HEAD check, and publish re-checks the tag.
release_workflow="$APPLE_ROOT/../.github/workflows/apple-release.yml"
# shellcheck disable=SC2016 # a literal GitHub Actions expression
validated_ref='${{ needs.release-metadata.outputs.commit }}'
verify_step='Verify the validated release commit'
awk -v ref="$validated_ref" -v verify="$verify_step" '
  function bad(message) { printf "%s\n", message; failed = 1 }
  function close_job() {
    if (job == "release-metadata") {
      if (!exports_commit) bad("release-metadata does not output the validated commit")
    } else if (job != "" && checkouts > 0 && verified < checkouts) {
      bad(job ": checkout is not immediately followed by \"" verify "\"")
    }
  }
  /^jobs:$/ { in_jobs = 1; next }
  in_jobs && /^  [A-Za-z0-9_-]+:$/ {
    close_job()
    job = $1; sub(/:$/, "", job)
    checkouts = 0; verified = 0; exports_commit = 0; in_checkout = 0
    next
  }
  job == "release-metadata" && $0 == "      commit: ${{ steps.release.outputs.commit }}" { exports_commit = 1 }
  /^      - / {
    if (in_checkout && job != "release-metadata" && checkout_ref != ref)
      bad(job ": checkout ref is \"" checkout_ref "\", not the validated commit")
    if (in_checkout && job != "release-metadata" && $0 == "      - name: " verify) verified++
    in_checkout = ($0 ~ /uses: actions\/checkout@/)
    if (in_checkout) { checkouts++; checkout_ref = "" }
    next
  }
  in_checkout && /^          ref: / { checkout_ref = $0; sub(/^          ref: /, "", checkout_ref) }
  END {
    close_job()
    if (!in_jobs) bad("no jobs found")
    exit failed
  }
' "$release_workflow" || fail "release jobs do not all build the validated release commit"
grep -Fq "printf 'commit=%s\\n' \"\$release_commit\" >> \"\$GITHUB_OUTPUT\"" "$release_workflow" ||
  fail "release-metadata does not export the commit it validated"
# shellcheck disable=SC2016 # literal workflow shell text
grep -Fq '"$GITHUB_SHA^{commit}")" ]]; then' "$release_workflow" ||
  fail "release-metadata accepts a tag moved after the push that triggered it"
awk '
  /- name: Verify the release tag still names the validated commit$/ { recheck = NR }
  /- name: Publish the tagged release$/ { publish = NR }
  END { exit !(recheck && publish && recheck < publish) }
' "$release_workflow" || fail "publish does not re-check the release tag before creating the release"

# Extract every run body of the step named $1 into $2.1, $2.2, ... and print
# how many there were, so each embedded copy is executed exactly as written.
extract_run_bodies() {
  awk -v name="      - name: $1" -v prefix="$2" '
    function finish() { if (out != "") close(out); body = 0; out = "" }
    $0 == name { finish(); step = 1; next }
    step && /^        run: \|$/ { step = 0; body = 1; out = prefix "." ++count; printf "" > out; next }
    body && /^          / { sub(/^          /, ""); print > out; next }
    body && /^$/ { print "" > out; next }
    body { finish() }
    /^      - / { step = 0 }
    END { finish(); print count + 0 }
  ' "$release_workflow"
}

# Execute every copy of the HEAD check exactly as the workflow embeds it: one
# per checkout outside release-metadata, each rejecting anything but the
# validated commit.
checkouts="$(awk '
  /^jobs:$/ { in_jobs = 1; next }
  in_jobs && /^  [A-Za-z0-9_-]+:$/ { job = $1; sub(/:$/, "", job); next }
  job != "release-metadata" && /^      - uses: actions\/checkout@/ { count++ }
  END { print count + 0 }
' "$release_workflow")"
verify_script="$work/verify-release-commit.sh"
verify_copies="$(extract_run_bodies "$verify_step" "$verify_script")"
[[ "$checkouts" -gt 0 ]] || fail "found no release checkouts to verify"
[[ "$verify_copies" == "$checkouts" ]] ||
  fail "found $verify_copies release commit check(s) for $checkouts release checkout(s)"
release_repo="$work/release-repo"
git init -q "$release_repo"
git -C "$release_repo" -c user.name=ci -c user.email=ci@example.invalid -c commit.gpgsign=false \
  commit -q --allow-empty -m validated
validated_commit="$(git -C "$release_repo" rev-parse HEAD)"
git -C "$release_repo" -c user.name=ci -c user.email=ci@example.invalid -c commit.gpgsign=false \
  commit -q --allow-empty -m moved
moved_commit="$(git -C "$release_repo" rev-parse HEAD)"
for ((copy = 1; copy <= verify_copies; copy++)); do
  script="$verify_script.$copy"
  [[ -s "$script" ]] || fail "release commit check $copy is empty"
  git -C "$release_repo" checkout -q --detach "$moved_commit"
  (cd "$release_repo" && RELEASE_COMMIT="$validated_commit" bash "$script") 2>/dev/null &&
    fail "release commit check $copy accepted a checkout of a different commit"
  (cd "$release_repo" && RELEASE_COMMIT=v1.2.3 bash "$script") 2>/dev/null &&
    fail "release commit check $copy accepted a non-SHA release commit"
  (cd "$release_repo" && RELEASE_COMMIT='' bash "$script") 2>/dev/null &&
    fail "release commit check $copy accepted an empty release commit"
  git -C "$release_repo" checkout -q --detach "$validated_commit"
  (cd "$release_repo" && RELEASE_COMMIT="$validated_commit" bash "$script") ||
    fail "release commit check $copy rejected the validated commit"
done

# Execute publish's tag re-check exactly as embedded, against a stub gh whose
# canned "type sha" answers model lightweight, annotated, and chained tags.
recheck_script="$work/verify-release-tag.sh"
recheck_copies="$(extract_run_bodies 'Verify the release tag still names the validated commit' "$recheck_script")"
[[ "$recheck_copies" == 1 ]] || fail "expected one release tag re-check, found $recheck_copies"
recheck_script="$recheck_script.1"
mkdir -p "$work/gh-stub" "$work/gh-tags"
cat > "$work/gh-stub/gh" <<'TOOL'
#!/bin/bash
[[ "$1" == api ]] || exit 2
case "$2" in
  "repos/$GITHUB_REPOSITORY/git/ref/tags/$RELEASE_TAG") printf '%s\n' "$GH_STUB_REF" ;;
  "repos/$GITHUB_REPOSITORY/git/tags/"*) cat "$GH_STUB_TAGS/${2##*/}" ;;
  *) exit 2 ;;
esac
TOOL
chmod +x "$work/gh-stub/gh"
tag_object() { printf '%040d' "$1"; }
# Tag objects 1..5 form a chain ending at the validated commit; object 9
# peels to the moved commit.
for level in 1 2 3 4; do
  printf 'tag %s\n' "$(tag_object $((level + 1)))" > "$work/gh-tags/$(tag_object "$level")"
done
printf 'commit %s\n' "$validated_commit" > "$work/gh-tags/$(tag_object 5)"
printf 'commit %s\n' "$moved_commit" > "$work/gh-tags/$(tag_object 9)"
run_recheck() {
  PATH="$work/gh-stub:$PATH" GH_STUB_REF="$1" GH_STUB_TAGS="$work/gh-tags" \
    GITHUB_REPOSITORY=example/release RELEASE_TAG=v1.2.3 \
    RELEASE_COMMIT="${2:-$validated_commit}" bash "$recheck_script" 2>/dev/null
}
run_recheck "commit $validated_commit" ||
  fail "the release tag re-check rejected a lightweight tag naming the validated commit"
run_recheck "tag $(tag_object 5)" ||
  fail "the release tag re-check rejected an annotated tag of the validated commit"
run_recheck "tag $(tag_object 2)" ||
  fail "the release tag re-check rejected a four-level tag chain to the validated commit"
run_recheck "commit $moved_commit" &&
  fail "the release tag re-check accepted a tag naming another commit"
run_recheck "tag $(tag_object 9)" &&
  fail "the release tag re-check accepted an annotated tag of another commit"
run_recheck "tag $(tag_object 1)" &&
  fail "the release tag re-check accepted a tag chain still unpeeled after four levels"
run_recheck "commit $validated_commit" v1.2.3 &&
  fail "the release tag re-check accepted a non-SHA release commit"

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

# The Apple Release ordering guard (issue #421): GitHub's latest release, which
# the website and Cockpit's Sparkle feed follow, must be the highest semantic
# version with the highest build. Run the workflow's own step body against a
# stubbed `gh`. release-metadata and publish must carry the identical check.
release_workflow="$APPLE_ROOT/../.github/workflows/apple-release.yml"
release_guard="$work/release-guard"
mkdir -p "$release_guard/tools"
awk -v name='Require a release above every published version' -v out="$release_guard/step" '
  in_run && $0 == "" { blanks += 1; next }
  in_run {
    if (substr($0, 1, 10) == "          ") {
      for (; blanks > 0; blanks--) print "" > (out "-" found ".sh")
      print substr($0, 11) > (out "-" found ".sh")
      next
    }
    in_run = 0
    in_step = 0
    blanks = 0
  }
  in_env {
    if (substr($0, 1, 10) == "          ") {
      print substr($0, 11) > (out "-" found ".env")
      next
    }
    in_env = 0
  }
  $0 == "      - name: " name { found += 1; in_step = 1; next }
  /^      - / || /^  [^ ]/ { in_step = 0 }
  in_step && $0 == "        env:" { in_env = 1; next }
  in_step && $0 == "        run: |" { in_run = 1 }
' "$release_workflow"
[[ -s "$release_guard/step-1.sh" && -s "$release_guard/step-2.sh" && ! -e "$release_guard/step-3.sh" ]] ||
  fail "apple-release.yml must run the release ordering check in release-metadata and publish"
cmp -s "$release_guard/step-1.sh" "$release_guard/step-2.sh" ||
  fail "release-metadata and publish ordering checks differ"
# Each guard step's own env block must feed it from its own job's outputs; a
# whole-file search would also match the macOS/TestFlight job env and the
# publish step that already read needs.release-metadata.outputs.
step=0
for expression in steps.release.outputs needs.release-metadata.outputs; do
  step=$((step + 1))
  printf '%s\n' \
    "GH_TOKEN: \${{ github.token }}" \
    "RELEASE_BUILD_NUMBER: \${{ $expression.build-number }}" \
    "RELEASE_TAG: \${{ $expression.tag }}" > "$release_guard/expected-$step.env"
  cmp -s "$release_guard/expected-$step.env" "$release_guard/step-$step.env" ||
    fail "ordering check $step must receive GH_TOKEN, RELEASE_BUILD_NUMBER, and RELEASE_TAG from $expression"
done
cat > "$release_guard/tools/gh" <<'TOOL'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$RELEASE_GUARD_FIXTURES/calls"
if [[ "$1 $2" == "api --paginate" ]]; then
  [[ -e "$RELEASE_GUARD_FIXTURES/api-failure" ]] && { printf 'HTTP 502\n' >&2; exit 1; }
  [[ "$3" == "repos/example/made/releases?per_page=100" ]] || exit 3
  cat "$RELEASE_GUARD_FIXTURES/releases.json"
elif [[ "$1 $2" == "release download" ]]; then
  tag="$3"
  directory=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == --dir ]] && directory="$2"
    shift
  done
  printf '%s\n' "$tag" > "$RELEASE_GUARD_FIXTURES/downloaded"
  cp "$RELEASE_GUARD_FIXTURES/appcast-$tag.xml" "$directory/appcast.xml"
else
  exit 4
fi
TOOL
chmod +x "$release_guard/tools/gh"
release_json() { # tag [appcast|none] [draft]
  local assets='[]'
  [[ "${2:-none}" == appcast ]] && assets='[{"name":"made-x-macOS.zip"},{"name":"appcast.xml"}]'
  printf '{"tag_name":"%s","draft":%s,"assets":%s}' "$1" "${3:-false}" "$assets"
}
appcast_for() { # tag build
  printf '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><title>%s</title><sparkle:version>%s</sparkle:version><sparkle:shortVersionString>%s</sparkle:shortVersionString><enclosure url="https://example.invalid/%s.zip" length="1" type="application/octet-stream" sparkle:edSignature="c2ln"/></item></channel></rss>\n' \
    "${1#v}" "$2" "${1#v}" "$1" > "$RELEASE_GUARD_FIXTURES/appcast-$1.xml"
}
reset_release_guard() { # releases-json
  export RELEASE_GUARD_FIXTURES="$release_guard/fixtures"
  rm -rf "$RELEASE_GUARD_FIXTURES" "$release_guard/runner-temp"
  mkdir -p "$RELEASE_GUARD_FIXTURES" "$release_guard/runner-temp"
  printf '%s' "$1" > "$RELEASE_GUARD_FIXTURES/releases.json"
}
run_release_guard() { # tag build
  PATH="$release_guard/tools:$PATH" RELEASE_TAG="$1" RELEASE_BUILD_NUMBER="$2" \
    GITHUB_REPOSITORY=example/made GH_TOKEN=test RUNNER_TEMP="$release_guard/runner-temp" \
    bash --noprofile --norc -eo pipefail "$release_guard/step-1.sh" > "$release_guard/log" 2>&1
}
expect_release_allowed() {
  run_release_guard "$1" "$2" || fail "release $1 ($2) was refused: $(cat "$release_guard/log")"
}
expect_release_refused() { # tag build reason
  if run_release_guard "$1" "$2"; then
    fail "release $1 ($2) must be refused: $3"
  fi
}

# The first semantic release has nothing to exceed; drafts and ChromiumKit
# support releases are not semantic app releases.
reset_release_guard "[$(release_json chromiumkit-123 none),$(release_json v9.0.0 appcast true)]"
expect_release_allowed v1.0.0 1.1
[[ ! -e "$RELEASE_GUARD_FIXTURES/downloaded" ]] || fail "no appcast should be read without a semantic release"

# A higher version with a higher build is allowed; versions compare numerically
# across paginated responses, so v1.10.0 is above v1.9.0.
reset_release_guard "[$(release_json v1.3.0 appcast),$(release_json v1.9.0 appcast)][$(release_json v1.2.0 appcast)]"
appcast_for v1.9.0 50.1
expect_release_allowed v1.10.0 51.1
[[ "$(cat "$RELEASE_GUARD_FIXTURES/downloaded")" == v1.9.0 ]] ||
  fail "the build must be compared with the highest release's appcast"
expect_release_allowed v1.9.1 50.2

# An older-line hotfix, a recovered older tag, or a republished version would
# move GitHub's latest release, and the Sparkle feed, backwards.
expect_release_refused v1.2.1 51.1 "lower version than v1.9.0"
expect_release_refused v1.9.0 51.1 "same version as v1.9.0"
expect_release_refused v1.8.9 99.1 "lower version than v1.9.0"
grep -Fq 'is not above the highest published release v1.9.0' "$release_guard/log" ||
  fail "an ordering refusal must name the highest release: $(cat "$release_guard/log")"

# Sparkle compares CFBundleVersion: a higher version with a lower or equal build
# than the published feed would never be offered to existing installs.
expect_release_refused v1.10.0 49.9 "lower build than 50.1"
expect_release_refused v1.10.0 50.1 "same build as 50.1"
expect_release_refused v1.10.0 50 "build 50 is not above 50.1"

# A pre-Sparkle highest release has no feed build to exceed.
reset_release_guard "[$(release_json v0.9.0 none)]"
expect_release_allowed v0.10.0 3.1
[[ ! -e "$RELEASE_GUARD_FIXTURES/downloaded" ]] || fail "a release without an appcast must not be downloaded"

# Malformed inputs and unreadable listings or feeds fail closed.
reset_release_guard "[$(release_json v1.0.0 appcast)]"
appcast_for v1.0.0 'not-a-build'
expect_release_refused v1.1.0 9.1 "unreadable published build"
printf '<rss></rss>\n' > "$RELEASE_GUARD_FIXTURES/appcast-v1.0.0.xml"
expect_release_refused v1.1.0 9.1 "published appcast without a build"
appcast_for v1.0.0 8.1
expect_release_allowed v1.1.0 9.1
expect_release_refused v1.1.0-beta 9.1 "non-semantic tag"
expect_release_refused v1.1.0 'nine' "non-numeric build number"
touch "$RELEASE_GUARD_FIXTURES/api-failure"
expect_release_refused v1.1.0 9.1 "release listing failed"
unset RELEASE_GUARD_FIXTURES

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
