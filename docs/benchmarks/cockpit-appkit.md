# Cockpit presentation benchmark

This report accompanies the AppKit migration in
[#339](https://github.com/joeblau/made/issues/339).
The results below are **isolated panel construction/layout measurements**,
not application launch time, frame rate, input latency, power consumption, or
live terminal/browser/video performance.

## Baseline environment and method

- Revision: `513715f6fe218f11d3cf1829d038da0588931268`.
- Hardware: Apple M3 Max, Mac15,8, 128 GiB memory, arm64.
- Software: macOS 27.2 (26B123), Xcode 27.2 (27B52).
- Configuration: hosted Debug tests compiled with `-O` and whole-module
  optimization. The test host suppresses production services and opens an
  in-memory SwiftData store.
- Data: the existing fictional screenshot fixtures, including seven workspaces,
  four Notes, eight Docker containers, eight runners, provider usage, repository
  panels and thirty days of aggregate history.
- Presentation: light appearance, 1440 × 960 initial content, alternating widths
  of 1280 and 1600 at height 960.
- Sampling: three fresh test runs; each scene has one unrecorded warm-up and seven
  recorded constructions, with twenty width changes per construction.
- Timing: synchronous construction/first layout and subsequent synchronous
  layout after resizing. The 180 ms settling delay is excluded.
- Memory: resident bytes observed for the entire hosted test process, not
  per-panel allocation or leak evidence.

The baseline worktree changes consist of the added measurement test and the
regenerated project membership. Application sources are unchanged.
The exact instrumentation is retained in
[baseline-harness.patch](cockpit-appkit/baseline-harness.patch).
The measurement runner was invoked from the migration worktree against the
detached baseline.

These were collected during the development session. They establish a
reproducible starting point; release comparisons must repeat under controlled
background load. In particular, the analytics and runner tails vary materially.

## Recorded SwiftUI baseline

Each median below is the median of the three run medians. The p95 range shows
the minimum and maximum of the three within-run p95 values. All times are ms.

| Panel fixture | Mount/layout median | Mount/layout p95 range | Resize/layout median | Resize/layout p95 range |
| --- | ---: | ---: | ---: | ---: |
| Actions | 51.283 | 49.807–57.085 | 2.116 | 6.050–6.936 |
| Agentic Use | 139.944 | 152.475–245.931 | 73.399 | 81.363–132.033 |
| Docker | 56.761 | 59.238–69.010 | 4.014 | 6.085–6.513 |
| Files | 49.465 | 46.307–53.240 | 1.761 | 4.902–6.420 |
| Notes | 17.077 | 16.967–19.303 | 2.459 | 3.318–5.093 |
| Pull requests | 47.950 | 45.504–49.886 | 2.075 | 5.184–6.727 |
| Runners | 91.542 | 107.022–139.742 | 16.299 | 25.534–50.273 |
| Tasks | 57.102 | 51.414–64.123 | 2.535 | 6.428–8.145 |
| Usage | 46.586 | 47.874–52.147 | 2.393 | 2.840–7.730 |

Raw samples and environment metadata:

- [Baseline run 1](cockpit-appkit/swiftui-baseline-run-1.json)
- [Baseline run 2](cockpit-appkit/swiftui-baseline-run-2.json)
- [Baseline run 3](cockpit-appkit/swiftui-baseline-run-3.json)

The fixture shell also participates in these costs. Its native implementation
changes during the migration, so a faster fixture does not attribute the entire
difference to one production panel.

## Recorded AppKit candidate

The candidate contains the implementation frozen in review commit `5d7d205`,
measured from the shared migration checkout. Its application source matches
that review commit; the shared generated project also includes concurrent
app-icon resource work that is excluded from the review branch. These panel
workloads do not measure application icon loading or launch. The raw reports
record the actual shared-tree source fingerprint and compiled app/test binary
SHA-256 values; all three runs used the same products and source content.

The optimized full suite passed **1,041 tests, with zero failures and three
intentional opt-in skips**, before measurement. The separate capture run
exported all 28 light/dark scenes; visual review found no blocking defects.
The ordinary Debug suite on the isolated review checkout also passed the same
1,041 tests after the subsequent formatting-only cleanup.
Three fresh candidate runs used the same hardware, OS, Xcode, dimensions,
fixtures, appearances and sampling counts as the baseline. Known competing
builds were allowed to finish before each run. The installed Cockpit app and
normal desktop services remained running, so this remains a development
measurement rather than a controlled laboratory experiment. Two earlier
attempts associated with external probe compiles were excluded.

Each value below is the median of three run medians. Negative change means
less elapsed time. All times are ms.

| Panel fixture | AppKit mount/layout | Change from baseline | AppKit resize/layout | Change from baseline |
| --- | ---: | ---: | ---: | ---: |
| Actions | 56.444 | +10.1% | 0.864 | -59.2% |
| Agentic Use | 55.665 | -60.2% | 5.940 | -91.9% |
| Docker | 58.868 | +3.7% | 1.043 | -74.0% |
| Files | 44.005 | -11.0% | 0.947 | -46.2% |
| Notes text editor | 29.379 | +72.0% | 0.730 | -70.3% |
| Pull requests | 48.926 | +2.0% | 1.128 | -45.7% |
| Runners | 52.635 | -42.5% | 0.899 | -94.5% |
| Tasks | 60.695 | +6.3% | 0.897 | -64.6% |
| Usage | 53.446 | +14.7% | 0.938 | -60.8% |

Within-run p95 ranges across the three native runs:

| Panel fixture | Mount/layout p95 range | Resize/layout p95 range |
| --- | ---: | ---: |
| Actions | 58.898–62.599 | 2.450–2.591 |
| Agentic Use | 57.020–60.188 | 9.524–11.536 |
| Docker | 62.093–63.989 | 2.706–3.068 |
| Files | 45.816–47.754 | 2.726–3.420 |
| Notes text editor | 30.616–39.306 | 1.177–2.012 |
| Pull requests | 50.573–55.147 | 2.843–3.428 |
| Runners | 56.043–75.666 | 2.017–2.088 |
| Tasks | 63.525–68.264 | 2.288–2.520 |
| Usage | 51.231–59.435 | 2.184–2.690 |

Resize/layout improved in every measured fixture, while construction/layout
is mixed. In particular, the Notes fixture has a retained mount regression.
Both implementations use the production `NoteTextView` inside fixture-owned
tabs and headers; this workload does **not** instantiate the complete
`NotesViewController`. The fixture shell changes from SwiftUI to native stack
and control construction too. Therefore neither the regression nor the
improvements can be attributed entirely to an individual production panel.
Frameworks can defer different work beyond synchronous layout, so these
measurements also do not represent a fully rendered interactive frame.

Using the median of each run's mount/layout p95, Notes (+69.9%), Usage
(+22.0%) and Actions (+16.4%) exceed the migration policy's 15% investigation
threshold. These are retained concerns, not accepted release regressions.
The small samples and uncontrolled desktop background load do not establish
statistical significance; they identify workloads for focused profiling.

The Notes mount regression and other mount/p95 changes remain follow-up work
in the [release checklist](../appkit-migration.md), with their history retained
in [the performance task #379](https://github.com/joeblau/made/issues/379).
No fixture was simplified to improve the reported numbers, and these results
do not establish a whole-application performance win or satisfy that task's
full profiling gate.

Raw candidate samples and metadata:

- [AppKit run 1](cockpit-appkit/appkit-run-1.json)
- [AppKit run 2](cockpit-appkit/appkit-run-2.json)
- [AppKit run 3](cockpit-appkit/appkit-run-3.json)

## Reproduce

Create a detached worktree at the recorded revision. Apply the retained
instrumentation patch in that worktree, then run the migration branch's runner
against it. Use separate derived-data directories for baseline and candidate.

```sh
git worktree add --detach /tmp/cockpit-swiftui-baseline 513715f6fe218f11d3cf1829d038da0588931268
git -C /tmp/cockpit-swiftui-baseline apply /absolute/path/to/made/docs/benchmarks/cockpit-appkit/baseline-harness.patch

python3 apple/bin/benchmark-cockpit-presentation.py \
  --source-root /tmp/cockpit-swiftui-baseline \
  --derived-data /tmp/cockpit-baseline-derived \
  --output /tmp/cockpit-baseline.json \
  --implementation swiftui-baseline
```

The script uses the repository's pinned package-resolution policy. Set
`BLAU_SOURCE_PACKAGES` to an existing compatible checkout cache if needed.
Only use `--skip-build` after the runner's optimized build has succeeded;
a stale Debug or differently configured test bundle is not comparable.

For the native implementation, run from the migration checkout:

```sh
python3 apple/bin/benchmark-cockpit-presentation.py \
  --derived-data /tmp/cockpit-appkit-derived \
  --output /tmp/cockpit-appkit.json \
  --implementation appkit \
  --baseline /tmp/cockpit-baseline.json
```

The runner rejects mismatched hardware, OS, Xcode, configuration, appearance,
dimensions or scene sets before emitting ratios. It retains the raw samples;
a ratio is descriptive evidence rather than a significance test.
New reports also record source-content and compiled-product fingerprints so a
dirty migration checkout can be distinguished from its unchanged Git HEAD. The runner requires
all 63 recorded mounts and 1,260 resize samples and publishes a report only
after a fresh test run produces them.

## Remaining performance evidence

The panel comparison above does not replace separate optimized app profiles
for launch, event latency/hitches, active workspace/pane movement, long
streaming chats and Notes, large data/list scaling, hidden-session cost,
retained-resource stress, energy and Chromium process-tree behavior.
Physical device/companion/Drone and external-display checks remain separate.

The [migration verification contract](../appkit-migration.md) defines the source
boundary, feature matrix and acceptance limits. Do not mark the performance
task complete solely because the panel harness passes.

## November 5 consistency follow-up

The follow-up keeps the same optimized hosted-test workload and records three
runs before the UI polish, three after the initial layout changes, and three
after caching metric text measurements. Other builds were idle during each
measurement; the user's desktop applications remained running. The first
baseline was measured before edits. Baseline runs 2 and 3 reused those exact
compiled products: their reports verify matching host/test SHA-256 values,
retain the compiled-source fingerprint from run 1, and separately record the
advanced checkout present when those retained binaries were measured.

The final interface shows more information in the same viewport: KPI cards are
96 pt tall, repository/container rows are more compact, and analytics column
layout includes the space needed by legacy scrollbars. Formatting, trend
updates, provider-button allocation, and metric text measurement no longer
repeat on ordinary resize paths. These are structural work reductions; the
measurements below do **not** establish a broad performance improvement.

Times are milliseconds. Each central value is the median of the three run
medians; p95 columns give the range of within-run p95 measurements.

| Panel | Before mount | Final mount | Before resize | Final resize | Final resize p95 range |
| --- | ---: | ---: | ---: | ---: | ---: |
| actions | 57.973 | 59.661 | 3.780 | 5.617 | 9.422–10.663 |
| agentic-use | 48.972 | 54.052 | 5.746 | 5.600 | 10.595–11.334 |
| docker | 65.239 | 63.756 | 6.434 | 3.196 | 10.189–16.399 |
| files | 47.021 | 49.249 | 4.390 | 5.372 | 12.992–16.051 |
| notes | 43.197 | 51.004 | 1.229 | 4.867 | 9.190–11.215 |
| pull-requests | 50.832 | 55.467 | 4.325 | 3.260 | 8.973–10.555 |
| runners | 56.579 | 58.667 | 3.110 | 5.092 | 9.910–14.564 |
| tasks | 63.095 | 62.222 | 1.839 | 1.764 | 7.312–9.606 |
| usage | 59.246 | 59.473 | 3.441 | 6.330 | 10.252–14.017 |

Dashboard resize/layout is roughly unchanged (5.746 → 5.600 ms), within the
observed run variation. Several other medians are worse, so this follow-up
does not close the performance acceptance gate. Variation is substantial even
in untouched fixtures: before-run Notes resize medians span 0.506–5.703 ms,
and Files spans 0.792–5.047 ms. These changes require profiling of window resize,
layout, rendering and main-thread scheduling before attributing them to the
modified panels. The table must not be read as application input latency or
frame-render time. The denser layout can also change which rows are visible.

[Aggregate statistics](cockpit-appkit/polish-summary.json) retain run-median
ranges, within-run p95 ranges, and pooled sample standard deviations for both
construction and resize. Raw samples and source/product fingerprints:

- Before: [run 1](cockpit-appkit/polish-before-run-1.json), [run 2](cockpit-appkit/polish-before-run-2.json), [run 3](cockpit-appkit/polish-before-run-3.json).
- Initial layout pass: [run 1](cockpit-appkit/polish-layout-run-1.json), [run 2](cockpit-appkit/polish-layout-run-2.json), [run 3](cockpit-appkit/polish-layout-run-3.json).
- With cached metric measurements: [run 1](cockpit-appkit/polish-cached-run-1.json), [run 2](cockpit-appkit/polish-cached-run-2.json), [run 3](cockpit-appkit/polish-cached-run-3.json).

Functional validation for the layout/interaction pass: 1,059 Pilot tests passed,
zero failed, with three intentional opt-in skips; all 26 design-review captures
were refreshed. The subsequent metric-measurement cache passed the focused
native analytics suite, including changed data and 85%/100%/200% zoom. Swift lint
and the AppKit presentation boundary checks passed. The subsequent follow-up
completed typography roles and removed temporary zero-width stack conflicts;
the final full suite passed 1,063 tests with zero failures, four opt-in skips,
and zero constraint conflicts in exported diagnostics. See the interaction
measurements below for the additional profiling evidence.

A separate 15-second Time Profiler recording launched the optimized candidate
through `/usr/bin/env` with `BLAU_COCKPIT_FIXTURE=1`, using the isolated in-memory
Notes window. The recorded image UUID was checked against the candidate binary;
a first probe that LaunchServices routed to the installed app was excluded.
Of 317 main-thread samples, 313 occurred in the first two seconds. Native window
and toolbar initialization/layout appeared frequently in those startup stacks;
no potential hang over 250 ms was reported. This is sampled startup/idle
evidence, not a launch-time, frame-time, or interaction-latency measurement.
[Profile summary](cockpit-appkit/polish-launch-profile.json); the retained trace
and exported tables are in `apple/.build/polish-profile/`.


## November 5 navigation and streaming follow-up

Time Profiler identified repeated sidebar cell construction and native view /
constraint removal and insertion during navigation. Sidebar rows now reload
only when their visible content changes. Visited global pages and inspector
tabs retain their view hierarchies; hidden pages relinquish keyboard focus,
stop their existing presentation work, and keep their geometry until shown.
Workspace and pane lifetimes remain bounded by their existing ownership.
Streaming text appends an unchanged attributed suffix while still replacing
prior Markdown runs when their formatting changes.

Three separate unprofiled runs used optimized `-O` whole-module products on the
same Mac and macOS/Xcode 27.2. No other builds or profilers ran during timing.
Each run visited Notes, Docker, Agentic Use, Runners, and the workspace five
times and visited all five inspector tabs in each cycle. The first cycle is
excluded from action timings. Each sample measures the synchronous selection
call plus immediate layout. The 200–250 ms settling waits are excluded. These
numbers are **not event-to-display latency or animation frame times**.

| Action | Before ms | Final ms | Reduction | Final within-run p95 range ms |
| --- | ---: | ---: | ---: | ---: |
| Inspector tab | 34.303 | 16.742 | 51.2% | 38.758–43.337 |
| Agentic Use | 50.172 | 17.526 | 65.1% | 18.711–22.110 |
| Docker | 48.477 | 16.081 | 66.8% | 14.402–19.685 |
| Notes | 23.614 | 7.775 | 67.1% | 8.529–8.691 |
| Runners | 77.771 | 34.613 | 55.5% | 34.707–40.853 |
| Workspace | 48.062 | 44.014 | 8.4% | 43.846–48.990 |

Central values are medians of the three run medians. Each run has four measured
samples per page and 20 inspector samples; small sample counts and desktop
scheduling limit precision. [Aggregate statistics](cockpit-appkit/interaction-summary.json)
retain all run medians, p95s, pooled sample deviations, counts and maxima.
[Before products](cockpit-appkit/interaction-before-products.json) and
[final products](cockpit-appkit/interaction-final-products.json) record binary
UUIDs and SHA-256 values. Final fingerprints match across all three runs.
Raw runs: [before 1](cockpit-appkit/interaction-before-run-1.json),
[2](cockpit-appkit/interaction-before-run-2.json),
[3](cockpit-appkit/interaction-before-run-3.json);
[final 1](cockpit-appkit/interaction-final-run-1.json),
[2](cockpit-appkit/interaction-final-run-2.json),
[3](cockpit-appkit/interaction-final-run-3.json).
The intermediate row-reuse runs and their product record are retained alongside
them; the summary includes their comparable navigation phases.

A separate [final Time Profiler recording](cockpit-appkit/interaction-profile-final.json)
verified the candidate image UUID and passed the same fixture. Inclusive sample
counts in page replacement fell from 444 to 151 and inspector selection from
541 to 182; the old unconditional sidebar-row reload path was removed. These
are sampled stacks, not exact durations. The traces and exported tables remain
in `apple/.build/polish-profile/`.

The chat check found a **benchmark fixture defect**: assigning its content
controller resized the window to a zero-height transcript. Earlier chat timings
and total/chat profile samples therefore cannot establish visible streaming
performance. They remain in the raw files, explicitly excluded from aggregate
comparisons. The corrected fixture sizes the window to 800 × 700 before timing,
asserts a visible transcript, and verifies that all 120 delivered paragraphs
appear. All three final runs and the separate profiler run passed.

The corrected workload loads 1,000 messages, then delivers 120 chunks while a
main-actor probe requests an 8 ms sleep. Additional scheduling-delay p95 during
streaming was 9.45–10.34 ms; during the subsequent hidden, idle interval it was
2.23–2.33 ms. These are scheduling observations, not frame-rate measurements or
hidden-streaming costs. Conversation delivery took a median 64.64 ms for the
history and 2.48 seconds for the stream; the latter includes 120 deliberate
10 ms shell sleeps, process scheduling, and IPC. There is no comparable valid
visible-chat baseline and no claimed streaming speedup.

Reproduce the corrected interaction workload from the repository root:

```bash
source apple/bin/lib/xcodebuild-ci.sh
TEST_RUNNER_MADE_INTERACTION_OUTPUT=/tmp/cockpit-interactions.json \
  ci_xcodebuild test /tmp/cockpit-interaction-derived -scheme PilotTests \
  -destination "$MACOS_DESTINATION" \
  -only-testing:PilotTests/CockpitPresentationPerformanceTests/testInteractionWorkloads \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule
```

The production change passed the full Pilot suite: **1,063 passed, zero failed,
four intentional opt-in skips**. The corrected benchmark additionally passed
four optimized runs with zero Auto Layout conflicts in exported final-profile
diagnostics. The review retains 26 refreshed light/dark and narrow/wide
captures. Compositor glass, GPU/event-to-display timing, energy, live engines,
and physical device/display acceptance remain separate checks; these results
do not close the entire migration release gate.
