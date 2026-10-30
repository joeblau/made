# WhisperKit 1.0 migration and benchmark report

Historical report: Walkie now uses [Parakeet v3 Ultra](parakeet-ultra-migration.md).
The Whisper benchmark tool and results below remain for comparison.

## Reviewed upstream changes

The reviewed target is the official `argmaxinc/argmax-oss-swift` `v1.0.0`
release from 2026-05-01. The package moved from
`argmaxinc/WhisperKit` to `argmaxinc/argmax-oss-swift`, adopted Swift 6
concurrency, vendored its Hub/tokenizer implementation, removed deprecated
APIs, renamed `supressTokens` to `suppressTokens`, and removed the separate
`TextDecoderContextPrefill` model and `DecodingOptions.usePrefillCache`.

Blau now resolves the new package at `1.0.0`, removes the deleted
`usePrefillCache` option, checks the optional tokenizer before constructing an
`AudioStreamTranscriber`, and keeps using the supported `WhisperKit`,
`WhisperKitConfig`, and streaming-transcriber APIs.

## Download and cache behavior

- A model transfer begins only after the user invokes transcription and then
  chooses a download action. Preparing the model does not pretend the original
  volume-button hold is still active; the user records with a fresh hold after
  preparation completes.
- The UI reports the approximate 150 MB size, byte progress, cancellation,
  retry, failures, stored size, and model removal.
- Expensive and constrained network paths are blocked unless the user chooses
  **Use Cellular**. Offline first-run preparation fails recoverably.
- Concurrent callers share one model task. Cached starts never start another
  download.
- Both SDK versions use
  `Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>`. Blau
  validates and adopts an existing 0.18 `openai_whisper-base` folder, so the
  migration does not require a second transfer. The cache tests cover this
  layout and incomplete-cache rejection.

## Reproducible benchmark harness and results

The migration was measured before and after on the same `Mac15,8`, macOS 27.0
(`26A5378j`), cached `openai_whisper-base` model, and three generated audio
fixtures. Both SDKs were built in debug mode and run after Core ML
specialization/cache warm-up. `First latency` is the end-to-end transcription
time for the first 1.32-second fixture, and command accuracy is `1 - mean WER`.

| Metric | WhisperKit 0.18.0 | Argmax OSS 1.0.0 |
| --- | ---: | ---: |
| Model load | 8.544 s | 8.190 s |
| First transcription | 0.1040 s | 0.0966 s |
| Mean real-time factor | 0.0637 | 0.0603 |
| Peak resident memory | 143,884,288 B | 143,409,152 B |
| Command accuracy | 88.89% | 88.89% |

Both versions recognized two phrases exactly and rendered `show git status` as
`Show Get Status`; the migration therefore preserved this fixture set's
accuracy while modestly improving the measured cached-load and inference
times. Full machine-readable reports are checked in as
[`whisperkit-0.18.0-macos.json`](benchmarks/whisperkit-0.18.0-macos.json) and
[`argmax-oss-swift-1.0.0-macos.json`](benchmarks/argmax-oss-swift-1.0.0-macos.json).

No physical supported iPhone is attached to the build environment, so these
are controlled macOS migration results rather than device-release numbers. The
checked-in harness records the same five metrics on release hardware without
inventing unavailable device measurements.

Create identical fixtures once (recorded human fixtures are preferable; these
macOS voices provide a reproducible smoke set):

```sh
mkdir -p /tmp/blau-whisper-cases
say -v Samantha -r 180 -o /tmp/blau-whisper-cases/open-dashboard.aiff "open the dashboard"
say -v Samantha -r 180 -o /tmp/blau-whisper-cases/run-tests.aiff "run the tests"
say -v Samantha -r 180 -o /tmp/blau-whisper-cases/show-status.aiff "show git status"
cp apple/Tools/WhisperBenchmark/cases.example.json /tmp/blau-whisper-cases/cases.json
sed -i '' 's#/absolute/path#/tmp/blau-whisper-cases#g' /tmp/blau-whisper-cases/cases.json
```

Run the candidate from `apple/Tools/WhisperBenchmark`. Passing `--download` is
explicit consent for the first-run model transfer; use `--model-folder` for the
cached run:

```sh
swift run WhisperBenchmark \
  --manifest /tmp/blau-whisper-cases/cases.json \
  --output /tmp/blau-whisper-cases/argmax-1.0-cold.json \
  --download

swift run WhisperBenchmark \
  --manifest /tmp/blau-whisper-cases/cases.json \
  --output /tmp/blau-whisper-cases/argmax-1.0-cached.json \
  --model-folder "$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base"
```

For the before/after report, run the same manifest on the same powered device,
OS, thermal state, and model folder after changing only the harness package URL
and exact version to `https://github.com/argmaxinc/WhisperKit.git` `0.18.0` on a
temporary baseline checkout. Keep the generated JSON reports as release
artifacts; do not compare numbers from different machines. On iPhone, repeat
the same command phrases in Copilot and capture model-load/first-result timings
with Instruments so Neural Engine behavior—not the macOS smoke harness—is the
release gate.

## Local verification record

- Package resolution: `argmax-oss-swift` `1.0.0` at tag commit
  `25c62997041c134b03ca82731ce2f6fd2cae1eb9`.
- The macOS benchmark harness builds locally without downloading a model.
- Copilot simulator build and SharedTests exercise compilation, consent policy,
  cached/offline startup planning, cache migration, cancellation state, and
  duplicate-load exclusion.
- Controlled same-machine before/after results are recorded above; physical-
  device latency, memory, RTF, and accuracy remain intentionally unreported
  until the harness is run on release hardware.
