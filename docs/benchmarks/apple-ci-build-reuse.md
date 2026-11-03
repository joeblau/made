# Apple CI build-product reuse

Issue #282 removes duplicate application-host compilation between
`apple/bin/build-ci.sh` and `apple/bin/test.sh all`.

## Clean-run compile counts and local wall time

These paired measurements used Xcode 26.6 (17F113) on arm64, with DerivedData
removed and SwiftPM clones cached. Compile units are the `SwiftCompile` and
`CompileC` tasks in non-quiet build logs. The heavily loaded local host (load
average 46–330) was not a GitHub-hosted runner, so these timings are not a
controlled runner benchmark.

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

## GitHub-hosted Xcode 26 runner wall time

The following complete Apple build/test jobs ran on GitHub's `macos-26-arm64`
image with Xcode 26.6 (17F113), clean DerivedData, and cached SwiftPM packages.
GitHub's timestamps have one-second resolution.

| Step | [Before](https://github.com/joeblau/made/actions/runs/36928564836/job/110591922182) | [After](https://github.com/joeblau/made/actions/runs/36931491398/job/110601649267) |
| --- | ---: | ---: |
| Compile every application | 12 m 9 s | 11 m 20 s |
| Run unit tests | 11 m 6 s | 6 m 49 s |
| Total | **23 m 15 s** | **18 m 9 s** |

The optimized runner job passed the complete build and hosted-test lane. Its
quiet CI logs do not contain per-compile-task records, so the runner runs
provide wall-time evidence while the local non-quiet runs provide compile
counts. Re-run the non-quiet measurement on the current supported toolchain
before using these historical numbers as a current performance baseline.
