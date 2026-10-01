import Foundation

/// Serializes one microphone cycle through final transcription and reliable
/// transport. Enter is deferred until the transcript has been sent, and uses
/// the same recording ID so Cockpit can execute in the captured input pane.
@MainActor
@Observable
final class CopilotWalkieTalkie {
    enum Phase: Equatable { case idle, preparing, recording, finishing }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var statusMessage: String?
    private(set) var rearmToken = 0

    private struct Recording {
        let id = UUID()
        let workspaceID: UUID?
        var didStart = false
        var didAnnounce = false
        var didSend = false
        var didExecute = false
        var wasInterrupted = false
    }

    private struct ExecutionRequest {
        let workspaceID: UUID?
    }

    @ObservationIgnored private let start: @MainActor (Bool) async -> Bool
    @ObservationIgnored private let finish: @MainActor () async -> String
    @ObservationIgnored private let send: @MainActor (SyncMessage) async -> Bool
    @ObservationIgnored private let isConnected: @MainActor () -> Bool
    @ObservationIgnored private var recording: Recording?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var executionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingExecution: ExecutionRequest?
    @ObservationIgnored private var interruptionGeneration = 0

    init(
        start: @escaping @MainActor (Bool) async -> Bool,
        finish: @escaping @MainActor () async -> String,
        send: @escaping @MainActor (SyncMessage) async -> Bool,
        isConnected: @escaping @MainActor () -> Bool
    ) {
        self.start = start
        self.finish = finish
        self.send = send
        self.isConnected = isConnected
    }

    func beginRecording(workspaceID: UUID?, allowRestrictedNetwork: Bool) {
        guard phase == .idle, executionTask == nil else { return }
        let attempt = Recording(workspaceID: workspaceID)
        recording = attempt
        pendingExecution = nil
        guard isConnected() else {
            statusMessage = "Connect to Cockpit before recording."
            return
        }
        transcript = ""
        statusMessage = nil
        phase = .preparing
        startTask = Task { [weak self] in
            guard let self else { return }
            let started = await self.start(allowRestrictedNetwork)
            guard self.recording?.id == attempt.id, self.phase == .preparing else { return }
            guard started else {
                self.phase = .idle
                self.rearmToken += 1
                self.statusMessage = "Recording could not start. Hold Volume Down to try again."
                return
            }
            self.recording?.didStart = true
            self.phase = .recording
            let sent = await self.send(.voiceRecord(VoiceRecordCommand(
                control: .start, workspaceID: attempt.workspaceID, recordingID: attempt.id
            )))
            guard self.recording?.id == attempt.id else { return }
            self.recording?.didAnnounce = sent
            if !sent {
                self.statusMessage = "Cockpit disconnected. Your transcript will stay on this phone."
            }
        }
    }

    func endRecording() {
        guard phase == .preparing || phase == .recording, let attempt = recording else { return }
        phase = .finishing
        let starting = startTask
        if !attempt.didStart { starting?.cancel() }
        finishTask = Task { [weak self] in
            guard let self else { return }
            // stop() invalidates any startup still waiting on permission; do
            // not wait for that prompt before releasing the microphone.
            let text = await self.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            if attempt.didStart { await starting?.value }
            self.rearmToken += 1
            guard self.recording?.id == attempt.id else { return }
            self.transcript = attempt.didStart ? text : ""
            if self.recording?.didAnnounce == true {
                _ = await self.send(.voiceRecord(VoiceRecordCommand(
                    control: .stop, workspaceID: attempt.workspaceID, recordingID: attempt.id
                )))
            }
            if attempt.didStart, !text.isEmpty {
                let sent = self.recording?.didAnnounce == true
                    && self.recording?.wasInterrupted == false && self.isConnected()
                    ? await self.send(.transcribedSpeech(TranscribedSpeech(
                        workspaceID: attempt.workspaceID, text: text, recordingID: attempt.id
                    ))) : false
                self.recording?.didSend = sent
                self.statusMessage = sent ? "Sent to Cockpit. Hold Volume Up to execute."
                    : "Could not send to Cockpit. Your transcript is below; copy it to keep it."
            } else {
                self.statusMessage = attempt.didStart ? "No speech detected. Hold Volume Down to try again."
                    : "Recording ended before the microphone was ready. Hold Volume Down to try again."
            }
            let pending = self.pendingExecution
            self.pendingExecution = nil
            if let pending, self.recording?.didSend == true {
                if pending.workspaceID == attempt.workspaceID {
                    await self.startExecution(workspaceID: pending.workspaceID).value
                } else {
                    self.statusMessage = "Select the recorded workspace and hold Volume Up to execute."
                }
            }
            self.phase = .idle
            self.startTask = nil
            self.finishTask = nil
        }
    }

    func execute(workspaceID: UUID?) {
        if phase != .idle {
            // One hold means one Enter, even while stop() is still decoding.
            if pendingExecution == nil { pendingExecution = ExecutionRequest(workspaceID: workspaceID) }
            return
        }
        guard executionTask == nil else { return }
        startExecution(workspaceID: workspaceID)
    }

    @discardableResult
    private func startExecution(workspaceID: UUID?) -> Task<Void, Never> {
        // Deferred Enter must be cancellable without cancelling finishTask,
        // which keeps the final transcript available after an interruption.
        let generation = interruptionGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performExecution(workspaceID: workspaceID, generation: generation)
            self.executionTask = nil
        }
        executionTask = task
        return task
    }

    /// Disconnect/background interrupts a hold, but never auto-executes it.
    func interrupt() {
        interruptionGeneration += 1
        recording?.wasInterrupted = true
        pendingExecution = nil
        executionTask?.cancel()
        endRecording()
    }

    /// A model-download prompt is not a recording. Do not let a subsequent Up
    /// hold execute the previous cycle after this attempt could not start.
    func recordingUnavailable(workspaceID: UUID?) {
        guard phase == .idle else { return }
        recording = Recording(workspaceID: workspaceID)
        transcript = ""
    }

    private func performExecution(workspaceID: UUID?, generation: Int) async {
        guard generation == interruptionGeneration, !Task.isCancelled else { return }
        guard isConnected() else {
            statusMessage = "Connect to Cockpit before sending Enter."
            return
        }
        if let recording {
            guard recording.workspaceID == workspaceID else {
                statusMessage = "Select the recorded workspace and hold Volume Up to execute."
                return
            }
            guard recording.didSend, !recording.didExecute else { return }
            self.recording?.didExecute = true
            let sent = await send(.executeTranscript(ExecuteTranscript(
                recordingID: recording.id, workspaceID: recording.workspaceID
            )))
            if !sent {
                self.recording?.didExecute = false
                statusMessage = "Could not send Enter. Hold Volume Up to try again."
            } else {
                statusMessage = "Enter sent to Cockpit."
            }
        } else {
            // Before any dictation, Up can submit an already typed command.
            if let workspaceID {
                guard await send(.selectWorkspace(SelectWorkspace(workspaceID: workspaceID))) else { return }
            }
            guard generation == interruptionGeneration, !Task.isCancelled, isConnected() else { return }
            _ = await send(.terminalInput(.enter))
        }
    }
}

/// Ignore workspace snapshots already in flight when a local volume tap was
/// sent. Once Cockpit confirms the selection, its normal updates take over.
struct CopilotWorkspaceSelectionState {
    private var pendingID: UUID?
    private var pendingUntil: Date?

    mutating func select(_ id: UUID, now: Date = Date()) {
        pendingID = id
        pendingUntil = now.addingTimeInterval(2)
    }

    mutating func receive(_ state: WorkspaceState, now: Date = Date()) -> UUID? {
        if let pendingID, let pendingUntil, now < pendingUntil,
           state.workspaces.contains(where: { $0.id == pendingID }),
           state.selectedWorkspaceID != pendingID {
            return pendingID
        }
        pendingID = nil
        pendingUntil = nil
        return state.selectedWorkspaceID
    }
}
