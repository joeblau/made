# Agentic usage loader benchmark

Issue #267 needs reproducible evidence for cold loads, unchanged refreshes,
small appends, and cancellation. The `AgenticUsagePerformanceTests` suite is an
opt-in benchmark, not part of normal CI timing: every test skips unless
`MADE_USAGE_BENCHMARK_OUTPUT` is set. The production loader is unchanged.

## Corpus and workloads

Each workload creates a deterministic synthetic corpus of **16,384 records per
provider** for Claude, Codex, Grok, and Kimi: 65,536 records in four JSONL files.
The files contain only local fixture data and do not contact a provider.

- **Cold load:** a new in-memory loader parses all four files on every measured
  iteration. Record count and total parsed bytes must match the corpus. Corpus
  creation is excluded. This is loader-cold, not a cold OS file-cache test.
- **Unchanged refresh:** an unmeasured initial load precedes repeated refreshes.
  Every measured refresh must return all records, report no change, and parse
  zero bytes.
- **Small append:** an unmeasured initial load precedes one-record Kimi appends.
  File writing is excluded. Every load must parse exactly the appended byte
  count and retain the expected cumulative record count.
- **Cancellation:** each iteration starts a fresh load, waits for scan progress,
  and measures cancellation through `CancellationError`. An unmeasured recovery
  load must then return the complete corpus.

The default is five measured iterations per workload. Reports retain each raw
elapsed time and its parsed-byte, record-count, or cancellation observation;
there are no performance thresholds that could make normal CI flaky.

## Reproduce

From the repository root, choose a new output path for each run:

```sh
MADE_USAGE_BENCHMARK_ITERATIONS=5 \
  apple/bin/benchmark-agentic-usage.sh /tmp/made-usage-benchmark-run-1
```

The runner builds hosted Debug tests with `-O` and whole-module optimization,
runs only `AgenticUsagePerformanceTests`, and disables parallel testing. Its
benchmark-specific derived-data directory can be overridden with
`BLAU_USAGE_BENCHMARK_DERIVED_DATA`; package resolution follows the shared Apple
CI policy, including `BLAU_SOURCE_PACKAGES` when set.

Each output directory contains:

- `environment.json`: hardware, macOS, Xcode, source revision, iteration count,
  one/five/fifteen-minute load averages before and after, and test exit status;
- `cold-load.json`, `unchanged-refresh.json`, `small-append.json`, and
  `cancellation.json`: corpus sizes and raw per-iteration measurements;
- `AgenticUsage.xcresult`: the hosted XCTest result, retained even though the
  build log is quiet.

The runner refuses to overwrite an existing output path. Use separate paths for
independent runs and compare only matching revisions, corpus definitions,
optimization settings, hardware, and software.

## Measurement status: open

No timing results are published from the initial harness-validation run. A
meaningful baseline still requires an otherwise idle, thermally stable host with
competing builds, tests, and profilers stopped. Record the runner's before/after
load, repeat at least three fresh runs, and retain their raw JSON and result
bundles before adding measurements or comparative claims here. Harness smoke
runs on a loaded development machine are functional evidence only, not a
performance baseline.
