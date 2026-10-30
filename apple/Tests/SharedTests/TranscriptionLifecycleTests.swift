import Foundation
@preconcurrency import AVFoundation
import Testing
@testable import Copilot

@Suite("Transcription model lifecycle", .serialized)
@MainActor
struct TranscriptionLifecycleTests {
    @Test("first run blocks offline and restricted transfers until explicit override")
    func firstRunNetworkPolicy() throws {
        #expect(throws: TranscriptionModelPreparationError.offline) {
            try TranscriptionDownloadPolicy.preparation(
                cachedEntry: nil,
                network: .offline,
                allowRestrictedNetwork: false
            )
        }
        #expect(throws: TranscriptionModelPreparationError.expensiveNetwork) {
            try TranscriptionDownloadPolicy.preparation(
                cachedEntry: nil,
                network: .expensive,
                allowRestrictedNetwork: false
            )
        }
        #expect(throws: TranscriptionModelPreparationError.constrainedNetwork) {
            try TranscriptionDownloadPolicy.preparation(
                cachedEntry: nil,
                network: .constrained,
                allowRestrictedNetwork: false
            )
        }
        #expect(try TranscriptionDownloadPolicy.preparation(
            cachedEntry: nil,
            network: .expensive,
            allowRestrictedNetwork: true
        ) == .download)
    }

    @Test("a complete cached model and vocabulary load while offline")
    func cachedStartupDoesNotRequireNetwork() throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let entry = try #require(fixture.cache.validEntry)
        #expect(try TranscriptionDownloadPolicy.preparation(
            cachedEntry: entry,
            network: .offline,
            allowRestrictedNetwork: false
        ) == .loadCached(entry))
    }

    @Test("Parakeet cache is isolated from an existing Whisper download")
    func legacyWhisperCacheIsNotReused() throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let legacy = fixture.documents.appendingPathComponent(
            "huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try Data([1]).write(to: legacy.appendingPathComponent("\(name).mlmodelc"))
        }
        try fixture.cache.remove()
        #expect(fixture.cache.validEntry == nil)
        #expect(!fixture.cache.isComplete(.init(modelFolder: legacy)))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("cancelled downloads release the single-flight gate for an explicit retry")
    func duplicateLoadGate() {
        var gate = TranscriptionLoadGate()
        let first = gate.begin()
        let duplicate = gate.begin()
        #expect(first)
        #expect(!duplicate)
        gate.cancel()
        let retry = gate.begin()
        #expect(retry)
    }

    @Test("a complete Ultra cache includes all four models and the v3 vocabulary")
    func completeParakeetCache() throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }

        #expect(fixture.cache.validEntry == SpeechModelCache.Entry(
            modelFolder: fixture.model
        ))
        #expect(fixture.cache.storedBytes > 3)
    }

    @Test("missing or corrupt vocabulary JSON invalidates an otherwise complete model")
    func vocabularyValidity() throws {
        let missing = try ModelCacheFixture(includeVocabulary: false)
        defer { missing.remove() }
        #expect(missing.cache.validEntry == nil)

        let corrupt = try ModelCacheFixture(corruptVocabulary: true)
        defer { corrupt.remove() }
        #expect(corrupt.cache.validEntry == nil)
    }

    @Test("removing a cached model removes Core ML components and vocabulary")
    func removeCompleteCache() throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        _ = fixture.cache.validEntry
        try fixture.cache.remove()
        #expect(!FileManager.default.fileExists(atPath: fixture.model.path))
        #expect(fixture.cache.validEntry == nil)
    }

    @Test("incomplete CoreML caches never masquerade as ready")
    func incompleteModelCache() throws {
        let fixture = try ModelCacheFixture(includeDecoder: false)
        defer { fixture.remove() }
        #expect(fixture.cache.validEntry == nil)

        try fixture.writeComponent("Decoder")
        #expect(fixture.cache.validEntry != nil)
    }

    @Test("empty Core ML bundles and missing weights are rejected and removable")
    func incompleteBundlesAreNotReady() throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let weights = fixture.model.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")
        try Data().write(to: weights)
        #expect(fixture.cache.validEntry == nil)
        #expect(fixture.cache.storedBytes > 0)
        try FileManager.default.removeItem(at: weights)
        #expect(fixture.cache.validEntry == nil)
        try fixture.cache.remove()
        #expect(fixture.cache.storedBytes == 0)
    }

    @Test("partial downloads remain visible and removable after a failed load")
    func partialDownloadStorageState() async throws {
        let fixture = try ModelCacheFixture(includeDecoder: false)
        defer { fixture.remove() }
        let service = TranscriptionService(
            testingCache: fixture.cache,
            modelLoader: { _, _ in throw TestFailure.unexpectedDownload },
            permissionRequest: { false },
            streamFactory: { _, _ in throw TestFailure.unexpectedDownload }
        )
        await waitUntil { service.hasStoredModel }
        #expect(!service.hasCachedModel)
        #expect(!(await service.loadModel()))
        #expect(service.hasStoredModel)
        #expect(service.cachedModelSize != "Not downloaded")
        await service.removeCachedModel()
        #expect(!service.hasStoredModel)
        #expect(service.cachedModelSize == "Not downloaded")
    }

    @Test("audio handed to the decoder owns its samples after the tap is reused")
    func microphoneBufferOwnership() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let original = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        original.frameLength = 4
        for channel in 0..<2 {
            for frame in 0..<4 { original.floatChannelData![channel][frame] = Float(channel * 4 + frame) }
        }
        let copy = try #require(copyTranscriptionBuffer(original))
        original.floatChannelData![0][0] = 99
        original.floatChannelData![1][3] = 99
        #expect(copy.frameLength == 4)
        #expect(copy.format == format)
        #expect(copy.floatChannelData![0][0] == 0)
        #expect(copy.floatChannelData![1][3] == 7)
    }

    @Test("service model loading is single-flight for concurrent callers")
    func serviceModelLoadIsSingleFlight() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let entry = try #require(fixture.cache.validEntry)
        let loader = ControlledModelLoader(entry: entry)
        let service = makeService(fixture: fixture, loader: loader)

        let first = Task { await service.loadModel() }
        let second = Task { await service.loadModel() }
        await loader.waitForLoadCount(1)
        #expect(await loader.loadCount == 1)
        await loader.releaseNext()

        #expect(await first.value)
        #expect(await second.value)
        #expect(service.isModelLoaded)
        #expect(!service.isModelLoading)
    }

    @Test("caller cancellation owns cleanup and blocks retry overlap")
    func serviceModelLoadCancellation() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let entry = try #require(fixture.cache.validEntry)
        let loader = ControlledModelLoader(entry: entry)
        let service = makeService(fixture: fixture, loader: loader)

        let first = Task { await service.loadModel() }
        await loader.waitForLoadCount(1)
        first.cancel()
        await waitUntil { service.modelLoadingProgress.contains("Cancelling") }

        let overlappingRetry = Task { await service.loadModel() }
        await Task.yield()
        #expect(await loader.loadCount == 1)
        #expect(service.isModelLoading)

        await loader.releaseNext()
        #expect(!(await first.value))
        #expect(!(await overlappingRetry.value))
        #expect(!service.isModelLoading)
        #expect(!service.isModelLoaded)

        let retry = Task { await service.loadModel() }
        await loader.waitForLoadCount(2)
        #expect(await loader.loadCount == 2)
        await loader.releaseNext()
        #expect(await retry.value)
        #expect(service.isModelLoaded)
    }

    @Test("start returns only after the owned stream reports recording ready")
    func recordingReadinessAndStop() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .readyUntilStopped)
        let service = makeService(fixture: fixture, stream: stream)

        #expect(await service.start())
        #expect(service.isTranscribing)
        #expect(stream.runCount == 1)

        await service.stop()
        #expect(!service.isTranscribing)
        #expect(stream.stopCount == 1)
    }

    @Test("live hypotheses replace displayed text before release and cannot overwrite final text")
    func liveHypothesesUpdateDuringRecording() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let updates = UpdateBox()
        let service = makeService(fixture: fixture, updates: updates, finalize: { "git status --short" })
        #expect(await service.start())
        let publish = try #require(updates.update)
        publish(TranscriptionStreamUpdate(isRecording: false, confirmedText: "", partialText: "git stash"))
        await waitUntil { service.combinedText == "git stash" }
        #expect(service.isTranscribing)
        publish(TranscriptionStreamUpdate(isRecording: false, confirmedText: "", partialText: "git status"))
        await waitUntil { service.combinedText == "git status" }
        #expect(service.isTranscribing)

        await service.stop()
        #expect(service.combinedText == "git status --short")
        publish(TranscriptionStreamUpdate(isRecording: false, confirmedText: "", partialText: "late preview"))
        await Task.yield()
        #expect(service.combinedText == "git status --short")
        #expect(!service.isTranscribing)
    }

    @Test("release retains transcript callbacks still waiting to update the UI")
    func releaseRetainsQueuedTranscript() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let updates = UpdateBox()
        let service = makeService(fixture: fixture, updates: updates)

        #expect(await service.start())
        updates.update?(TranscriptionStreamUpdate(
            isRecording: true,
            confirmedText: "run the",
            partialText: "tests"
        ))
        // Deliberately do not yield to the callback's main-actor task.
        await service.stop()
        #expect(service.combinedText == "run the tests")
    }

    @Test("release decodes short recordings even before a streaming transcript exists")
    func releaseFinalizesShortRecording() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .readyUntilStopped)
        let service = makeService(fixture: fixture, stream: stream, finalize: {
            #expect(stream.stopCount == 1)
            #expect(stream.hasFinishedRunning)
            return "ship it"
        })

        #expect(await service.start())
        #expect(service.combinedText.isEmpty)
        await service.stop()
        #expect(service.combinedText == "ship it")
        #expect(service.partialText.isEmpty)
        #expect(service.modelErrorMessage == nil)
    }

    @Test("release waits for final words and prevents overlapping recording or stop")
    func releaseWaitsForFinalDecode() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let updates = UpdateBox()
        let finalizer = ControlledFinalizer()
        let service = makeService(
            fixture: fixture,
            updates: updates,
            finalize: { await finalizer.finish() }
        )

        #expect(await service.start())
        updates.update?(TranscriptionStreamUpdate(
            isRecording: true,
            confirmedText: "run the",
            partialText: "unit"
        ))
        let stopProbe = ControlledCallProbe()
        let stop = Task {
            await service.stop()
            stopProbe.markReturned()
        }
        await finalizer.waitUntilRequested()
        #expect(!stopProbe.didReturn)
        #expect(!(await service.start()))
        #expect(service.combinedText == "run the unit")

        let secondStopEntered = ControlledSignal()
        let secondStopProbe = ControlledCallProbe()
        let secondStop = Task {
            secondStopEntered.signal()
            await service.stop()
            secondStopProbe.markReturned()
        }
        await secondStopEntered.wait()
        #expect(!secondStopProbe.didReturn)
        #expect(await finalizer.callCount == 1)

        // A late preview must not overwrite the final decoder's result.
        updates.update?(TranscriptionStreamUpdate(
            isRecording: false,
            confirmedText: "run the",
            partialText: "unit tes"
        ))
        await finalizer.resolve("run the unit tests")
        await stop.value
        await secondStop.value
        #expect(service.combinedText == "run the unit tests")
        #expect(service.partialText.isEmpty)
        #expect(secondStopProbe.didReturn)
        #expect(await finalizer.callCount == 1)
    }

    @Test("failed final decoding cannot send an incomplete command")
    func finalDecodeFailureClearsIncompleteCommand() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let updates = UpdateBox()
        let service = makeService(fixture: fixture, updates: updates, finalize: {
            throw TestFailure.finalDecodeFailed
        })

        #expect(await service.start())
        updates.update?(TranscriptionStreamUpdate(
            isRecording: true,
            confirmedText: "remove the",
            partialText: ""
        ))
        await service.stop()
        #expect(service.combinedText.isEmpty)
        #expect(service.modelErrorMessage?.contains("Could not finish transcription") == true)
    }

    @Test("unexpected stream exits discard incomplete commands", arguments: [false, true])
    func unexpectedStreamExitClearsIncompleteCommand(throwsError: Bool) async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .readyUntilStopped)
        let updates = UpdateBox()
        let service = makeService(fixture: fixture, stream: stream, updates: updates, finalize: {
            Issue.record("A failed stream must not finalize an incomplete recording")
            return "incomplete command"
        })

        #expect(await service.start())
        updates.update?(TranscriptionStreamUpdate(
            isRecording: true,
            confirmedText: "remove the",
            partialText: ""
        ))
        await waitUntil { service.combinedText == "remove the" }
        stream.endUnexpectedly(throwsError: throwsError)
        await waitUntil { service.modelErrorMessage != nil }
        #expect(!service.isTranscribing)
        #expect(service.combinedText.isEmpty)

        // A callback that was still in flight cannot restore the failed
        // recording's preview when its button is subsequently released.
        updates.update?(TranscriptionStreamUpdate(
            isRecording: false,
            confirmedText: "remove the",
            partialText: "old"
        ))
        await service.stop()
        #expect(service.combinedText.isEmpty)
        #expect(service.modelErrorMessage?.contains("Transcription stopped") == true)
    }

    @Test("releasing before microphone readiness never finalizes old audio")
    func releaseBeforeReadinessSkipsFinalDecode() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .waitWithoutReadiness)
        let service = makeService(fixture: fixture, stream: stream, finalize: {
            Issue.record("An unstarted recording must not finalize a previous audio buffer")
            return "stale audio"
        })

        let start = Task { await service.start() }
        await stream.waitUntilRunning()
        await service.stop()
        #expect(!(await start.value))
        #expect(service.combinedText.isEmpty)
    }

    @Test("denied microphone permission never starts a stream")
    func deniedMicrophonePermission() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .readyUntilStopped)
        let service = makeService(fixture: fixture, permission: { false }, stream: stream)

        #expect(!(await service.start()))
        #expect(!service.isTranscribing)
        #expect(stream.runCount == 0)
        #expect(service.modelErrorMessage?.contains("Microphone access") == true)
    }

    @Test("a normally returning stream is not mistaken for readiness")
    func streamReturnBeforeReadiness() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .returnBeforeReady)
        let service = makeService(fixture: fixture, stream: stream)

        #expect(!(await service.start()))
        #expect(!service.isTranscribing)
        #expect(service.modelErrorMessage?.contains("did not become ready") == true)
    }

    @Test("stopping while permission is pending prevents a late stream start")
    func earlyStopDuringPermission() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let permission = ControlledPermission()
        let stream = ControlledStream(behavior: .readyUntilStopped)
        let service = makeService(
            fixture: fixture,
            permission: { await permission.request() },
            stream: stream
        )

        let start = Task { await service.start() }
        await permission.waitUntilRequested()
        await service.stop()
        await permission.resolve(true)

        #expect(!(await start.value))
        #expect(stream.runCount == 0)
        #expect(!service.isTranscribing)
    }

    @Test("stopping before the stream readiness callback cancels the owned stream")
    func earlyStopDuringStreamStart() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .waitWithoutReadiness)
        let service = makeService(fixture: fixture, stream: stream)

        let start = Task { await service.start() }
        await stream.waitUntilRunning()
        await service.stop()

        #expect(!(await start.value))
        #expect(stream.stopCount == 1)
        #expect(!service.isTranscribing)
    }

    @Test("start fails and concurrent stop waits while teardown is owned")
    func startDuringStopDoesNotOverlapReplacement() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let audioSession = ControlledAudioSession()
        let stream = ControlledStream(behavior: .readyUntilStopped, blocksStop: true)
        let service = makeService(fixture: fixture, stream: stream, audioSession: audioSession)

        #expect(await service.start())
        #expect(service.isTranscribing)
        #expect(audioSession.activationCount == 1)

        let stop = Task { await service.stop() }
        await stream.waitUntilStopRequested()
        #expect(!service.isTranscribing)

        let overlappingStart = await service.start()
        #expect(!overlappingStart)
        #expect(stream.runCount == 1)
        #expect(stream.stopCount == 1)
        #expect(audioSession.activationCount == 1)
        #expect(audioSession.deactivationCount == 0)

        let secondStopEntered = ControlledSignal()
        let secondStopProbe = ControlledCallProbe()
        let secondStop = Task {
            secondStopEntered.signal()
            await service.stop()
            secondStopProbe.markReturned()
        }
        await secondStopEntered.wait()
        #expect(!secondStopProbe.didReturn)
        #expect(stream.stopCount == 1)

        stream.releaseStop()
        await stop.value
        await secondStop.value
        #expect(!service.isTranscribing)
        #expect(secondStopProbe.didReturn)
        #expect(audioSession.deactivationCount == 1)
    }

    @Test("cached-model removal waits for active stream teardown")
    func removalWaitsForStopCompletion() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .readyUntilStopped, blocksStop: true)
        let service = makeService(fixture: fixture, stream: stream)

        #expect(await service.start())
        let stop = Task { await service.stop() }
        await stream.waitUntilStopRequested()

        let removalEntered = ControlledSignal()
        let removalProbe = ControlledCallProbe()
        let removal = Task {
            removalEntered.signal()
            await service.removeCachedModel()
            removalProbe.markReturned()
        }
        await removalEntered.wait()
        #expect(!removalProbe.didReturn)
        #expect(service.hasCachedModel)

        stream.releaseStop()
        await stop.value
        await removal.value
        #expect(removalProbe.didReturn)
        #expect(!service.hasCachedModel)
    }

    @Test("a failed start clears the previous transcript instead of leaking it")
    func failedStartClearsStaleTranscript() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let permission = PermissionGate()
        let updates = UpdateBox()
        let stream = ControlledStream(behavior: .readyUntilStopped)
        let service = TranscriptionService(
            testingCache: fixture.cache,
            modelLoader: { preparation, _ in
                guard case .loadCached(let cached) = preparation else {
                    throw TestFailure.unexpectedDownload
                }
                return TranscriptionLoadedModel(models: nil, cacheEntry: cached)
            },
            permissionRequest: { await permission.value },
            streamFactory: { _, update in
                updates.update = update
                return TranscriptionStreamHandle(
                    run: { try await stream.run(update: update) },
                    stop: { await stream.stop() }
                )
            }
        )

        // First cycle: a successful recording leaves a transcript behind.
        #expect(await service.start())
        updates.update?(TranscriptionStreamUpdate(
            isRecording: true,
            confirmedText: "ship it",
            partialText: ""
        ))
        await waitUntil { service.finalText == "ship it" }
        await service.stop()
        #expect(service.combinedText == "ship it")

        // Second cycle dies at the permission gate. The stale transcript must
        // not survive — a walkie-talkie release would otherwise re-send it.
        await permission.deny()
        #expect(await service.start() == false)
        #expect(service.combinedText.isEmpty)
        #expect(service.modelErrorMessage != nil)
    }

    @Test("memoized cache state answers gesture checks without re-walking disk")
    func memoizedCacheStateAvoidsRepeatDiskWalks() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let service = makeService(fixture: fixture)

        await waitUntil { service.hasCachedModel }
        let memoizedSize = service.cachedModelSize
        #expect(memoizedSize != "Not downloaded")

        // Deleting the backing files must go unnoticed by gesture-path
        // checks: a re-walk would see the empty directory and flip both
        // answers, so stable answers prove they come from the memo.
        fixture.remove()
        for _ in 0..<25 {
            #expect(service.hasCachedModel)
            #expect(service.cachedModelSize == memoizedSize)
        }
    }

    @Test("cached-model removal clears memoized state synchronously")
    func removalClearsMemoizedCacheState() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let service = makeService(fixture: fixture)
        await waitUntil { service.hasCachedModel }
        #expect(service.cachedModelSize != "Not downloaded")

        await service.removeCachedModel()
        #expect(!service.hasCachedModel)
        #expect(service.cachedModelSize == "Not downloaded")
    }

    @Test("a memoized entry that fails load-time validation is dropped, not downloaded")
    func staleMemoizedEntryFailsLoadWithoutDownload() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let service = makeService(fixture: fixture)
        await waitUntil { service.hasCachedModel }

        // Corrupt the cache behind the memoized entry. The load must surface
        // the incomplete-cache error (never a silent download) and drop the
        // memoized readiness synchronously — before the background re-walk
        // lands — so a gesture arriving right after the failure re-confirms
        // with the user instead of starting a silent download.
        try FileManager.default.removeItem(
            at: fixture.model.appendingPathComponent(SpeechModelCache.vocabularyName)
        )
        #expect(!(await service.loadModel()))
        #expect(service.modelErrorMessage?.contains("incomplete") == true)
        #expect(!service.hasCachedModel)
    }

    private func makeService(
        fixture: ModelCacheFixture,
        loader: ControlledModelLoader? = nil,
        permission: @escaping @Sendable () async -> Bool = { true },
        stream: ControlledStream = ControlledStream(behavior: .readyUntilStopped),
        audioSession: ControlledAudioSession? = nil,
        updates: UpdateBox? = nil,
        finalize: @escaping @Sendable () async throws -> String? = { nil }
    ) -> TranscriptionService {
        let entry = fixture.cache.validEntry!
        return TranscriptionService(
            testingCache: fixture.cache,
            modelLoader: { preparation, _ in
                if let loader { return try await loader.load() }
                guard case .loadCached(let cached) = preparation else {
                    throw TestFailure.unexpectedDownload
                }
                return TranscriptionLoadedModel(models: nil, cacheEntry: cached)
            },
            permissionRequest: permission,
            streamFactory: { loaded, update in
                #expect(loaded.cacheEntry == entry)
                updates?.update = update
                return TranscriptionStreamHandle(
                    run: { try await stream.run(update: update) },
                    stop: { await stream.stop() },
                    finalize: finalize
                )
            },
            activateAudioSession: { audioSession?.activate() },
            deactivateAudioSession: { audioSession?.deactivate() }
        )
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        while !predicate() { await Task.yield() }
    }
}

private enum TestFailure: Error {
    case unexpectedDownload
    case finalDecodeFailed
    case streamStopped
}

private actor PermissionGate {
    private var allowed = true
    var value: Bool { allowed }
    func deny() { allowed = false }
}

private final class UpdateBox: @unchecked Sendable {
    var update: (@Sendable (TranscriptionStreamUpdate) -> Void)?
}

private actor ControlledModelLoader {
    let entry: SpeechModelCache.Entry
    private(set) var loadCount = 0
    private var releases: [CheckedContinuation<Void, Never>] = []

    init(entry: SpeechModelCache.Entry) {
        self.entry = entry
    }

    func load() async throws -> TranscriptionLoadedModel {
        loadCount += 1
        await withCheckedContinuation { releases.append($0) }
        return TranscriptionLoadedModel(models: nil, cacheEntry: entry)
    }

    func waitForLoadCount(_ expected: Int) async {
        while loadCount < expected { await Task.yield() }
    }

    func releaseNext() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }
}

private final class ControlledStream: @unchecked Sendable {
    enum Behavior: Sendable {
        case readyUntilStopped
        case waitWithoutReadiness
        case returnBeforeReady
    }

    private let behavior: Behavior
    private let blocksStop: Bool
    private let lock = NSLock()
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>
    private var runs = 0
    private var stops = 0
    private var didFinishRunning = false
    private var shouldThrowOnExit = false
    private var stopReleased = false
    private var stopReleaseContinuation: CheckedContinuation<Void, Never>?

    init(behavior: Behavior, blocksStop: Bool = false) {
        self.behavior = behavior
        self.blocksStop = blocksStop
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    var runCount: Int { lock.withLock { runs } }
    var stopCount: Int { lock.withLock { stops } }
    var hasFinishedRunning: Bool { lock.withLock { didFinishRunning } }

    func run(update: @escaping @Sendable (TranscriptionStreamUpdate) -> Void) async throws {
        lock.withLock { runs += 1 }
        defer { lock.withLock { didFinishRunning = true } }
        switch behavior {
        case .returnBeforeReady:
            return
        case .readyUntilStopped:
            update(TranscriptionStreamUpdate(
                isRecording: true,
                confirmedText: "",
                partialText: ""
            ))
        case .waitWithoutReadiness:
            break
        }
        for await _ in stream {}
        if lock.withLock({ shouldThrowOnExit }) { throw TestFailure.streamStopped }
    }

    func endUnexpectedly(throwsError: Bool) {
        lock.withLock { shouldThrowOnExit = throwsError }
        continuation.finish()
    }

    func stop() async {
        lock.withLock { stops += 1 }
        if blocksStop { await waitForStopRelease() }
        continuation.finish()
    }

    func waitUntilRunning() async {
        while runCount == 0 { await Task.yield() }
    }

    func waitUntilStopRequested() async {
        while stopCount == 0 { await Task.yield() }
    }

    func releaseStop() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            stopReleased = true
            defer { stopReleaseContinuation = nil }
            return stopReleaseContinuation
        }
        pending?.resume()
    }

    private func waitForStopRelease() async {
        await withCheckedContinuation { continuation in
            let alreadyReleased = lock.withLock { () -> Bool in
                guard !stopReleased else { return true }
                stopReleaseContinuation = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
    }
}

private actor ControlledFinalizer {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<String, Never>?

    func finish() async -> String {
        callCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        while callCount == 0 { await Task.yield() }
    }

    func resolve(_ text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

private final class ControlledSignal: @unchecked Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func signal() {
        continuation.yield()
        continuation.finish()
    }

    func wait() async {
        for await _ in stream { return }
    }
}

@MainActor
private final class ControlledCallProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}

@MainActor
private final class ControlledAudioSession: @unchecked Sendable {
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0

    func activate() {
        activationCount += 1
    }

    func deactivate() {
        deactivationCount += 1
    }
}

private actor ControlledPermission {
    private var requested = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func request() async -> Bool {
        requested = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        while !requested { await Task.yield() }
    }

    func resolve(_ granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

private struct ModelCacheFixture {
    let root: URL
    let documents: URL
    let model: URL

    var cache: SpeechModelCache {
        SpeechModelCache(documentsURL: documents)
    }

    init(
        includeDecoder: Bool = true,
        includeVocabulary: Bool = true,
        corruptVocabulary: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-transcription-tests-\(UUID().uuidString)", isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        model = documents.appendingPathComponent("speech-models", isDirectory: true)
            .appendingPathComponent(SpeechModelCache.modelName, isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for name in SpeechModelCache.requiredModelNames where includeDecoder || name != "Decoder" {
            try writeComponent(name)
        }
        if includeVocabulary {
            let vocabulary = corruptVocabulary ? [:] : Dictionary(
                uniqueKeysWithValues: (0..<8192).map { (String($0), "token\($0)") })
            try JSONEncoder().encode(vocabulary).write(to: model.appendingPathComponent(SpeechModelCache.vocabularyName))
        }
    }

    func writeComponent(_ name: String) throws {
        let component = model.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: component.appendingPathComponent("weights"), withIntermediateDirectories: true)
        for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
            try Data([1]).write(to: component.appendingPathComponent(file))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
