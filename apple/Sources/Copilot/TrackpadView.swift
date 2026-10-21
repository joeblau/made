import SwiftUI

/// Sums per-event drag deltas so moves go out at most once per display frame
/// instead of once per 120 Hz gesture event. Delta summing is lossless: the
/// Pilot receiver applies each move additively to the current cursor position.
struct TrackpadMoveCoalescer: Sendable {
    /// Minimum spacing between coalesced sends (~one 60 Hz frame).
    static let sendInterval: Duration = .milliseconds(16)

    private var pendingDX: Float = 0
    private var pendingDY: Float = 0
    private var lastSend: ContinuousClock.Instant?

    var hasPendingDelta: Bool { pendingDX != 0 || pendingDY != 0 }

    /// Returns a move to send immediately, or nil when the delta was
    /// accumulated and the caller must guarantee one trailing flush.
    mutating func accumulate(
        dx: Float,
        dy: Float,
        now: ContinuousClock.Instant
    ) -> MouseMove? {
        pendingDX += dx
        pendingDY += dy
        if let lastSend, now - lastSend < Self.sendInterval { return nil }
        return take(now: now)
    }

    /// Drains any pending delta regardless of pacing (drag end, click, timer).
    mutating func flush(now: ContinuousClock.Instant) -> MouseMove? {
        hasPendingDelta ? take(now: now) : nil
    }

    private mutating func take(now: ContinuousClock.Instant) -> MouseMove {
        defer {
            pendingDX = 0
            pendingDY = 0
            lastSend = now
        }
        return MouseMove(dx: pendingDX, dy: pendingDY)
    }
}

struct TrackpadView: View {
    let syncService: PeerSyncService
    private let sensitivity: Float = 2.0
    @State private var lastTranslation: CGSize = .zero
    @State private var coalescer = TrackpadMoveCoalescer()
    @State private var trailingFlush: Task<Void, Never>?

    var body: some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                Text("Trackpad")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 200)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let dx = Float(value.translation.width - lastTranslation.width) * sensitivity
                        let dy = Float(value.translation.height - lastTranslation.height) * sensitivity
                        lastTranslation = value.translation
                        if let move = coalescer.accumulate(dx: dx, dy: dy, now: .now) {
                            trailingFlush?.cancel()
                            trailingFlush = nil
                            // Mid-drag deltas commute on the receiver and the
                            // replay window accepts out-of-order sequences, so
                            // unreliable delivery only risks losing a sliver of
                            // relative motion while avoiding the head-of-line
                            // blocking of the reliable ordered stream.
                            syncService.send(.mouseMove(move), reliable: false)
                        } else {
                            scheduleTrailingFlush()
                        }
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                        flushPendingMove()
                    }
            )
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                flushPendingMove()
                syncService.send(.mouseClick(MouseClick(button: 0)))
            }
            .onDisappear {
                trailingFlush?.cancel()
                trailingFlush = nil
            }
            .padding(.horizontal)
    }

    /// Guarantees the tail of a fast flick is sent even when no further drag
    /// event arrives to carry it.
    private func scheduleTrailingFlush() {
        guard trailingFlush == nil else { return }
        trailingFlush = Task { @MainActor in
            try? await Task.sleep(for: TrackpadMoveCoalescer.sendInterval)
            guard !Task.isCancelled else { return }
            trailingFlush = nil
            if let move = coalescer.flush(now: .now) {
                syncService.send(.mouseMove(move), reliable: false)
            }
        }
    }

    /// Final drag position must land before a subsequent click, so this flush
    /// rides the reliable ordered stream like the click itself.
    private func flushPendingMove() {
        trailingFlush?.cancel()
        trailingFlush = nil
        if let move = coalescer.flush(now: .now) {
            syncService.send(.mouseMove(move))
        }
    }
}

#Preview {
    TrackpadView(syncService: PeerSyncService(role: .browser, displayName: "Preview"))
}
