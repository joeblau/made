# Parakeet v3 Ultra in Walkie

Walkie uses Moondream Parakeet Ultra, the post-trained NVIDIA Parakeet TDT
0.6B v3 model, through FluidAudio 0.17.7. The exact runtime selection is
`AsrModelVersion.ultra`, with weights from
[FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml).
The model supports the same 25 languages as v3; transcription uses automatic
language recognition instead of Whisper's previous English-only setting.

## Download and storage

The first use requires an approximately **630 MB** download, confirmed in the
existing Wi-Fi/cellular consent flow. Audio stays on the iPhone. Cached startup
uses `AsrModels.loadLocal(from:version:)`, which never downloads missing files.

The cache is `Documents/speech-models/parakeet-ultra-coreml`. Readiness requires
all four compiled components (`Preprocessor`, `Encoder`, `Decoder`, and
`JointDecisionv3`) with nonempty model metadata, MIL and weights, plus all 8192
vocabulary entries. Core ML validates the actual models when loading them.
Partial downloads remain visible and removable in Speech Storage.

Existing Whisper downloads cannot be reused and remain untouched. The separate
cache prevents an old Whisper installation from bypassing the new download
confirmation. The old Whisper benchmark harness is retained as historical tooling.

## Recording behavior

Each hold creates a new `ParakeetTranscriptionSession` with the already loaded
Ultra models. Its sliding-window preview uses a 1-second step, 12 seconds of left
context, and 250 ms of right context. In FluidAudio 0.17.7, changing
`hypothesisChunkSeconds` alone does not produce faster updates; `chunkSeconds +
rightContextSeconds` determines when the first window can be decoded.

The audio tap copies buffers before passing them to the session. Readiness is
reported only after `AVAudioEngine.start()` succeeds. Walkie displays and
revises the current hypothesis during recording, scrolls to the newest words,
and retains the preview while finishing. Preparing a new recording hides stale
text from the previous hold.

The session also writes the captured audio to a temporary local CAF file. After
release, it drains the preview and runs a separate disk-backed final decode of
the complete recording. This restores context and punctuation lost by the short
preview windows. Only that final result is eligible for delivery and execution;
preview changes are never sent as terminal input. The temporary file is deleted
after finalization, cancellation, or failure. Audio remains on the iPhone.

Overlapping starts, permission cancellation and reliable message delivery retain
their existing gates. SDK debug logging of transcript contents is disabled.

## Validation (2026-10-24)

- Walkie's sources compile for the iOS simulator with FluidAudio 0.17.7.
- 49 tests pass across `TranscriptionLifecycleTests` and `CopilotWalkieTalkieTests`,
  including cache isolation, incomplete bundles, buffer ownership, cancellation,
  finalization, live revisions, stale-preview suppression and reliable delivery.
- A macOS smoke run loaded the actual Ultra weights with network access disabled
  in FluidAudio, then used the production session on generated audio paced at
  recording speed. The first live text appeared after about 1.35 seconds on this
  Mac, with updates roughly every second; this is not an iPhone latency guarantee.
  It recognized a 0.7-second “Ship it.” recording, a short dashboard/tests/git
  command, and a longer recording spanning multiple windows with its final words
  intact. One second of digital silence returned an empty transcript. Temporary
  recording directories were empty after every finalization and a cancelled hold.
- A simulator preview verified the transcript component renders live updates in
  its fixed-height display area.
- Simulator validation used an isolated Xcode project with the same Walkie sources
  and test files. The full repository build stopped during unrelated dependency
  resolution: a swift-jpeg revision fingerprint mismatch and GhosttyKit artifact
  mapping failure. Physical iPhone microphone, latency and memory testing remains
  to be done; the macOS smoke run does not establish device performance.

## Attribution

[Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) is by Moondream,
based on NVIDIA's Parakeet TDT 0.6B v3. Fluid Inference converted it to Core ML
and quantized the encoder. The weights use
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); model and license links
also appear in Walkie's Speech Storage screen.

The implementation follows the pinned
[FluidAudio Ultra documentation](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/ASR/ParakeetUltra.md).
