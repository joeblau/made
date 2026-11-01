import Foundation
import Testing

@testable import Copilot

@Suite("SyncMessage Encoding")
struct SyncMessagesTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("WorkspaceState round-trip")
    func workspaceStateRoundTrip() throws {
        let state = WorkspaceState(
            workspaces: [
                WorkspaceSummary(id: UUID(), name: "Terminal"),
                WorkspaceSummary(id: UUID(), name: "Browser"),
            ],
            selectedWorkspaceID: nil
        )
        let message = SyncMessage.workspaceState(state)
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .workspaceState(let decodedState) = decoded {
            #expect(decodedState.workspaces.count == 2)
            #expect(decodedState.workspaces[0].name == "Terminal")
            #expect(decodedState.workspaces[1].name == "Browser")
            #expect(decodedState.selectedWorkspaceID == nil)
        } else {
            Issue.record("Expected workspaceState case")
        }
    }

    @Test("WorkspaceState with selection round-trip")
    func workspaceStateWithSelectionRoundTrip() throws {
        let id = UUID()
        let state = WorkspaceState(
            workspaces: [WorkspaceSummary(id: id, name: "Selected")],
            selectedWorkspaceID: id
        )
        let message = SyncMessage.workspaceState(state)
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .workspaceState(let decodedState) = decoded {
            #expect(decodedState.selectedWorkspaceID == id)
            #expect(decodedState.workspaces[0].id == id)
        } else {
            Issue.record("Expected workspaceState case")
        }
    }

    @Test("Legacy WorkspaceState defaults all dashboard snapshots to nil")
    func legacyWorkspaceStateHasNoDashboards() throws {
        let json = #"{"workspaces":[],"selectedWorkspaceID":null,"workflowRuns":null}"#
        let state = try decoder.decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(state.workflowRuns == nil)
        #expect(state.actionsDashboard == nil)
        #expect(state.usageDashboard == nil)
        #expect(state.runnersDashboard == nil)
    }

    @Test("WorkspaceState round-trips all dashboard snapshots")
    func workspaceStateDashboardRoundTrip() throws {
        let actions = ActionsDashboardSnapshot(updatedAt: 100, runs: [])
        let usage = UsageDashboardSnapshot(
            updatedAt: 200,
            estimatedCost: 1.5,
            totalTokens: 250,
            providers: []
        )
        let runners = RunnersDashboardSnapshot(
            enterpriseID: "enterprise:blau",
            enterpriseName: "BLAU",
            totalCount: 0,
            idleCount: 0,
            busyCount: 0,
            offlineCount: 0,
            runners: [],
            updatedAt: 300
        )
        let state = WorkspaceState(
            workspaces: [],
            selectedWorkspaceID: nil,
            actionsDashboard: actions,
            usageDashboard: usage,
            runnersDashboard: runners
        )
        let decoded = try decoder.decode(SyncMessage.self, from: try encoder.encode(SyncMessage.workspaceState(state)))
        guard case .workspaceState(let decodedState) = decoded else {
            Issue.record("Expected workspaceState case")
            return
        }
        #expect(decodedState.actionsDashboard == actions)
        #expect(decodedState.usageDashboard == usage)
        #expect(decodedState.runnersDashboard == runners)
    }

    @Test("SelectWorkspace round-trip")
    func selectWorkspaceRoundTrip() throws {
        let id = UUID()
        let message = SyncMessage.selectWorkspace(SelectWorkspace(workspaceID: id))
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .selectWorkspace(let sel) = decoded {
            #expect(sel.workspaceID == id)
        } else {
            Issue.record("Expected selectWorkspace case")
        }
    }

    @Test("Empty workspace list round-trip")
    func emptyWorkspaceListRoundTrip() throws {
        let state = WorkspaceState(workspaces: [], selectedWorkspaceID: nil)
        let message = SyncMessage.workspaceState(state)
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .workspaceState(let decodedState) = decoded {
            #expect(decodedState.workspaces.isEmpty)
        } else {
            Issue.record("Expected workspaceState case")
        }
    }

    @Test("WorkspaceSummary preserves UUID identity")
    func workspaceSummaryIdentity() throws {
        let id = UUID()
        let summary = WorkspaceSummary(id: id, name: "Test")
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(WorkspaceSummary.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.name == "Test")
    }

    @Test("WorkspaceSummary preserves badgeCount")
    func workspaceSummaryBadgeCount() throws {
        let summary = WorkspaceSummary(id: UUID(), name: "Test", badgeCount: 3)
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(WorkspaceSummary.self, from: data)
        #expect(decoded.badgeCount == 3)
    }

    @Test("WorkspaceSummary badgeCount defaults to zero")
    func workspaceSummaryBadgeCountDefault() throws {
        let summary = WorkspaceSummary(id: UUID(), name: "Test")
        #expect(summary.badgeCount == 0)
    }

    @Test("VoiceRecordCommand round-trip")
    func voiceRecordCommandRoundTrip() throws {
        let id = UUID()
        let recordingID = UUID()
        for control in [VoiceRecordControl.start, VoiceRecordControl.stop] {
            let command = VoiceRecordCommand(control: control, workspaceID: id, recordingID: recordingID)
            let message = SyncMessage.voiceRecord(command)
            let data = try encoder.encode(message)
            let decoded = try decoder.decode(SyncMessage.self, from: data)

            if case .voiceRecord(let decodedCommand) = decoded {
                #expect(decodedCommand.control == control)
                #expect(decodedCommand.workspaceID == id)
                #expect(decodedCommand.recordingID == recordingID)
            } else {
                Issue.record("Expected voiceRecord case for \(control)")
            }
        }
    }

    @Test("VoiceRecordCommand with nil workspaceID")
    func voiceRecordCommandNilWorkspace() throws {
        let command = VoiceRecordCommand(control: .start, workspaceID: nil)
        let message = SyncMessage.voiceRecord(command)
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .voiceRecord(let decodedCommand) = decoded {
            #expect(decodedCommand.workspaceID == nil)
            #expect(decodedCommand.recordingID == nil)
        } else {
            Issue.record("Expected voiceRecord case")
        }
    }

    @Test("TranscribedSpeech preserves the recording ID and exact transcript")
    func transcribedSpeechRoundTrip() throws {
        let workspaceID = UUID()
        let recordingID = UUID()
        let text = "Review the changes in Café.swift, then run the tests."
        let message = SyncMessage.transcribedSpeech(TranscribedSpeech(
            workspaceID: workspaceID,
            text: text,
            recordingID: recordingID
        ))
        let decoded = try decoder.decode(SyncMessage.self, from: encoder.encode(message))

        guard case .transcribedSpeech(let speech) = decoded else {
            Issue.record("Expected transcribedSpeech case")
            return
        }
        #expect(speech.workspaceID == workspaceID)
        #expect(speech.recordingID == recordingID)
        #expect(speech.text == text)
    }

    @Test("ExecuteTranscript preserves its recording and optional workspace")
    func executeTranscriptRoundTrip() throws {
        let recordingID = UUID()
        for workspaceID in [UUID(), nil] {
            let message = SyncMessage.executeTranscript(ExecuteTranscript(
                recordingID: recordingID,
                workspaceID: workspaceID
            ))
            let decoded = try decoder.decode(SyncMessage.self, from: encoder.encode(message))

            guard case .executeTranscript(let command) = decoded else {
                Issue.record("Expected executeTranscript case")
                continue
            }
            #expect(command.recordingID == recordingID)
            #expect(command.workspaceID == workspaceID)
        }
    }

    @Test("Legacy recording start and stop decode without a recording ID")
    func legacyVoiceCommandsRemainCompatible() throws {
        let workspaceID = UUID()
        for control in [VoiceRecordControl.start, VoiceRecordControl.stop] {
            let json = """
            {"voiceRecord":{"_0":{"control":"\(control.rawValue)","workspaceID":"\(workspaceID.uuidString)"}}}
            """
            let decoded = try decoder.decode(SyncMessage.self, from: Data(json.utf8))

            guard case .voiceRecord(let command) = decoded else {
                Issue.record("Expected legacy voiceRecord case")
                continue
            }
            #expect(command.control == control)
            #expect(command.workspaceID == workspaceID)
            #expect(command.recordingID == nil)
        }
    }

    @Test("Legacy speech decodes without a recording ID or explicit workspace")
    func legacySpeechRemainsCompatible() throws {
        let workspaceID = UUID()
        let fixtures = [
            """
            {"transcribedSpeech":{"_0":{"text":"Run the tests","workspaceID":"\(workspaceID.uuidString)"}}}
            """,
            #"{"transcribedSpeech":{"_0":{"text":"Run the tests"}}}"#,
        ]
        for (index, json) in fixtures.enumerated() {
            let decoded = try decoder.decode(SyncMessage.self, from: Data(json.utf8))

            guard case .transcribedSpeech(let speech) = decoded else {
                Issue.record("Expected legacy transcribedSpeech case")
                continue
            }
            #expect(speech.workspaceID == (index == 0 ? workspaceID : nil))
            #expect(speech.recordingID == nil)
            #expect(speech.text == "Run the tests")
        }
    }
}

@Suite("AudioOutputDevice")
struct AudioOutputDeviceTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("AudioOutputDevice round-trip with new kinds",
          arguments: [
            ConnectedDeviceKind.beats,
            ConnectedDeviceKind.usb,
            ConnectedDeviceKind.speaker,
            ConnectedDeviceKind.unknown,
          ])
    func audioOutputDeviceRoundTrip(kind: ConnectedDeviceKind) throws {
        let device = AudioOutputDevice(kind: kind, name: "Test Device")
        let data = try encoder.encode(device)
        let decoded = try decoder.decode(AudioOutputDevice.self, from: data)
        #expect(decoded.kind == kind)
        #expect(decoded.name == "Test Device")
    }

    @Test("DeviceStatus with audioOutput round-trip")
    func deviceStatusRoundTrip() throws {
        let status = DeviceStatus(
            isWatchConnected: true,
            audioOutput: AudioOutputDevice(kind: .airpodsPro, name: "Joe's AirPods Pro")
        )
        let data = try encoder.encode(status)
        let decoded = try decoder.decode(DeviceStatus.self, from: data)
        #expect(decoded.isWatchConnected == true)
        #expect(decoded.audioOutput?.kind == .airpodsPro)
        #expect(decoded.audioOutput?.name == "Joe's AirPods Pro")
    }

    @Test("DeviceStatus with nil audioOutput")
    func deviceStatusNilAudioOutput() throws {
        let status = DeviceStatus()
        let data = try encoder.encode(status)
        let decoded = try decoder.decode(DeviceStatus.self, from: data)
        #expect(decoded.audioOutput == nil)
        #expect(decoded.isWatchConnected == false)
    }
}

@Suite("ConnectedDeviceKind classification")
struct ClassificationTests {
    @Test("AirPods Max classified correctly")
    func airpodsMax() {
        let kind = ConnectedDeviceKind.classify(name: "Joe's AirPods Max", defaultKind: .headphonesBluetooth)
        #expect(kind == .airpodsMax)
    }

    @Test("AirPods Pro classified correctly")
    func airpodsPro() {
        let kind = ConnectedDeviceKind.classify(name: "AirPods Pro", defaultKind: .headphonesBluetooth)
        #expect(kind == .airpodsPro)
    }

    @Test("AirPods (regular) classified correctly")
    func airpods() {
        let kind = ConnectedDeviceKind.classify(name: "AirPods", defaultKind: .headphonesBluetooth)
        #expect(kind == .airpods)
    }

    @Test("Beats classified correctly")
    func beats() {
        let kind = ConnectedDeviceKind.classify(name: "Beats Studio Pro", defaultKind: .headphonesBluetooth)
        #expect(kind == .beats)
    }

    @Test("Case insensitive matching")
    func caseInsensitive() {
        #expect(ConnectedDeviceKind.classify(name: "AIRPODS PRO", defaultKind: .unknown) == .airpodsPro)
        #expect(ConnectedDeviceKind.classify(name: "airpods max", defaultKind: .unknown) == .airpodsMax)
        #expect(ConnectedDeviceKind.classify(name: "BEATS Solo", defaultKind: .unknown) == .beats)
    }

    @Test("Unknown device returns defaultKind")
    func unknownDevice() {
        let kind = ConnectedDeviceKind.classify(name: "Sony WH-1000XM5", defaultKind: .headphonesBluetooth)
        #expect(kind == .headphonesBluetooth)
    }

    @Test("AirPods Max takes priority over AirPods")
    func airpodsMaxPriority() {
        let kind = ConnectedDeviceKind.classify(name: "AirPods Max", defaultKind: .unknown)
        #expect(kind == .airpodsMax)
    }

    @Test("AirPods Pro takes priority over AirPods")
    func airpodsProPriority() {
        let kind = ConnectedDeviceKind.classify(name: "AirPods Pro", defaultKind: .unknown)
        #expect(kind == .airpodsPro)
    }

    @Test("Empty name returns defaultKind")
    func emptyName() {
        let kind = ConnectedDeviceKind.classify(name: "", defaultKind: .speaker)
        #expect(kind == .speaker)
    }
}

@Suite("ConnectedDeviceKind properties")
struct DeviceKindPropertyTests {
    @Test("New kinds have systemImageName")
    func systemImageNames() {
        #expect(!ConnectedDeviceKind.beats.systemImageName.isEmpty)
        #expect(!ConnectedDeviceKind.usb.systemImageName.isEmpty)
        #expect(!ConnectedDeviceKind.speaker.systemImageName.isEmpty)
        #expect(!ConnectedDeviceKind.unknown.systemImageName.isEmpty)
    }

    @Test("New kinds have displayName")
    func displayNames() {
        #expect(ConnectedDeviceKind.beats.displayName == "Beats")
        #expect(ConnectedDeviceKind.usb.displayName == "USB Audio")
        #expect(ConnectedDeviceKind.speaker.displayName == "Speaker")
        #expect(ConnectedDeviceKind.unknown.displayName == "Audio Output")
    }

    @Test("isHeadphones correct for new kinds")
    func isHeadphones() {
        #expect(ConnectedDeviceKind.beats.isHeadphones == true)
        #expect(ConnectedDeviceKind.usb.isHeadphones == true)
        #expect(ConnectedDeviceKind.speaker.isHeadphones == false)
        #expect(ConnectedDeviceKind.unknown.isHeadphones == false)
    }

    @Test("isHeadphones correct for existing kinds")
    func isHeadphonesExisting() {
        #expect(ConnectedDeviceKind.airpods.isHeadphones == true)
        #expect(ConnectedDeviceKind.airpodsPro.isHeadphones == true)
        #expect(ConnectedDeviceKind.airpodsMax.isHeadphones == true)
        #expect(ConnectedDeviceKind.headphonesWired.isHeadphones == true)
        #expect(ConnectedDeviceKind.headphonesBluetooth.isHeadphones == true)
        #expect(ConnectedDeviceKind.computer.isHeadphones == false)
        #expect(ConnectedDeviceKind.iphone.isHeadphones == false)
        #expect(ConnectedDeviceKind.appleWatch.isHeadphones == false)
    }

    @Test("usesFillVariant for speaker")
    func usesFillVariant() {
        #expect(ConnectedDeviceKind.speaker.usesFillVariant == true)
        #expect(ConnectedDeviceKind.beats.usesFillVariant == false)
        #expect(ConnectedDeviceKind.usb.usesFillVariant == false)
        #expect(ConnectedDeviceKind.unknown.usesFillVariant == false)
    }
}
