import Foundation

/// Routes dictation through the captured terminal or VNC connection without
/// relying on whichever AppKit view happens to have focus at delivery time.
@MainActor
struct PilotWalkieDelivery {
    typealias Target = PilotWalkieInputState.Target

    let store: WorkspaceStore
    let terminalPaneID: @MainActor (UUID?) -> UUID?
    var remoteSessionID: @MainActor (UUID) -> UUID? = {
        RemoteDesktopSessionManager.shared.existingSession(for: $0)?.inputSessionID
    }
    var insertText: @MainActor (Target, String) -> Bool = Self.insertLiveText
    var sendEnter: @MainActor (Target) -> Bool = Self.sendLiveEnter

    func capture(workspaceID: UUID?) -> Target? {
        if workspaceID == WorkspaceStore.remoteDesktopWorkspaceID {
            guard store.isSidebarFeatureVisible(.remoteDesktop), let connection = store.selectedRemoteConnection,
                  let sessionID = remoteSessionID(connection.id) else { return nil }
            return Target(workspaceID: workspaceID, destination: .remoteDesktop(
                connectionID: connection.id, sessionID: sessionID
            ))
        }
        return terminalPaneID(workspaceID).map { Target(workspaceID: workspaceID, paneID: $0) }
    }

    func start(_ command: VoiceRecordCommand, state: inout PilotWalkieInputState) {
        let workspaceID = command.workspaceID ?? store.selectedSyncWorkspaceID
        if workspaceID == WorkspaceStore.remoteDesktopWorkspaceID {
            store.enterRemoteDesktopMode()
        } else if let workspaceID {
            store.selectWorkspace(workspaceID)
        }
        state.begin(recordingID: command.recordingID, workspaceID: workspaceID,
                    target: capture(workspaceID: workspaceID))
    }

    @discardableResult
    func receive(_ speech: TranscribedSpeech, state: inout PilotWalkieInputState) -> Bool {
        let fallback = speech.recordingID == nil
            ? capture(workspaceID: speech.workspaceID ?? store.selectedSyncWorkspaceID) : nil
        let target = state.receiveTranscript(recordingID: speech.recordingID,
                                             workspaceID: speech.workspaceID, legacyFallback: fallback)
        let text = PilotWalkieInputState.textForTerminal(speech.text)
        guard !text.isEmpty, let target, insertText(target, text) else { return false }
        state.didPasteTranscript(recordingID: speech.recordingID)
        return true
    }

    @discardableResult
    func execute(_ command: ExecuteTranscript, state: inout PilotWalkieInputState) -> Bool {
        guard let target = state.takeExecutionTarget(recordingID: command.recordingID,
                                                    workspaceID: command.workspaceID) else { return false }
        return sendEnter(target)
    }

    @discardableResult
    func enterSelection() -> Bool {
        guard let target = capture(workspaceID: store.selectedSyncWorkspaceID) else { return false }
        return sendEnter(target)
    }

    private static func insertLiveText(target: Target, text: String) -> Bool {
        switch target.destination {
        case .terminal(let paneID):
            guard let terminal = GhosttyMetalView.view(for: paneID), terminal.surface != nil else { return false }
            terminal.pasteText(text)
            return true
        case .remoteDesktop(let connectionID, let sessionID):
            return RemoteDesktopSessionManager.shared.existingSession(for: connectionID)?
                .sendText(text, sessionID: sessionID) ?? false
        }
    }

    private static func sendLiveEnter(target: Target) -> Bool {
        switch target.destination {
        case .terminal(let paneID):
            guard let terminal = GhosttyMetalView.view(for: paneID), terminal.surface != nil else { return false }
            terminal.sendEnter()
            return true
        case .remoteDesktop(let connectionID, let sessionID):
            return RemoteDesktopSessionManager.shared.existingSession(for: connectionID)?
                .sendEnter(sessionID: sessionID) ?? false
        }
    }
}
