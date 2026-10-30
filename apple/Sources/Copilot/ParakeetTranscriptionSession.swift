import Foundation
import FluidAudio
@preconcurrency import AVFoundation

/// One hold-to-talk session. Fast, provisional windows drive the display; a
/// separate decode of the complete recording supplies the text sent to Cockpit.
actor ParakeetTranscriptionSession {
    // In FluidAudio 0.17.7, chunk + right context controls when updates arrive.
    // hypothesisChunkSeconds alone does not enable a second, faster decode loop.
    static let previewConfiguration = SlidingWindowAsrConfig(
        chunkSeconds: 1,
        hypothesisChunkSeconds: 1,
        leftContextSeconds: 12,
        rightContextSeconds: 0.25,
        minContextForConfirmation: 3,
        confirmationThreshold: 0.8
    )

    private let models: AsrModels
    private let preview = SlidingWindowAsrManager(config: previewConfiguration)
    private let recordingURL: URL
    private var recordingFile: AVAudioFile?
    private var recordedDuration: TimeInterval = 0

    init(models: AsrModels, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.models = models
        recordingURL = temporaryDirectory.appendingPathComponent("walkie-\(UUID().uuidString).caf")
    }

    deinit {
        try? FileManager.default.removeItem(at: recordingURL)
    }

    func start() async throws {
        try await preview.loadModels(models)
        try await preview.startStreaming()
    }

    var transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate> {
        get async { await preview.transcriptionUpdates }
    }

    var currentText: String {
        get async {
            let confirmed = await preview.confirmedTranscript
            let partial = await preview.volatileTranscript
            return [confirmed, partial].filter { !$0.isEmpty }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func append(_ audio: TranscriptionAudioBuffer) async throws {
        let buffer = audio.pcm
        guard buffer.frameLength > 0 else { return }
        if recordingFile == nil {
            recordingFile = try AVAudioFile(
                forWriting: recordingURL,
                settings: buffer.format.settings,
                commonFormat: buffer.format.commonFormat,
                interleaved: buffer.format.isInterleaved
            )
        }
        try recordingFile?.write(from: buffer)
        recordedDuration += Double(buffer.frameLength) / buffer.format.sampleRate
        await preview.streamAudio(buffer)
    }

    /// Called only after capture stops and all queued buffers have been appended.
    func finish() async throws -> String {
        recordingFile = nil
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        // Drain the preview before reusing the models. A preview failure does not
        // prevent a fresh final decode of the complete, successfully saved audio.
        _ = try? await preview.finish()
        await preview.cleanup()
        guard recordedDuration >= ASRConstants.minimumAudioDurationSeconds else { return "" }

        let finalDecoder = AsrManager()
        do {
            try await finalDecoder.loadModels(models)
            var state = TdtDecoderState.make(decoderLayers: models.version.decoderLayers)
            // Disk-backed decoding bounds memory even for a long hold. It also
            // gives short live windows their full context for final punctuation.
            let result = try await finalDecoder.transcribeDiskBacked(recordingURL, decoderState: &state)
            await finalDecoder.cleanup()
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await finalDecoder.cleanup()
            throw error
        }
    }

    func cancel() async {
        _ = try? await preview.finish()
        await preview.cleanup()
        recordingFile = nil
        try? FileManager.default.removeItem(at: recordingURL)
    }
}

/// The tap creates an independent copy and never mutates it after enqueueing.
/// The session reads/writes it before handing it to FluidAudio for decoding.
struct TranscriptionAudioBuffer: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
}
