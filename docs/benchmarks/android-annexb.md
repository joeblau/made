# Android Annex-B parser benchmark

Issue #265 compares the checked-in `H264AnnexBAssembler` with baseline
`4f9997cdd7ac2a5747a59891017ada29c9fc1e13`. The benchmark compiles both
sources with the same harness and `swiftc -O -swift-version 6`.

The workload is one 262,150-byte synthetic access unit: a four-byte Annex-B
start code, bytes `65 80`, and 262,144 bytes of `55`. Eight independent parser
instances receive it in 1, 4, or 64 KiB chunks, followed by `flushTrailing()`.
Each run must emit eight events. The harness performs five runs per chunk size
by default and reports the run with median elapsed time, including that run's
allocation count and allocated bytes. A `malloc_logger` hook counts allocations
only while parsing; input and chunk construction happen outside the measured
region. This is parser-only synthetic evidence, not Android device latency.

## Reproduce

Run from the repository root on an idle macOS host with Xcode installed. Keep
the same Xcode version, power state, and machine conditions for both runs, and
avoid concurrent builds, simulators, and other CPU-heavy work.

```bash
baseline_dir="$(mktemp -d -t made-annexb-baseline.XXXXXX)"
trap 'rm -rf "$baseline_dir"' EXIT
git show 4f9997c:apple/Sources/Pilot/Android/H264AnnexBAssembler.swift \
  > "$baseline_dir/H264AnnexBAssembler.swift"

ANNEXB_BENCH_REPETITIONS=5 \
  apple/bin/benchmark-annexb.sh "$baseline_dir/H264AnnexBAssembler.swift"
ANNEXB_BENCH_REPETITIONS=5 apple/bin/benchmark-annexb.sh
```

To check harness compatibility without measuring performance:

```bash
apple/bin/benchmark-annexb.sh --typecheck
apple/bin/benchmark-annexb.sh --typecheck "$baseline_dir/H264AnnexBAssembler.swift"
```

Both typechecks and optimized compilation passed locally with Xcode 27.2 /
Swift 6.4.2. The timed runs were not executed because the host was contended
(load averages 8.31, 8.45, and 10.92, with other CPU-heavy processes active).
**No timing or
allocation performance claim is made here.** Comparable before/after results
from an uncontended host remain a required gate.

The focused `PilotTests/H264AnnexBAssemblerTests` suite passed all 30 test
cases (40 runs including parameterized cases), with zero failures.

Live Android recording continuity and recovery also remain unverified. That
gate requires exercising a real stream; neither the synthetic benchmark nor
parser unit tests can establish it.
