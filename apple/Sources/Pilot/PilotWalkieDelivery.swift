import Foundation

/// Routes dictation through the captured terminal or VNC connection without
/// relying on whichever AppKit view happens to have focus at delivery time.
@MainActor
struct PilotWalkieDelivery {
    typealias Target = PilotWalkieInputState.Target
    typealias TerminalSessionResolver = @MainActor (UUID) -> (any CockpitTerminalSession)?
    typealias InsertText = @MainActor (Target, String) async -> Bool
    typealias SendEnter = @MainActor (Target) async -> Bool

    let store: WorkspaceStore
    let terminalPaneID: @MainActor (UUID?) -> UUID?
    let terminalSession: TerminalSessionResolver
    var remoteSessionID: @MainActor (UUID) -> UUID?
    var insertText: InsertText?
    var sendEnter: SendEnter?

    init(
        store: WorkspaceStore,
        terminalPaneID: @escaping @MainActor (UUID?) -> UUID?,
        terminalSession: TerminalSessionResolver? = nil,
        remoteSessionID: @escaping @MainActor (UUID) -> UUID? = {
            RemoteDesktopSessionManager.shared.existingSession(for: $0)?.inputSessionID
        },
        insertText: InsertText? = nil,
        sendEnter: SendEnter? = nil
    ) {
        self.store = store
        self.terminalPaneID = terminalPaneID
        self.terminalSession = terminalSession ?? { paneID in
            guard let pane = store.workspaces.lazy.flatMap(\.panes).first(where: { $0.id == paneID }) else {
                return nil
            }
            return TerminalSessionProvider.shared.existingSession(for: pane)
        }
        self.remoteSessionID = remoteSessionID
        self.insertText = insertText
        self.sendEnter = sendEnter
    }

    func capture(workspaceID: UUID?) -> Target? {
        if workspaceID == WorkspaceStore.remoteDesktopWorkspaceID {
            guard store.isSidebarFeatureVisible(.remoteDesktop), let connection = store.selectedRemoteConnection,
                  let sessionID = remoteSessionID(connection.id) else { return nil }
            return Target(workspaceID: workspaceID, destination: .remoteDesktop(
                connectionID: connection.id, sessionID: sessionID
            ))
        }
        guard let paneID = terminalPaneID(workspaceID), let session = terminalSession(paneID),
              session.identity.paneID == paneID, session.destination.isValid else { return nil }
        return Target(workspaceID: workspaceID, paneID: paneID, terminalIdentity: session.identity)
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
    func receive(_ speech: TranscribedSpeech, state: inout PilotWalkieInputState) async -> Bool {
        let fallback = speech.recordingID == nil
            ? capture(workspaceID: speech.workspaceID ?? store.selectedSyncWorkspaceID) : nil
        let target = state.receiveTranscript(recordingID: speech.recordingID,
                                             workspaceID: speech.workspaceID, legacyFallback: fallback)
        let text = PilotWalkieInputState.textForTerminal(speech.text)
        guard !text.isEmpty, let target else { return false }
        let inserted = if let insertText {
            await insertText(target, text)
        } else {
            await insertLiveText(target: target, text: text)
        }
        guard inserted else { return false }
        state.didPasteTranscript(recordingID: speech.recordingID)
        return true
    }

    @discardableResult
    func execute(_ command: ExecuteTranscript, state: inout PilotWalkieInputState) async -> Bool {
        guard let target = state.takeExecutionTarget(recordingID: command.recordingID,
                                                    workspaceID: command.workspaceID) else { return false }
        if let sendEnter { return await sendEnter(target) }
        return await sendLiveEnter(target: target)
    }

    @discardableResult
    func enterSelection() async -> Bool {
        guard let target = capture(workspaceID: store.selectedSyncWorkspaceID) else { return false }
        if let sendEnter { return await sendEnter(target) }
        return await sendLiveEnter(target: target)
    }

    private func insertLiveText(target: Target, text: String) async -> Bool {
        switch target.destination {
        case .terminal(let paneID):
            guard let session = liveSession(for: target, paneID: paneID) else { return false }
            return await session.send(.literal(text))
        case .remoteDesktop(let connectionID, let sessionID):
            return RemoteDesktopSessionManager.shared.existingSession(for: connectionID)?
                .sendText(text, sessionID: sessionID) ?? false
        }
    }

    private func sendLiveEnter(target: Target) async -> Bool {
        switch target.destination {
        case .terminal(let paneID):
            guard let session = liveSession(for: target, paneID: paneID) else { return false }
            return await session.send(.enter)
        case .remoteDesktop(let connectionID, let sessionID):
            return RemoteDesktopSessionManager.shared.existingSession(for: connectionID)?
                .sendEnter(sessionID: sessionID) ?? false
        }
    }

    private func liveSession(for target: Target, paneID: UUID) -> (any CockpitTerminalSession)? {
        guard let identity = target.terminalIdentity, identity.paneID == paneID,
              let session = terminalSession(paneID), session.identity == identity,
              session.destination.isValid else { return nil }
        return session
    }
}
