import Foundation

/// Pins one utterance to the input destination where its recording began. A
/// later Enter uses the same terminal or remote session despite focus changes.
struct PilotWalkieInputState {
    enum Destination: Equatable {
        case terminal(paneID: UUID)
        case remoteDesktop(connectionID: UUID, sessionID: UUID)
    }

    struct Target: Equatable {
        let workspaceID: UUID?
        let destination: Destination
        let terminalIdentity: TerminalSessionIdentity?

        init(
            workspaceID: UUID?,
            destination: Destination,
            terminalIdentity: TerminalSessionIdentity? = nil
        ) {
            self.workspaceID = workspaceID
            self.destination = destination
            self.terminalIdentity = terminalIdentity
        }

        init(workspaceID: UUID?, paneID: UUID, terminalIdentity: TerminalSessionIdentity? = nil) {
            self.init(
                workspaceID: workspaceID,
                destination: .terminal(paneID: paneID),
                terminalIdentity: terminalIdentity
            )
        }

        var paneID: UUID? {
            guard case .terminal(let paneID) = destination else { return nil }
            return paneID
        }
    }

    private enum Stage {
        case awaitingTranscript, receivedTranscript, pasted, executed
    }

    private struct Recording {
        let workspaceID: UUID?
        let target: Target?
        var stage: Stage = .awaitingTranscript

        func matches(workspaceID: UUID?) -> Bool {
            workspaceID == nil || self.workspaceID == workspaceID
        }
    }

    private enum RecordingKey: Equatable {
        case identified(UUID)
        case legacy
    }

    private var recordings: [UUID: Recording] = [:]
    private var recordingOrder: [UUID] = []
    private var legacyRecording: Recording?
    private var activeRecording: RecordingKey?
    private static let retainedRecordingLimit = 32

    var isRecording: Bool { activeRecording != nil }

    /// Literal terminal input is unbracketed. Keep dictated line breaks,
    /// Escape, and other controls from submitting or editing terminal input
    /// before the user explicitly holds volume up to send Enter.
    static func textForTerminal(_ transcript: String) -> String {
        transcript
            .components(separatedBy: CharacterSet.controlCharacters.union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func begin(recordingID: UUID?, workspaceID: UUID?, paneID: UUID?) {
        begin(
            recordingID: recordingID,
            workspaceID: workspaceID,
            target: paneID.map { Target(workspaceID: workspaceID, paneID: $0) }
        )
    }

    mutating func begin(recordingID: UUID?, workspaceID: UUID?, target: Target?) {
        let recording = Recording(workspaceID: workspaceID, target: target)
        if let recordingID {
            // Replayed start messages must not recapture a different target or
            // make an already-completed recording look active again.
            guard recordings[recordingID] == nil else { return }
            recordings[recordingID] = recording
            recordingOrder.append(recordingID)
            while recordingOrder.count > Self.retainedRecordingLimit {
                recordings.removeValue(forKey: recordingOrder.removeFirst())
            }
            activeRecording = .identified(recordingID)
        } else {
            legacyRecording = recording
            activeRecording = .legacy
        }
    }

    mutating func stop(recordingID: UUID?, workspaceID: UUID?) {
        if let recordingID {
            guard recordings[recordingID]?.matches(workspaceID: workspaceID) == true,
                  activeRecording == .identified(recordingID) else { return }
        } else {
            guard legacyRecording?.matches(workspaceID: workspaceID) == true,
                  activeRecording == .legacy else { return }
        }
        activeRecording = nil
    }

    mutating func receiveTranscript(
        recordingID: UUID?,
        workspaceID: UUID?,
        legacyFallback: Target? = nil
    ) -> Target? {
        if let recordingID {
            guard var recording = recordings[recordingID],
                  recording.matches(workspaceID: workspaceID),
                  recording.stage == .awaitingTranscript else { return nil }
            recording.stage = .receivedTranscript
            recordings[recordingID] = recording
            stop(recordingID: recordingID, workspaceID: workspaceID)
            return recording.target
        }

        // Older peers have no utterance ID. Preserve their captured target when
        // present, but never let a transcript from another workspace consume it.
        guard let recording = legacyRecording else { return legacyFallback }
        guard recording.matches(workspaceID: workspaceID) else { return nil }
        stop(recordingID: nil, workspaceID: workspaceID)
        legacyRecording = nil
        return recording.target
    }

    mutating func didPasteTranscript(recordingID: UUID?) {
        guard let recordingID,
              recordings[recordingID]?.stage == .receivedTranscript else { return }
        recordings[recordingID]?.stage = .pasted
    }

    mutating func takeExecutionTarget(recordingID: UUID, workspaceID: UUID?) -> Target? {
        guard var recording = recordings[recordingID],
              recording.matches(workspaceID: workspaceID),
              recording.stage == .pasted else { return nil }
        recording.stage = .executed
        recordings[recordingID] = recording
        return recording.target
    }

    mutating func reset() {
        self = Self()
    }
}
