# Apple CI build-product reuse

Issue #282 removes duplicate application-host compilation between
`apple/bin/build-ci.sh` and `apple/bin/test.sh all`.

## Supported Xcode 27 runner evidence

The normal CI lane remains quiet. To collect the missing non-quiet evidence,
run the opt-in benchmark from a checkout of the revision being measured:

```bash
apple/bin/benchmark-ci.sh "$RUNNER_TEMP/apple-ci-evidence"
```

The evidence directory must not already exist. The tool creates fresh
DerivedData below that directory, preserves `BLAU_SOURCE_PACKAGES` as the
external SwiftPM clone cache, and runs `build-ci.sh` followed by `test.sh all`.
It removes `-quiet` only from benchmarked `xcodebuild` invocations and tees
their complete output to `logs/`. It requires Xcode 27, the toolchain enforced
by current CI, and propagates build/test failures.

Each run produces:

- `environment.txt`: revision, architecture, runner image, macOS, and Xcode.
- `steps.tsv`: complete `build-ci.sh` and `test.sh all` wall seconds and status.
- `commands.tsv`: one row per `xcodebuild` invocation, including action, scheme,
  `SwiftCompile` count, `CompileC` count, their sum, wall seconds, status, and
  log path.
- `totals.tsv`: invocation, compile-count, `xcodebuild`-only wall-time, and
  failure totals for the build and test phases.
- `logs/`: the non-quiet log supporting every row in `commands.tsv`.

`build-for-testing` belongs to the build phase; `test-without-building` belongs
to the test phase. Thus the mobile hosts and test bundles are counted whether a
revision compiles them during `test` or during `build-for-testing`. Compare both
per-phase and combined counts, and use `steps.tsv` rather than GitHub step
timestamps for paired wall time.

### Exact paired runner protocol

Use two sequential, otherwise identical GitHub-hosted jobs on the current
`xcode-27` label. Do not substitute a local or contended machine. The paired
revisions are:

- **Baseline:** `958130b8bdaf20b0b9789f1b679a44b65fd1b550`, immediately before
  the #335 build-reuse implementation.
- **Reuse:** `2a857f3018b7840bd2a415d31cfc0424655fb4fd`, the #335
  implementation.

The immediate parent is the closest available pre-reuse checkout on the current
toolchain. However, #335 also adds DroneTools/DroneTests and preflight checks.
Whole-lane totals therefore compare the actual revisions, not reuse alone. Use
`commands.tsv` to aggregate Pilot/PilotTests, Copilot/SharedTests, and
Plotter/PlotterTests across both phases for the like-for-like host evidence;
do not attribute the whole-lane delta solely to reuse.

These revisions have identical SwiftPM lock and pinned binary-artifact inputs.
Run both jobs on the same `runner_image` and architecture, with full history and
Git LFS objects checked out at a tooling revision containing
`apple/bin/benchmark-ci.sh`. Restore the exact same pre-warmed SwiftPM cache to
`$GITHUB_WORKSPACE/apple/.ci-source-packages` in both jobs. A suitable immutable
cache key is `apple-ci-282-xcode27-shared-packages-v1`; neither measured job may
save or update it. Do not restore DerivedData. If the package cache is not
already populated, populate it in a separate warm-up job and discard that run's
measurements.

Set `TARGET_REVISION` to the baseline SHA for the first job and the reuse SHA
for the second, then run:

```bash
set -euo pipefail
tooling="$GITHUB_WORKSPACE"
target="$RUNNER_TEMP/target"
evidence="$RUNNER_TEMP/apple-ci-$TARGET_REVISION"
git -C "$tooling" worktree add --detach "$target" "$TARGET_REVISION"
cd "$target"
export BLAU_SOURCE_PACKAGES="$tooling/apple/.ci-source-packages"
"$tooling/apple/bin/benchmark-ci.sh" "$evidence"
awk -F '\t' 'NR > 1 && $3 != 0 { exit 1 }' "$evidence/steps.tsv"
printf 'Evidence: %s\n' "$evidence"
cat "$evidence/environment.txt" "$evidence/steps.tsv" "$evidence/totals.tsv"
```

Upload `environment.txt`, `steps.tsv`, `commands.tsv`, `totals.tsv`, and all of
`logs/` from each job, including after a failure; do not upload DerivedData.
Confirm that both `environment.txt` files report the same runner image,
architecture, and Xcode 27 build. A mismatch invalidates the pair and requires
rerunning both jobs. Keep the raw artifacts with the report.

Record the actual outputs in these tables only after both jobs pass. Do not fill
them from the historical Xcode 26 results below.

| Whole-lane metric (includes the Drone lane difference) | Baseline | Reuse |
| --- | ---: | ---: |
| Build `SwiftCompile` / `CompileC` / total | — | — |
| Test `SwiftCompile` / `CompileC` / total | — | — |
| Combined compile units | — | — |
| Build script wall seconds | — | — |
| Test script wall seconds | — | — |
| Combined script wall seconds | — | — |

| Like-for-like compile units across build + test | Baseline | Reuse |
| --- | ---: | ---: |
| Pilot + PilotTests | — | — |
| Copilot + SharedTests (iOS host) | — | — |
| Plotter + PlotterTests (iPadOS host) | — | — |

## Historical clean-run compile counts and local wall time

These paired measurements used Xcode 26.6 (17F113) on arm64, with DerivedData
removed and SwiftPM clones cached. Compile units are the `SwiftCompile` and
`CompileC` tasks in non-quiet build logs. The heavily loaded local host (load
average 46–330) was not a GitHub-hosted runner, so these timings are not a
controlled runner benchmark and do not satisfy the current Xcode 27 gate.

| macOS Pilot build + hosted tests | Before | After |
| --- | ---: | ---: |
| Build-step compile units | 1,445 | 1,445 |
| Test-step compile units | 1,521 | 76 |
| Total compile units | **2,966** | **1,521** |
| Run 1 wall time (build / test / total) | 82 s / 241 s / 323 s | 87 s / 51 s / 138 s |
| Run 2 wall time (build / test / total) | 56 s / 119 s / 175 s | 55 s / 45 s / 100 s |

The first baseline test run included a 108-second TLS-fixture timeout caused by
host load. Compile counts were identical across two independent runs, and all
497 PilotTests passed in both optimized runs.

## Historical GitHub-hosted Xcode 26 runner wall time

The following complete Apple build/test jobs ran on GitHub's `macos-26-arm64`
image with Xcode 26.6 (17F113), clean DerivedData, and cached SwiftPM packages.
GitHub's timestamps have one-second resolution.

| Step | [Before](https://github.com/joeblau/made/actions/runs/36928564836/job/110591922182) | [After](https://github.com/joeblau/made/actions/runs/36931491398/job/110601649267) |
| --- | ---: | ---: |
| Compile every application | 12 m 9 s | 11 m 20 s |
| Run unit tests | 11 m 6 s | 6 m 49 s |
| Total | **23 m 15 s** | **18 m 9 s** |

The optimized runner job passed the complete build and hosted-test lane. Its
quiet CI logs do not contain per-compile-task records, so these runs provide
only historical Xcode 26 wall-time evidence. They cannot supply the requested
compile counts or current supported-toolchain timings.
