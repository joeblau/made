# Notes editing benchmark

This report tracks the locally actionable evidence for
[#266](https://github.com/joeblau/made/issues/266). The standalone harness is
restored from `ba9c007bcb92d77acc797f31c95e977fa48704dc` and adapted to compile
both the current and pre-incremental editor sources. It does not change
production code.

## Method

- Current source: `fd047ba2888fc934384e7be32d811519505f6b51`.
- Pre-incremental baseline: `86e05c6cdeeae5b848784e98104f1a4cd83c0f28`, the
  parent of the original incremental implementation in `84be0cf9`.
- Harness: `apple/Tools/NotesEditBenchmark/main.swift`, compiled by
  `apple/bin/benchmark-notes-editing.sh` with `swiftc -O -swift-version 6`.
- Measurement: synchronous `insertText` on the main thread through the real
  text-storage delegate, secret mask, gutter/overlay updates, and automatic
  task/table reflows. Each workload runs once as an unrecorded warm-up and once
  as a recorded fresh editor. `edit+layout` additionally forces the full text
  container layout.
- Scope: the view is off-screen, so drawing, display delivery, physical input,
  persistence, and application-wide work are excluded. This is not an
  end-to-end key-to-pixel latency measurement.

The small fixture has one mixed-content section (438 UTF-16 units). The long
fixture has 120 sections containing prose, Markdown markup, secrets, tasks,
tables, fenced code, links, and images. Workloads cover prose, table-cell text,
task text, fenced-code text, and insertion of a fence delimiter that re-pairs
later fences and exercises the full-pass fallback. A styler-only prose workload
isolates styling from the text view and reflows. Every statistic is accompanied
by its ordered raw millisecond samples. Median averages the two middle values
for an even sample count; p95 uses nearest rank. Most workloads have 16 samples,
while fence-delimiter fallback has three, so its p95 is only its maximum.

## Reproduce

Run from the benchmark branch checkout. Create a separate detached baseline;
do not overwrite or copy the baseline's production sources into the current
checkout.

```sh
git worktree add --detach /tmp/made-notes-baseline \
  86e05c6cdeeae5b848784e98104f1a4cd83c0f28

# Current: all workloads, small and long notes.
MADE_BENCHMARK_OUT=/tmp/made-notes-current-build \
  apple/bin/benchmark-notes-editing.sh current-fd047ba2 \
  | tee /tmp/made-notes-current.log

# Pre-incremental: the same runner and fixture, baseline production sources.
MADE_SOURCE_ROOT=/tmp/made-notes-baseline/apple \
MADE_BENCHMARK_OUT=/tmp/made-notes-baseline-build \
  apple/bin/benchmark-notes-editing.sh pre-incremental-86e05c6 \
  | tee /tmp/made-notes-baseline.log
```

`MADE_SOURCE_ROOT` names the other checkout's `apple` directory. Use separate
`MADE_BENCHMARK_OUT` directories when runs overlap. To focus one long-note
workload, append its name, for example `prose`, `table cell`, `task text`,
`fenced code`, `fence delim`, or `styler`. Append `small` after the workload for
a quick small-note smoke run, or append `long` explicitly. Use `all small` for
every workload on only the small note, or `all long` for only the long note.

Run correctness independently of timing collection:

```sh
export BLAU_DERIVED_DATA=/tmp/made-notes-derived
source apple/bin/lib/xcodebuild-ci.sh
python3 apple/bin/check-cockpit-ui-boundary.py
ci_xcodebuild test "$MACOS_DERIVED_DATA" \
  -scheme PilotTests \
  -destination "$MACOS_DESTINATION" \
  -only-testing:PilotTests/MarkdownStylerIncrementalTests \
  -only-testing:PilotTests/NotesEditingSmokeTests \
  -only-testing:PilotTests/NoteDisplayTitleTests \
  -only-testing:PilotTests/NotesTableReflowCaretTests \
  -only-testing:PilotTests/NativeNotesTests \
  -only-testing:PilotTests/NotesSecurityBoundaryTests
```

## Evidence status

Uncontended current-versus-baseline results remain needed. Before collection,
the Apple M3 Max (128 GiB, arm64, macOS 27.2, Xcode 27.2) had load averages of
7.96, 8.38, and 10.88, with active desktop, simulator, browser, and installed
Cockpit processes. This does not meet an idle-machine bar, so no comparative
latency claim is recorded.

Both source revisions compiled successfully with the adapted optimized runner.
Both completed every small-note workload in `edit` and `edit+layout` modes,
including styler-only prose and fence-delimiter fallback. A current smoke
sample also contained 51–71 ms outliers, and a final check found other
compilation and test-host processes still active. These development-desktop
timings are not performance evidence, so raw smoke timings are not promoted
into a comparison table. The full current/baseline commands above still need
to be run after builds and other heavy processes finish, preferably in
alternating order over multiple fresh runs with the raw logs retained.

The focused native correctness command above passed 46 tests (54 runs including
parameterized cases), with zero failures and zero skips. The first attempt with
shared derived data did not run tests because another build held its database
lock; the recorded pass used isolated `/tmp/made-fix-266-derived` instead. No
production behavior was changed by this benchmark restoration.

## Remaining native and physical gates

- Collect uncontended optimized current/baseline runs for every small and long
  workload, including raw samples and run-to-run variation.
- Profile a visible Notes editor in the real application if evidence is needed
  for drawing, scrolling, window/layout interaction, or key-to-pixel latency.
- Exercise physical keyboard input and IME composition interactively; the
  standalone harness calls `insertText` directly and cannot validate those
  input paths.
- Keep these off-screen numbers separate from memory, energy, persistence, and
  physical-device/companion acceptance checks, which this harness does not
  exercise.
