# Android Annex-B parser benchmark

Issue #265 compares the checked-in `H264AnnexBAssembler` with baseline
`4f9997cdd7ac2a5747a59891017ada29c9fc1e13`. The benchmark compiles both
sources with the same harness and `swiftc -O -swift-version 6`.

The workload is one 262,150-byte synthetic access unit: a four-byte Annex-B
start code, bytes `65 80`, and 262,144 bytes of `55`. Eight independent parser
instances receive it in 1, 4, or 64 KiB chunks, followed by `flushTrailing()`.
Each run must emit eight events. The harness performs five runs per chunk size
by default and reports the run with median elapsed time, including that run's
thread CPU time, allocation count, and allocated bytes. A `malloc_logger` hook counts allocations
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

## Results (2026-11-09)

Xcode 27.2 / Swift 6.4.2 on a Mac15,8 (16 cores, AC power), nine runs per
chunk size, median run shown. The host was contended (load average about 95
from an Android emulator, two iOS simulators, and Cockpit), so wall time is
not a fair measurement. The harness therefore also reports thread CPU time,
which excludes time spent descheduled; allocation counts are deterministic and
independent of load.

| Chunk | Baseline `4f9997c` CPU | Current CPU | Speed-up | Allocations (both) | Allocated bytes (both) |
|---|---|---|---|---|---|
| 1 KiB | 1.07412 s | 0.00122 s | about 880x | 136 | 11,355,696 |
| 4 KiB | 0.26977 s | 0.00112 s | about 240x | 112 | 10,290,736 |
| 64 KiB | 0.02798 s | 0.00119 s | about 24x | 72 | 9,176,624 |

All runs emitted eight events. The baseline gets 38x slower as reads shrink
from 64 KiB to 1 KiB, the quadratic rescan this issue describes; the current
parser is flat (1.02x), so fragmented input is scanned about once. Allocation
counts and bytes are identical, so the gain is algorithmic and adds no
allocation cost. Contention can inflate CPU time a little through cache and
frequency effects, but not by the two to three orders of magnitude measured.

## Live device verification (2026-11-09)

Run on a Solana Seeker (Android 16, 1200x2670, streamed at 712x1600 and
16 Mbps) over USB.

**Parser parity on real bytes.** A 27,878,328-byte `screenrecord` capture of
scrolling content was fed to the checked-in assembler and to baseline
`4f9997c` in fixed 1 KiB, 4 KiB, 64 KiB, and 1 MiB chunks, and in three
pseudo-random chunkings of 1 byte to 64 KiB. All 14 runs produced the same
SHA-256 event digest (1 parameter-set pair, 860 access units, 1 IDR,
27,878,296 AVCC bytes). Reproduce with:

```bash
adb -s <serial> exec-out screenrecord --output-format=h264 --time-limit 14 - > capture.h264
apple/bin/check-annexb-parity.sh capture.h264
apple/bin/check-annexb-parity.sh capture.h264 "$baseline_dir/H264AnnexBAssembler.swift"
```

**Recording continuity and recovery.** `apple/bin/check-android-stream-live.sh`
compiles Cockpit's own `AndroidScreenStream`, `H264AnnexBAssembler`,
`AndroidStreamRecorder`, `AndroidStreamPolicy`, and `AdbBridge` into a harness
wired the way `AndroidDeviceSession` wires them. It records across three stream
lifetimes on one connection epoch:

1. the first stream;
2. an in-place restart, the record-start and rotation path;
3. `screenrecord` killed on the device after a 12.4 s healthy run, then
   respawned by the restart policy.

It then decodes every frame of the recording.

| Measure | Result |
|---|---|
| Samples teed to the recorder | 2,582, including 4 IDRs |
| Poisoned streams / sync requests | 0 / 0 |
| Segments | 1, with no error, across both respawn seams |
| Frames decoded | 2,582 of 2,582, timestamps strictly increasing |
| Duration | 24.57 s |
| Largest seam freeze | 0.608 s |

The harness opens Settings and scrolls it for motion, then presses Back.

## Limits

The 4 MiB buffer cap is checked before every append, so buffered input never
grows past it. Leading-garbage, NAL, and parameter-set limits are checked after
that bounded append or when a NAL unit completes, exactly as in baseline
`4f9997c`; they can reject a stream but cannot let memory grow past the cap.

The focused `PilotTests/H264AnnexBAssemblerTests` suite passed all 30 test
cases (40 runs including parameterized cases), with zero failures.
