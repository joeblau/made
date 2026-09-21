import SwiftUI

struct TrackpadView: View {
    let syncService: PeerSyncService
    private let sensitivity: Float = 2.0
    @State private var lastTranslation: CGSize = .zero

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
                        syncService.send(.mouseMove(MouseMove(dx: dx, dy: dy)))
                    }
                    .onEnded { _ in lastTranslation = .zero }
            )
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                syncService.send(.mouseClick(MouseClick(button: 0)))
            }
            .padding(.horizontal)
    }
}

#Preview {
    TrackpadView(syncService: PeerSyncService(role: .browser, displayName: "Preview"))
}
