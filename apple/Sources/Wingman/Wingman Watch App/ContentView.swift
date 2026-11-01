import SwiftUI

struct ContentView: View {
    let sessionDelegate: WatchSessionDelegate

    // Demo mode: when launched with ["-demoMode", "YES"] the app
    // short-circuits live connectivity and renders representative
    // fixture content so screenshots show a healthy connected state
    // with no live peer. A normal launch (no arg) leaves this false
    // and the regular path is completely unchanged.
    private let isDemoMode = UserDefaults.standard.bool(forKey: "demoMode")

    @State private var currentGesture: String = "Waiting…"
    @State private var currentIcon: String = "hand.raised"

    private var isConnected: Bool {
        isDemoMode || sessionDelegate.isReachable
    }

    var body: some View {
        NavigationStack {
            // One scrolling column instead of a fixed stack plus a pinned
            // footer: at accessibility sizes the fixed stack pushed the
            // gesture glyph up under the "Trigger" title, and a pinned
            // footer overlapped the delivery line (TYPE-4).
            ScrollView {
                VStack {
                    gestureDisplay
                    Text(sessionDelegate.deliveryStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // Delivery state cross-fades instead of hard-cutting (MOT-4).
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: sessionDelegate.deliveryStatus)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                            // The adjacent text already speaks the state.
                            .accessibilityHidden(true)
                        Text(isConnected ? "Walkie Connected" : "Walkie Disconnected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            }
            .navigationTitle("Trigger")
            .onAppear {
                if isDemoMode {
                    currentGesture = "Double Pinch"
                    currentIcon = "hand.pinch.fill"
                }
            }
        }
        // The asset-catalog AccentColor is empty and not wired as the global
        // accent, so the tint falls back to a neutral gray and the gesture
        // glyph and prominent Send button read as secondary text. Use the
        // same system blue as Walkie's accent so the one primary action
        // stands out (BTN-1, COL-4). The navigation title still follows the
        // (empty) asset accent; giving the asset a color is a brand decision.
        .tint(.blue)
    }

    // MARK: - Current Gesture Display

    private var gestureDisplay: some View {
        VStack(spacing: 8) {
            VStack(spacing: 4) {
                Image(systemName: currentIcon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))

                Text(currentGesture)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            // Drives the symbol replace and the label cross-fade on each
            // recorded gesture (MOT-4).
            .animation(.spring(duration: 0.3, bounce: 0.15), value: currentIcon)

            Button {
                triggerDoublePinch(source: "button")
            } label: {
                Label("Send to Walkie", systemImage: "hand.pinch.fill")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            // Standard watchOS 26 primary control: prominent Liquid Glass,
            // capsule by default (no manual clip).
            .buttonStyle(.glassProminent)
            .handGestureShortcut(.primaryAction)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func record(_ name: String, icon: String) {
        currentGesture = name
        currentIcon = icon
    }

    private func triggerDoublePinch(source: String) {
        record("Double Pinch", icon: "hand.pinch")
        sessionDelegate.sendDoublePinch(source: source)
    }
}

#Preview {
    ContentView(sessionDelegate: WatchSessionDelegate())
}
