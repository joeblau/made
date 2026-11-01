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
            VStack {
                gestureDisplay
                    .frame(maxHeight: .infinity)
                Text(sessionDelegate.deliveryStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Trigger")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(isConnected ? "Walkie Connected" : "Walkie Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .onAppear {
                if isDemoMode {
                    currentGesture = "Double Pinch"
                    currentIcon = "hand.pinch.fill"
                }
            }
        }
    }

    // MARK: - Current Gesture Display

    private var gestureDisplay: some View {
        VStack(spacing: 8) {
            VStack(spacing: 4) {
                Image(systemName: currentIcon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))

                Text(currentGesture)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
