# Web startup baseline

This records the before/after evidence for deferring the decorative cockpit
scene. The before build is issue #269's pinned baseline, `4f9997c`; the after
build is `4eefbbf`. The site was redesigned between those revisions, so this is
a release comparison rather than an isolated A/B measurement of one commit.

## JavaScript transfer budgets

A fresh build's reachable module graph was measured as raw bytes and gzip -9.
Initial includes HTML script entries, module preloads, and their static imports.
Deferred includes dynamic imports and their static closure. Emitted modules no
page reaches are not counted.

| Module group | Before raw / gzip | After raw / gzip | Budget raw / gzip |
| --- | ---: | ---: | ---: |
| Initial JavaScript | 535,735 / 134,101 | 6,522 / 3,184 | 8,000 / 4,000 |
| Deferred JavaScript | 0 / 0 | 581,747 / 146,349 | 600,000 / 150,000 |
| Unreferenced, not counted | 191,646 / 59,536 | 220,749 / 68,073 | none |

The unreferenced output is the React client emitted by the build-time-only QR
integration. It is reported for visibility but is not an initial browser
download. `workers/web/scripts/check-build-size.mjs` enforces both raw and
compressed ceilings on every web build.

## Throttled mobile startup

Measured locally on 2026-11-02 with an Apple M3 Max, Chrome 156.0.8078.80, and
Node 24.22.1. Each of three cold-profile runs used a 390 × 844 mobile viewport,
device scale factor 3, 4× CPU throttling, 150 ms latency, and 1.6 Mbps download
bandwidth. JavaScript was served with gzip -9. Chrome DevTools Protocol tracing
(`devtools.timeline`), performance metrics, and network events were sampled at
the window `load` event on `/made/`; cache was disabled.

The table reports medians, with ranges in parentheses. Transfer is the sum of
Chrome's `encodedDataLength` for scripts finished by `load`, including HTTP
overhead. Task and script CPU are the renderer's cumulative `TaskDuration` and
`ScriptDuration` metrics at that point.

| Metric | Before | After |
| --- | ---: | ---: |
| Time to `load` | 42.35 s (32.50–46.97) | 13.53 s (12.04–40.24) |
| Task CPU | 41.27 s (31.44–45.82) | 9.72 s (8.63–34.84) |
| Script CPU | 33.44 s (26.86–42.44) | 10.79 ms (10.68–14.28) |
| Initial JavaScript transfer | 134,542 bytes | 4,061 bytes |

The after scene and optional interactions were absent from the initial transfer
in every run. These traces are local reference evidence, not CI timing
assertions; the deterministic transfer budgets above are the regression gate.
