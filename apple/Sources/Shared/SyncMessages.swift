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

extension AnnotationColor {
    /// A wire color from platform color components, clamped into the `0...1`
    /// range ``FrameProtocol`` accepts (a non-finite component becomes `0`).
    /// `UIColor.getRed(_:green:blue:alpha:)` reports extended-sRGB components
    /// outside `0...1` for the wide-gamut (Display P3) colors `PKToolPicker`
    /// offers; unclamped, such a stroke could never be encoded and Pilot's
    /// mirror would fail closed for an ordinary drawing (issue #431).
    static func normalized(red: Double, green: Double, blue: Double, alpha: Double) -> AnnotationColor {
        func unit(_ component: Double) -> Double {
            component.isFinite ? min(1, max(0, component)) : 0
        }
        return AnnotationColor(red: unit(red), green: unit(green), blue: unit(blue), alpha: unit(alpha))
    }
}

extension AnnotationStroke {
    /// The wire `width` for a pen `penWidth` points wide drawn over a video
    /// content rect `contentWidth` x `contentHeight` points: a fraction of the
    /// rect's shorter side, clamped into what ``FrameProtocol`` accepts so a
    /// real stroke is never refused for its width (issue #431).
    static func normalizedWidth(penWidth: Double, contentWidth: Double, contentHeight: Double) -> Double {
        let range = FrameProtocol.annotationStrokeWidthRange
        let scaleBase = max(1, min(contentWidth, contentHeight))
        let width = max(1.5, penWidth.isFinite ? penWidth : 1.5) / scaleBase
        return min(range.upperBound, max(range.lowerBound, width))
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

/// Keeps Pilot's mirrored ink identical, index for index, to Plotter's drawing
/// (issue #431). Pilot applies `.addStroke` as an append and `.undo` as "drop
/// the last stroke", so those incremental messages are only correct when the
/// change provably is exactly that. PencilKit's eraser, undoing an erase, and
/// stroke splits change the drawing in the middle, so any change that is not a
/// provable append or last-stroke removal resends the whole drawing.
///
/// An instance is Plotter's record of what Pilot holds. It advances only when
/// every message of a change was actually handed to the link (`send` returned
/// `true`), and it never sends a message that Pilot's `RemoteInkModel` would
/// reject for its total stroke/point ceilings.
///
/// A drawing within those ceilings can still be too large to encode as one
/// `.replaceDrawing` (`maxAnnotationBytes` is reached at roughly 23k
/// full-precision points, well under the 100k point ceiling). Such a drawing
/// is delivered as `.clear` followed by one `.addStroke` per stroke, which
/// Pilot applies as an exact rebuild (`.clear` also ends Pilot's post-rejection
/// quarantine) with each stroke its own undo entry.
///
/// When a change cannot be mirrored at all (the drawing is over Pilot's
/// ceilings, or one of its strokes is too large to encode on its own), it
/// fails closed: it sends a `.clear` so Pilot shows no ink rather than ink
/// that no longer matches, marks itself out of sync, and sends nothing
/// incremental until a full rebuild (a replacement, or a clear and every
/// stroke) succeeds. A stroke-by-stroke rebuild is preflighted, so a doomed
/// one sends only that single fail-closed `.clear`, never a prefix of the
/// drawing.
struct AnnotationMirrorSync {
    /// The strokes Pilot holds after every message handed to the link so far.
    private(set) var mirrored: [AnnotationStroke] = []
    /// True while Pilot does not mirror the canvas because a change could not
    /// be delivered; the next change or resync attempts a full rebuild.
    private(set) var isOutOfSync = false

    /// Whether Pilot's `RemoteInkModel` accepts `strokes` as its whole drawing:
    /// the same total ceilings it enforces on `.replaceDrawing` and on the
    /// running total of `.addStroke`.
    static func fitsPilotLimits(_ strokes: [AnnotationStroke]) -> Bool {
        guard strokes.count <= FrameProtocol.maxAnnotationStrokes else { return false }
        var points = 0
        for stroke in strokes {
            points += stroke.points.count
            if points > FrameProtocol.maxAnnotationPoints { return false }
        }
        return true
    }

    /// Records `strokes` as already held by Pilot without sending anything
    /// (seeded demo content, which has no peer).
    mutating func assumeMirrored(_ strokes: [AnnotationStroke]) {
        mirrored = strokes
        isOutOfSync = false
    }

    /// Sends what makes Pilot's ink match `current`, if anything: one
    /// incremental message for a provable append or last-stroke removal,
    /// otherwise a full rebuild. While out of sync it is always a full rebuild.
    mutating func sync(to current: [AnnotationStroke], send: (AnnotationMessage) -> Bool) {
        if isOutOfSync {
            resync(to: current, send: send)
            return
        }
        guard let message = Self.message(from: mirrored, to: current) else { return }
        deliver(message, producing: current, send: send)
    }

    /// Replaces Pilot's ink with `current`, unconditionally: one
    /// `.replaceDrawing`, or a clear and every stroke when that is too large.
    mutating func resync(to current: [AnnotationStroke], send: (AnnotationMessage) -> Bool) {
        deliver(.replaceDrawing(AnnotationDrawing(strokes: current)), producing: current, send: send)
    }

    /// Empties Pilot's ink.
    mutating func clear(send: (AnnotationMessage) -> Bool) {
        deliver(.clear, producing: [], send: send)
    }

    private mutating func deliver(
        _ message: AnnotationMessage,
        producing current: [AnnotationStroke],
        send: (AnnotationMessage) -> Bool
    ) {
        if Self.fitsPilotLimits(current) {
            if send(message) || (Self.isReplacement(message) && Self.rebuild(current, send: send)) {
                mirrored = current
                isOutOfSync = false
                return
            }
        }
        // Fail closed: `mirrored` is not advanced past an undelivered or
        // rejectable message, so nothing incremental may follow it.
        isOutOfSync = true
        if send(.clear) { mirrored = [] }
    }

    private static func isReplacement(_ message: AnnotationMessage) -> Bool {
        if case .replaceDrawing = message { return true }
        return false
    }

    /// Whether `message` passes ``FrameProtocol``'s per-message validation and
    /// `maxAnnotationBytes`: exactly what `FrameReceiver.sendAnnotation` checks
    /// before it hands a message to the link.
    static func isEncodable(_ message: AnnotationMessage) -> Bool {
        !FrameProtocol.encode(.annotation(seq: 0, message: message)).isEmpty
    }

    /// Rebuilds Pilot's ink as `strokes` one message at a time, for a drawing
    /// within Pilot's ceilings (the caller checks them) that is too large for
    /// a single replacement. Nothing is sent unless every stroke is
    /// individually encodable, so a rebuild that cannot finish never clears
    /// Pilot and replays a prefix of the drawing. Returns `true` only if every
    /// message was handed to the link; on `false` Pilot may hold a prefix of
    /// `strokes` (the link refused mid-rebuild), so the caller must fail
    /// closed.
    private static func rebuild(_ strokes: [AnnotationStroke], send: (AnnotationMessage) -> Bool) -> Bool {
        guard strokes.allSatisfy({ Self.isEncodable(.addStroke($0)) }) else { return false }
        guard send(.clear) else { return false }
        for stroke in strokes where !send(.addStroke(stroke)) {
            return false
        }
        return true
    }

    /// The single message that turns Pilot's `mirrored` strokes into `current`,
    /// or nil when they already match.
    static func message(
        from mirrored: [AnnotationStroke],
        to current: [AnnotationStroke]
    ) -> AnnotationMessage? {
        if current == mirrored { return nil }
        if current.count == mirrored.count + 1,
           let appended = current.last,
           current.dropLast().elementsEqual(mirrored) {
            return .addStroke(appended)
        }
        if current.count + 1 == mirrored.count,
           mirrored.dropLast().elementsEqual(current) {
            return .undo
        }
        if current.isEmpty { return .clear }
        return .replaceDrawing(AnnotationDrawing(strokes: current))
    }
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
    var actionsDashboard: ActionsDashboardSnapshot? = nil
    var usageDashboard: UsageDashboardSnapshot? = nil
    var runnersDashboard: RunnersDashboardSnapshot? = nil
}

struct SelectWorkspace: Codable, Sendable {
    let workspaceID: UUID
}
