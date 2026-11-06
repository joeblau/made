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
under [the performance task #379](https://github.com/joeblau/made/issues/379).
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
