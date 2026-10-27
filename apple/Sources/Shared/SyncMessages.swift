import Foundation

struct WorkspaceSummary: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var isPinned: Bool = false
    var badgeCount: Int = 0
    /// The workspace's panes, surfaced to Copilot as selectable tabs.
    var tabs: [TabSummary] = []
    /// The pane currently focused in Pilot for this workspace.
    var selectedTabID: UUID? = nil
}

/// One pane within a workspace, shown as a tab in Copilot's tab selector.
struct TabSummary: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var title: String
    var systemImageName: String
}

enum VoiceRecordControl: String, Codable, Sendable {
    case start, stop
}

struct VoiceRecordCommand: Codable, Sendable {
    let control: VoiceRecordControl
    let workspaceID: UUID?
    var recordingID: UUID? = nil
}

/// Final transcript produced on Copilot (iPhone). Sent to Pilot at the
/// end of a push-to-talk hold so the Mac can paste it into the workspace
/// whose volume button was held — no audio bytes ever cross the wire.
struct TranscribedSpeech: Codable, Sendable {
    let workspaceID: UUID?
    let text: String
    var recordingID: UUID? = nil
}

/// Execute only the input that received this recording's transcript, even if
/// the user has focused a different pane since dictation began.
struct ExecuteTranscript: Codable, Sendable {
    let recordingID: UUID
    let workspaceID: UUID?
}

enum TerminalInput: String, Codable, Sendable {
    case enter
}

struct SelectTab: Codable, Sendable {
    let workspaceID: UUID
    let tabID: UUID
}

enum SyncMessage: Codable, Sendable {
    case workspaceState(WorkspaceState)
    case selectWorkspace(SelectWorkspace)
    case selectTab(SelectTab)
    case deviceStatus(DeviceStatus)
    case mouseMove(MouseMove)
    case mouseClick(MouseClick)
    case voiceRecord(VoiceRecordCommand)
    case transcribedSpeech(TranscribedSpeech)
    case terminalInput(TerminalInput)
    case executeTranscript(ExecuteTranscript)
    case followBuild(BuildFollowRequest)
    case unfollowBuild(BuildUnfollowRequest)
    case buildRunUpdate(BuildWorkflowRun)
    /// Announces this device's long-term public key to the paired peer so the
    /// two sides exchange keys automatically over the encrypted Multipeer
    /// channel — no manual entry (issue #51).
    case deviceKey(DeviceKeyAnnounce)
}

/// A device broadcasting its long-term Curve25519 public key (base64) to its
/// paired peer, tagged with which app sent it.
struct DeviceKeyAnnounce: Codable, Sendable {
    let role: ConnectedDeviceAppRole
    let publicKey: String
}

public struct AnnotationPoint: Codable, Sendable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct AnnotationColor: Codable, Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct AnnotationStroke: Codable, Sendable, Hashable {
    public let color: AnnotationColor
    public let width: Double
    public let points: [AnnotationPoint]

    public init(color: AnnotationColor, width: Double, points: [AnnotationPoint]) {
        self.color = color
        self.width = width
        self.points = points
    }
}

public struct AnnotationDrawing: Codable, Sendable, Hashable {
    public let strokes: [AnnotationStroke]

    public init(strokes: [AnnotationStroke]) {
        self.strokes = strokes
    }
}

public enum AnnotationMessage: Codable, Sendable, Hashable {
    /// Full-drawing resync (used on connect / non-incremental changes).
    case replaceDrawing(AnnotationDrawing)
    /// One completed stroke appended incrementally, so each Plotter line is a
    /// discrete entry on Pilot's undo stack.
    case addStroke(AnnotationStroke)
    case clear
    /// Undo the most recent stroke. Flows either direction: when one side undoes
    /// it tells the other to pop too, keeping both in sync.
    case undo
}

struct MouseMove: Codable, Sendable {
    let dx: Float
    let dy: Float
}

struct MouseClick: Codable, Sendable {
    let button: Int // 0 = left
}

struct AudioOutputDevice: Codable, Sendable, Hashable {
    let kind: ConnectedDeviceKind
    let name: String
}

struct DeviceStatus: Codable, Sendable {
    var isWatchConnected: Bool = false
    var audioOutput: AudioOutputDevice?
}

enum ConnectedDeviceAppRole: String, Codable, Sendable {
    case pilot
    case copilot
}

enum ConnectedDeviceKind: String, Codable, Sendable, Hashable, Identifiable {
    case computer
    case iphone
    case ipad
    case appleWatch
    case airpods
    case airpodsPro
    case airpodsMax
    case beats
    case headphonesWired
    case headphonesBluetooth
    case usb
    case speaker
    case unknown

    var id: String { rawValue }

    var systemImageName: String {
        switch self {
        case .computer: return "laptopcomputer"
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .appleWatch: return "applewatch"
        case .airpods: return "airpods.gen3"
        case .airpodsPro: return "airpods.pro"
        case .airpodsMax: return "airpods.max"
        case .beats: return "beats.headphones"
        case .headphonesWired: return "headphones"
        case .headphonesBluetooth: return "headphones"
        case .usb: return "cable.connector"
        case .speaker: return "hifispeaker"
        case .unknown: return "speaker.wave.2"
        }
    }

    var displayName: String {
        switch self {
        case .computer: return "Computer"
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .appleWatch: return "Apple Watch"
        case .airpods: return "AirPods"
        case .airpodsPro: return "AirPods Pro"
        case .airpodsMax: return "AirPods Max"
        case .beats: return "Beats"
        case .headphonesWired: return "Wired Headphones"
        case .headphonesBluetooth: return "Bluetooth Headphones"
        case .usb: return "USB Audio"
        case .speaker: return "Speaker"
        case .unknown: return "Audio Output"
        }
    }

    var usesFillVariant: Bool {
        switch self {
        case .computer, .appleWatch, .speaker:
            return true
        case .iphone, .ipad, .airpods, .airpodsPro, .airpodsMax, .beats,
             .headphonesWired, .headphonesBluetooth, .usb, .unknown:
            return false
        }
    }

    var isHeadphones: Bool {
        switch self {
        case .airpods, .airpodsPro, .airpodsMax, .beats,
             .headphonesWired, .headphonesBluetooth, .usb:
            return true
        case .computer, .iphone, .ipad, .appleWatch, .speaker, .unknown:
            return false
        }
    }

    // Shared classification heuristic used by both iOS (HeadphoneRouteMonitor)
    // and macOS (HeadphoneDetector). Pure function: name string in, kind out.
    //
    //   "airpods max" → .airpodsMax
    //   "airpods pro" → .airpodsPro
    //   "airpods"     → .airpods
    //   "beats"       → .beats
    //   other         → defaultKind
    static func classify(name: String, defaultKind: ConnectedDeviceKind) -> ConnectedDeviceKind {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return .airpodsMax }
        if lowered.contains("airpods pro") { return .airpodsPro }
        if lowered.contains("airpods") { return .airpods }
        if lowered.contains("beats") { return .beats }
        return defaultKind
    }
}

struct ConnectedDevice: Codable, Sendable, Hashable, Identifiable {
    let kind: ConnectedDeviceKind
    let isConnected: Bool
    var name: String? = nil

    var id: ConnectedDeviceKind { kind }
}

enum ConnectedDeviceCatalog {
    static func devices(
        for role: ConnectedDeviceAppRole,
        peerConnected: Bool,
        deviceStatus: DeviceStatus
    ) -> [ConnectedDevice] {
        let headphoneDevice = ConnectedDevice(
            kind: deviceStatus.audioOutput?.kind ?? .headphonesBluetooth,
            isConnected: deviceStatus.audioOutput != nil,
            name: deviceStatus.audioOutput?.name
        )
        switch role {
        case .pilot:
            return [
                ConnectedDevice(kind: .iphone, isConnected: peerConnected),
                ConnectedDevice(kind: .appleWatch, isConnected: deviceStatus.isWatchConnected),
                headphoneDevice
            ]
        case .copilot:
            return [
                ConnectedDevice(kind: .computer, isConnected: peerConnected),
                ConnectedDevice(kind: .appleWatch, isConnected: deviceStatus.isWatchConnected)
            ]
        }
    }
}

struct WorkspaceState: Codable, Sendable {
    let workspaces: [WorkspaceSummary]
    let selectedWorkspaceID: UUID?
    // Optional so older companions can still exchange workspace snapshots.
    var workflowRuns: [BuildWorkflowRun]? = nil
}

struct SelectWorkspace: Codable, Sendable {
    let workspaceID: UUID
}
