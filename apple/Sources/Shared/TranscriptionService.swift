import Foundation
import Observation
import FluidAudio
@preconcurrency import AVFoundation

#if canImport(AVFAudio)
import AVFAudio
#endif

struct TranscriptionLoadedModel: Sendable {
    let models: AsrModels?
    let cacheEntry: SpeechModelCache.Entry
}

struct TranscriptionStreamUpdate: Sendable {
    let isRecording: Bool
    let confirmedText: String
    let partialText: String
}

struct TranscriptionStreamHandle: @unchecked Sendable {
    let run: @Sendable () async throws -> Void
    let stop: @Sendable () async -> Void
    /// Called after recording and its streaming decoder have both stopped.
    let finalize: @Sendable () async throws -> String?

    init(
        run: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async -> Void,
        finalize: @escaping @Sendable () async throws -> String? = { nil }
    ) {
        self.run = run
        self.stop = stop
        self.finalize = finalize
    }
}

private final class TranscriptionStreamUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: TranscriptionStreamUpdate?

    func store(_ update: TranscriptionStreamUpdate) {
        lock.withLock { latest = update }
    }

    var current: TranscriptionStreamUpdate? {
        lock.withLock { latest }
    }
}

private final class TranscriptionReadiness: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case ready
        case endedBeforeReady
        case failed(String)
        case cancelled
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            let resolved = lock.withLock { () -> Outcome? in
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let resolved { continuation.resume(returning: resolved) }
        }
    }

    func resolve(_ outcome: Outcome) {
        let continuation = lock.withLock { () -> CheckedContinuation<Outcome, Never>? in
            guard self.outcome == nil else { return nil }
            self.outcome = outcome
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: outcome)
    }

    var currentOutcome: Outcome? {
        lock.withLock { outcome }
    }
}

private final class TranscriptionStopRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () async -> Void)?
    private var completion: TranscriptionStopCompletion?

    func install(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock { self.operation = operation }
    }

    func stop() async {
        let request = lock.withLock { () -> (
            operation: (@Sendable () async -> Void)?,
            completion: TranscriptionStopCompletion?
        ) in
            if let completion { return (nil, completion) }
            guard let operation else { return (nil, nil) }
            let completion = TranscriptionStopCompletion()
            self.operation = nil
            self.completion = completion
            return (operation, completion)
        }

        if let operation = request.operation {
            await operation()
            request.completion?.resolve()
        } else {
            await request.completion?.wait()
        }
    }
}

private final class TranscriptionStopCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !isComplete else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func resolve() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isComplete else { return [] }
            isComplete = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

private enum TranscriptionServiceError: LocalizedError {
    case incompleteCache

    var errorDescription: String? {
        "The speech model cache is incomplete. Remove it and download the model again."
    }
}

@Observable
@MainActor
final class TranscriptionService: @unchecked Sendable {
    typealias ModelLoader = @Sendable (
        TranscriptionModelPreparation,
        @escaping @Sendable (Progress) -> Void
    ) async throws -> TranscriptionLoadedModel
    typealias StreamFactory = @MainActor @Sendable (
        TranscriptionLoadedModel,
        @escaping @Sendable (TranscriptionStreamUpdate) -> Void
    ) throws -> TranscriptionStreamHandle

    var partialText: String = ""
    var finalText: String = ""
    var isTranscribing: Bool = false
    var isModelLoaded: Bool = false
    var isModelLoading: Bool = false
    var modelLoadingProgress: String = ""
    var modelLoadingFraction: Double?
    var modelErrorMessage: String?

    private var loadedModel: TranscriptionLoadedModel?
    private var modelOperationTask: Task<TranscriptionLoadedModel, Error>?
    private var modelCompletionTask: Task<Bool, Never>?
    private var modelLoadGate = TranscriptionLoadGate()
    private var modelLoadGeneration = 0
    private var modelCancellationRequested = false
    private var modelCancellationMessage: String?

    private var streamStopRelay: TranscriptionStopRelay?
    private var streamTask: Task<Void, Never>?
    private var streamReadiness: TranscriptionReadiness?
    private var streamUpdates: TranscriptionStreamUpdates?
    private var streamFinalizer: (@Sendable () async throws -> String?)?
    private var transcriptionGeneration = 0
    private var streamStopCompletion: TranscriptionStopCompletion?
    private var audioSessionGeneration: Int?

    private var validatedCacheEntry: SpeechModelCache.Entry?
    private var cacheRefreshTask: Task<Void, Never>?
    private var cacheRefreshGeneration = 0

    private let modelCache: SpeechModelCache
    private let networkStatusProvider: @Sendable () -> TranscriptionNetworkStatus
    private let modelLoader: ModelLoader
    private let permissionRequest: @Sendable () async -> Bool
    private let streamFactory: StreamFactory
    private let activateAudioSession: @MainActor @Sendable () -> Void
    private let deactivateAudioSession: @MainActor @Sendable () -> Void

    init() {
        // Keep transcript-bearing SDK debug messages out of application logs.
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        let cache = SpeechModelCache()
        let networkObserver = TranscriptionNetworkObserver()
        modelCache = cache
        networkStatusProvider = { networkObserver.status }
        modelLoader = { preparation, progress in
            try await Self.loadParakeetModel(
                preparation: preparation,
                cache: cache,
                progress: progress
            )
        }
        permissionRequest = { await AVAudioApplication.requestRecordPermission() }
        streamFactory = Self.makeParakeetStream
        activateAudioSession = Self.activateRecordingAudioSession
        deactivateAudioSession = Self.deactivateRecordingAudioSession
        refreshCachedModelState()
    }

    init(
        testingCache: SpeechModelCache,
        networkStatus: TranscriptionNetworkStatus = .unmetered,
        modelLoader: @escaping ModelLoader,
        permissionRequest: @escaping @Sendable () async -> Bool,
        streamFactory: @escaping StreamFactory,
        activateAudioSession: @escaping @MainActor @Sendable () -> Void = {},
        deactivateAudioSession: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        modelCache = testingCache
        networkStatusProvider = { networkStatus }
        self.modelLoader = modelLoader
        self.permissionRequest = permissionRequest
        self.streamFactory = streamFactory
        self.activateAudioSession = activateAudioSession
        self.deactivateAudioSession = deactivateAudioSession
        refreshCachedModelState()
    }

    /// Memoized by `refreshCachedModelState()`. Validating the cache walks the
    /// model folder and parses its vocabulary, and the
    /// volume-hold gesture path reads these synchronously at gesture time.
    private(set) var hasCachedModel = false
    private(set) var hasStoredModel = false
    private(set) var cachedModelSize = "Not downloaded"

    var networkStatus: TranscriptionNetworkStatus { networkStatusProvider() }

    /// Revalidates the on-disk cache off the main actor and memoizes the
    /// result. Call after anything that can change the cached model on disk.
    private func refreshCachedModelState() {
        cacheRefreshGeneration += 1
        let generation = cacheRefreshGeneration
        let cache = modelCache
        cacheRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let entry = cache.validEntry
            let storedBytes = cache.storedBytes
            await self?.finishCacheRefresh(
                entry: entry,
                storedBytes: storedBytes,
                generation: generation
            )
        }
    }

    private func finishCacheRefresh(
        entry: SpeechModelCache.Entry?,
        storedBytes: Int64,
        generation: Int
    ) {
        guard generation == cacheRefreshGeneration else { return }
        validatedCacheEntry = entry
        hasCachedModel = entry != nil
        hasStoredModel = storedBytes > 0
        cachedModelSize = storedBytes > 0
            ? ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file)
            : "Not downloaded"
    }

    private func resolveCachedEntry() async -> SpeechModelCache.Entry? {
        if let task = cacheRefreshTask { await task.value }
        return validatedCacheEntry
    }

    @discardableResult
    func loadModel(allowRestrictedNetwork: Bool = false) async -> Bool {
        guard !isModelLoaded else { return true }
        if let existing = modelCompletionTask {
            return await waitForModelLoad(existing, generation: modelLoadGeneration)
        }
        // Resolve the memoized entry before taking the gate so this method
        // stays suspension-free between begin() and installing the completion
        // task, which concurrent callers join through `modelCompletionTask`.
        let cachedEntry = await resolveCachedEntry()
        guard !isModelLoaded else { return true }
        if let existing = modelCompletionTask {
            return await waitForModelLoad(existing, generation: modelLoadGeneration)
        }
        guard modelLoadGate.begin() else { return false }

        let preparation: TranscriptionModelPreparation
        do {
            preparation = try TranscriptionDownloadPolicy.preparation(
                cachedEntry: cachedEntry,
                network: networkStatusProvider(),
                allowRestrictedNetwork: allowRestrictedNetwork
            )
        } catch {
            modelLoadGate.finish()
            modelErrorMessage = error.localizedDescription
            return false
        }

        isModelLoading = true
        modelErrorMessage = nil
        modelLoadingProgress = preparation.isCached
            ? "Loading cached speech model…"
            : "Preparing speech model download…"
        modelLoadingFraction = preparation.isCached ? nil : 0
        modelLoadGeneration += 1
        modelCancellationRequested = false
        modelCancellationMessage = nil
        let generation = modelLoadGeneration

        let operation = Task { [weak self, modelLoader] in
            try await modelLoader(preparation) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateModelProgress(
                        progress,
                        generation: generation,
                        allowRestrictedNetwork: allowRestrictedNetwork
                    )
                }
            }
        }
        modelOperationTask = operation

        let completion = Task { [weak self] in
            let result: Result<TranscriptionLoadedModel, Error>
            do {
                result = .success(try await operation.value)
            } catch {
                result = .failure(error)
            }
            guard let self else { return false }
            return self.finishModelLoad(result, generation: generation)
        }
        modelCompletionTask = completion
        return await waitForModelLoad(completion, generation: generation)
    }

    private func waitForModelLoad(_ task: Task<Bool, Never>, generation: Int) async -> Bool {
        await withTaskCancellationHandler {
            let succeeded = await task.value
            return !Task.isCancelled && succeeded
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.requestModelCancellation(
                    generation: generation,
                    message: "Speech model download was cancelled. You can retry when ready."
                )
            }
        }
    }

    private func finishModelLoad(
        _ result: Result<TranscriptionLoadedModel, Error>,
        generation: Int
    ) -> Bool {
        guard generation == modelLoadGeneration else { return false }
        defer {
            modelOperationTask = nil
            modelCompletionTask = nil
            modelLoadGate.finish()
            isModelLoading = false
            modelLoadingProgress = ""
            modelLoadingFraction = nil
            modelCancellationRequested = false
            modelCancellationMessage = nil
            // Include partial downloads in storage controls after failure/cancellation.
            refreshCachedModelState()
        }

        if modelCancellationRequested {
            modelErrorMessage = modelCancellationMessage
                ?? "Speech model download was cancelled. You can retry when ready."
            return false
        }

        switch result {
        case .success(let loaded):
            guard modelCache.isComplete(loaded.cacheEntry) else {
                modelErrorMessage = TranscriptionServiceError.incompleteCache.localizedDescription
                // The memoized entry failed deep validation: drop it
                // synchronously so a volume hold that lands before the
                // detached re-walk finishes re-confirms with the user
                // instead of silently starting the download.
                validatedCacheEntry = nil
                hasCachedModel = false
                return false
            }
            loadedModel = loaded
            isModelLoaded = true
            validatedCacheEntry = loaded.cacheEntry
            hasCachedModel = true
            hasStoredModel = true
            if cachedModelSize == "Not downloaded" {
                // A just-loaded model has a size on disk; show a provisional
                // value so an open storage sheet never renders
                // "Not downloaded" beside an enabled Remove button while the
                // detached re-walk formats the real size.
                cachedModelSize = "Calculating…"
            }
            return true
        case .failure(let error):
            if error is CancellationError {
                modelErrorMessage = modelCancellationMessage
                    ?? "Speech model download was cancelled. You can retry when ready."
            } else {
                modelErrorMessage = "Speech model load failed: \(error.localizedDescription)"
                if error is TranscriptionServiceError {
                    // Same as the incomplete-cache guard above: drop the
                    // memoized readiness synchronously so the gesture gate
                    // cannot see stale `hasCachedModel == true` during the
                    // background re-walk.
                    validatedCacheEntry = nil
                    hasCachedModel = false
                }
            }
            return false
        }
    }

    private func updateModelProgress(
        _ progress: Progress,
        generation: Int,
        allowRestrictedNetwork: Bool
    ) {
        guard generation == modelLoadGeneration, !modelCancellationRequested else { return }
        if !allowRestrictedNetwork,
           [.offline, .expensive, .constrained].contains(networkStatusProvider()) {
            requestModelCancellation(
                generation: generation,
                message: "The speech-model download stopped because the network became unavailable or restricted. Connect to Wi-Fi or choose Use Cellular to retry."
            )
            return
        }
        let fraction = progress.fractionCompleted
        modelLoadingFraction = fraction.isFinite ? min(max(fraction, 0), 1) : nil
        modelLoadingProgress = fraction.isFinite && fraction > 0
            ? "Downloading speech model… \(Int(fraction * 100))%"
            : "Downloading speech model (about 630 MB)…"
    }

    func cancelModelLoad(message: String = "Speech model download was cancelled.") {
        requestModelCancellation(generation: modelLoadGeneration, message: message)
    }

    private func requestModelCancellation(generation: Int, message: String) {
        guard generation == modelLoadGeneration,
              modelCompletionTask != nil,
              !modelCancellationRequested else { return }
        modelCancellationRequested = true
        modelCancellationMessage = message
        modelLoadingProgress = "Cancelling speech-model load…"
        modelLoadingFraction = nil
        modelOperationTask?.cancel()
    }

    @discardableResult
    func start(allowRestrictedNetwork: Bool = false) async -> Bool {
        guard streamStopCompletion == nil else { return false }
        guard !isTranscribing else { return true }
        guard streamTask == nil else { return false }
        transcriptionGeneration += 1
        let generation = transcriptionGeneration

        // Clear the previous cycle's transcript up front. When this happens
        // after a model load or a permission prompt, a failed start leaves
        // `combinedText` holding the last recording — and a walkie-talkie
        // release would re-send that stale text to the terminal.
        partialText = ""
        finalText = ""
        modelErrorMessage = nil

        if !isModelLoaded {
            guard await loadModel(allowRestrictedNetwork: allowRestrictedNetwork) else { return false }
        }
        guard generation == transcriptionGeneration,
              !Task.isCancelled,
              let loadedModel else { return false }

        guard await permissionRequest() else {
            guard generation == transcriptionGeneration else { return false }
            modelErrorMessage = "Microphone access was not granted. Enable microphone access in Settings and retry."
            return false
        }
        guard generation == transcriptionGeneration, !Task.isCancelled else { return false }

        activateAudioSession()
        audioSessionGeneration = generation

        let readiness = TranscriptionReadiness()
        let stopRelay = TranscriptionStopRelay()
        let updates = TranscriptionStreamUpdates()
        let update: @Sendable (TranscriptionStreamUpdate) -> Void = { [weak self] update in
            // Retain callbacks synchronously: releasing the button may reach
            // the main actor before the callback's UI update does.
            updates.store(update)
            if update.isRecording { readiness.resolve(.ready) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.transcriptionGeneration else {
                    if update.isRecording { await stopRelay.stop() }
                    return
                }
                if let latest = updates.current {
                    self.finalText = latest.confirmedText
                    self.partialText = latest.partialText
                }
            }
        }

        let handle: TranscriptionStreamHandle
        do {
            handle = try streamFactory(loadedModel, update)
        } catch {
            modelErrorMessage = "Could not prepare transcription: \(error.localizedDescription)"
            deactivateAudioSessionIfOwned(by: generation)
            return false
        }
        stopRelay.install(handle.stop)
        streamStopRelay = stopRelay
        streamReadiness = readiness
        streamUpdates = updates
        streamFinalizer = handle.finalize

        let task = Task { [weak self] in
            do {
                try await handle.run()
                readiness.resolve(.endedBeforeReady)
                self?.streamDidEnd(generation: generation, readiness: readiness, error: nil)
            } catch is CancellationError {
                readiness.resolve(.cancelled)
                self?.streamDidEnd(generation: generation, readiness: readiness, error: nil)
            } catch {
                readiness.resolve(.failed(error.localizedDescription))
                self?.streamDidEnd(generation: generation, readiness: readiness, error: error)
            }
        }
        streamTask = task

        let outcome = await withTaskCancellationHandler {
            await readiness.wait()
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.stopStreamIfCurrent(generation: generation)
            }
        }

        switch outcome {
        case .ready:
            guard generation == transcriptionGeneration,
                  streamReadiness === readiness,
                  streamTask != nil else { return false }
            isTranscribing = true
            return true
        case .endedBeforeReady:
            if generation == transcriptionGeneration, modelErrorMessage == nil {
                modelErrorMessage = "Could not start transcription because microphone recording did not become ready."
            }
            return false
        case .failed(let message):
            if generation == transcriptionGeneration {
                modelErrorMessage = "Could not start transcription: \(message)"
            }
            return false
        case .cancelled:
            return false
        }
    }

    private func streamDidEnd(
        generation: Int,
        readiness: TranscriptionReadiness,
        error: Error?
    ) {
        guard generation == transcriptionGeneration, streamReadiness === readiness else { return }
        let wasReady = readiness.currentOutcome == .ready
        // Only an explicit stop may finalize a recording. An unexpected exit
        // leaves an incomplete preview that must never become a command; also
        // invalidate callbacks already queued by the failed decoder.
        transcriptionGeneration += 1
        finalText = ""
        partialText = ""
        streamStopRelay = nil
        streamTask = nil
        streamReadiness = nil
        streamUpdates = nil
        streamFinalizer = nil
        isTranscribing = false
        deactivateAudioSessionIfOwned(by: generation)
        if let error {
            modelErrorMessage = wasReady
                ? "Transcription stopped: \(error.localizedDescription)"
                : "Could not start transcription: \(error.localizedDescription)"
        } else if wasReady {
            modelErrorMessage = "Transcription stopped unexpectedly."
        } else {
            modelErrorMessage = "Could not start transcription because microphone recording did not become ready."
        }
    }

    private func stopStreamIfCurrent(generation: Int) async {
        guard generation == transcriptionGeneration else { return }
        await stop()
    }

    func removeCachedModel() async {
        await stop()
        loadedModel = nil
        isModelLoaded = false
        // Invalidate any in-flight revalidation so it cannot resurrect the
        // entry after the files are gone.
        cacheRefreshGeneration += 1
        cacheRefreshTask?.cancel()
        cacheRefreshTask = nil
        do {
            try modelCache.remove()
            modelErrorMessage = nil
            finishCacheRefresh(entry: nil, storedBytes: 0, generation: cacheRefreshGeneration)
        } catch {
            modelErrorMessage = "Could not remove the speech model: \(error.localizedDescription)"
            // Removal may have partially succeeded; recompute from disk.
            refreshCachedModelState()
        }
    }

    func stop() async {
        if let streamStopCompletion {
            await streamStopCompletion.wait()
            return
        }
        let completion = TranscriptionStopCompletion()
        streamStopCompletion = completion
        let stoppedGeneration = transcriptionGeneration
        transcriptionGeneration += 1
        let stopGeneration = transcriptionGeneration
        isTranscribing = false

        if modelCompletionTask != nil {
            cancelModelLoad()
            if let completion = modelCompletionTask { _ = await completion.value }
        }

        let readiness = streamReadiness
        let stopRelay = streamStopRelay
        let task = streamTask
        let updates = streamUpdates
        let finalizer = streamFinalizer
        let wasReady = readiness?.currentOutcome == .ready
        streamReadiness = nil
        streamStopRelay = nil
        streamTask = nil
        streamUpdates = nil
        streamFinalizer = nil
        readiness?.resolve(.cancelled)
        task?.cancel()
        await stopRelay?.stop()
        if let task { await task.value }
        if wasReady {
            if let latest = updates?.current {
                finalText = latest.confirmedText
                partialText = latest.partialText
            }
            do {
                if let text = try await finalizer?() {
                    finalText = text
                    partialText = ""
                }
            } catch {
                // An incomplete command must not be sent or executed when
                // the final decode fails.
                finalText = ""
                partialText = ""
                modelErrorMessage = "Could not finish transcription: \(error.localizedDescription)"
            }
        }
        if stopGeneration == transcriptionGeneration {
            deactivateAudioSessionIfOwned(by: stoppedGeneration)
        }
        if streamStopCompletion === completion {
            streamStopCompletion = nil
        }
        completion.resolve()
    }

    private func deactivateAudioSessionIfOwned(by generation: Int) {
        guard audioSessionGeneration == generation else { return }
        audioSessionGeneration = nil
        deactivateAudioSession()
    }

    /// Returns the best-effort full transcript captured during the most
    /// recent `start()/stop()` cycle. Call after `stop()` returns.
    var combinedText: String {
        [finalText, partialText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func loadParakeetModel(
        preparation: TranscriptionModelPreparation,
        cache: SpeechModelCache,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> TranscriptionLoadedModel {
        let entry: SpeechModelCache.Entry
        switch preparation {
        case .loadCached(let cached):
            entry = cached
        case .download:
            try await ModelHub.download(
                .parakeetUltra,
                to: cache.modelFolder.deletingLastPathComponent(),
                progressHandler: { update in
                    let value = Progress(totalUnitCount: 1000)
                    // ModelHub reserves half its progress range for subsequent
                    // model loading. This call downloads only compiled components.
                    value.completedUnitCount = Int64(min(max(update.fractionCompleted * 2, 0), 1) * 1000)
                    progress(value)
                }
            )
            entry = SpeechModelCache.Entry(modelFolder: cache.modelFolder)
        }
        try Task.checkCancellation()
        guard cache.isComplete(entry) else { throw TranscriptionServiceError.incompleteCache }
        // loadLocal fails locally for damaged files and never falls back to a download.
        // Core ML compilation/loading is kept off the main actor.
        let models = try await Task.detached(priority: .userInitiated) {
            try AsrModels.loadLocal(from: entry.modelFolder, version: .ultra)
        }.value
        try Task.checkCancellation()
        return TranscriptionLoadedModel(models: models, cacheEntry: entry)
    }

    private static func makeParakeetStream(
        loaded: TranscriptionLoadedModel,
        update: @escaping @Sendable (TranscriptionStreamUpdate) -> Void
    ) throws -> TranscriptionStreamHandle {
        guard let models = loaded.models else { throw TranscriptionServiceError.incompleteCache }
        let microphone = ParakeetMicrophone(models: models, update: update)
        return TranscriptionStreamHandle(
            run: { try await microphone.run() },
            stop: { await microphone.stop() },
            finalize: { try await microphone.finalize() }
        )
    }

    // MARK: - AVAudioSession (iOS only)

    private static func activateRecordingAudioSession() {
        #if canImport(AVFAudio) && os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Keep an output route while recording. Walkie's volume-button hold
        // detector observes outputVolume auto-repeat to know that the button
        // remains down; a record-only category makes that signal disappear.
        try? session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try? session.setActive(true)
        #endif
    }

    private static func deactivateRecordingAudioSession() {
        #if canImport(AVFAudio) && os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }
}

private extension TranscriptionModelPreparation {
    var isCached: Bool {
        if case .loadCached = self { return true }
        return false
    }
}

/// Owns one recording. A new sliding-window decoder is created per hold because
/// FluidAudio's input stream is closed permanently by finish().
@MainActor
private final class ParakeetMicrophone {
    private let update: @Sendable (TranscriptionStreamUpdate) -> Void
    private let session: ParakeetTranscriptionSession
    private let engine = AVAudioEngine()
    private var input: AsyncThrowingStream<TranscriptionAudioBuffer, Error>.Continuation?
    private var forwardingTask: Task<Void, Error>?
    private var updatesTask: Task<Void, Never>?
    private var hasTap = false
    private var isStopped = false
    private var captureError: Error?

    init(models: AsrModels, update: @escaping @Sendable (TranscriptionStreamUpdate) -> Void) {
        session = ParakeetTranscriptionSession(models: models)
        self.update = update
    }

    func run() async throws {
        do {
            try Task.checkCancellation()
            try await session.start()
            let updates = await session.transcriptionUpdates
            try Task.checkCancellation()
            guard !isStopped else { throw CancellationError() }
            updatesTask = Task { [session, update] in
                for await _ in updates {
                    guard !Task.isCancelled else { break }
                    update(TranscriptionStreamUpdate(
                        isRecording: false,
                        confirmedText: "",
                        partialText: await session.currentText
                    ))
                }
            }

            let (buffers, continuation) = AsyncThrowingStream<TranscriptionAudioBuffer, Error>.makeStream()
            input = continuation
            forwardingTask = Task { [session] in
                // This task is drained, not cancelled, on release. Every captured
                // buffer must reach the decoder before finish() flushes the tail.
                for try await buffer in buffers { try await session.append(buffer) }
            }
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw ParakeetMicrophoneError.invalidInputFormat
            }
            node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                guard buffer.frameLength > 0 else { return }
                // AVAudioEngine reuses tap memory after this callback returns.
                guard let copy = copyTranscriptionBuffer(buffer) else {
                    continuation.finish(throwing: ParakeetMicrophoneError.bufferCopyFailed)
                    return
                }
                continuation.yield(TranscriptionAudioBuffer(pcm: copy))
            }
            hasTap = true
            engine.prepare()
            try engine.start()
            // Readiness is published only after the microphone actually starts.
            update(TranscriptionStreamUpdate(isRecording: true, confirmedText: "", partialText: ""))
            try await forwardingTask?.value
        } catch {
            captureError = error
            await stop()
            await session.cancel()
            throw error
        }
    }

    func stop() async {
        isStopped = true
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        input?.finish()
        input = nil
        _ = try? await forwardingTask?.value
        forwardingTask = nil
        updatesTask?.cancel()
        await updatesTask?.value
        updatesTask = nil
    }

    func finalize() async throws -> String {
        do {
            if let captureError { throw captureError }
            return try await session.finish()
        } catch {
            await session.cancel()
            throw error
        }
    }
}

private enum ParakeetMicrophoneError: LocalizedError {
    case invalidInputFormat
    case bufferCopyFailed

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat: "The microphone has no available audio input."
        case .bufferCopyFailed: "Could not retain the microphone audio for transcription."
        }
    }
}

/// Returns owned PCM storage so asynchronous decoding never reads reused tap memory.
nonisolated func copyTranscriptionBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (input, output) in zip(source, destination) {
        guard let from = input.mData, let to = output.mData else { return nil }
        memcpy(to, from, Int(input.mDataByteSize))
    }
    return copy
}
