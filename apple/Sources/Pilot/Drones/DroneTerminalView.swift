import SwiftUI

struct DroneTerminalView: View {
    let pane: Pane

    @State private var contents = ""
    @State private var input = ""
    @State private var status = "Connecting…"
    @State private var isConnected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(pane.terminalDestination.droneName ?? "Drone", systemImage: "server.rack")
                Spacer()
                Text(status)
                    .foregroundStyle(isConnected ? .secondary : Color.orange)
            }
            .font(.caption)
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(contents.isEmpty ? "Waiting for remote output…" : contents)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("terminal-output")
                }
                .background(Color.black.opacity(0.92))
                .foregroundStyle(.white)
                .onChange(of: contents) {
                    proxy.scrollTo("terminal-output", anchor: .bottom)
                }
            }

            HStack {
                TextField("Remote command", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(!isConnected)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(!isConnected || input.isEmpty)
            }
            .padding(8)
        }
        .task(id: pane.id) {
            do {
                let session = pane.terminalSession
                _ = try await pane.restoreTerminalSession()
                contents = session.visibleContents() ?? ""
                await session.setOutputHandler { updated in
                    Task { @MainActor in contents = updated }
                }
                isConnected = true
                status = "Connected"
            } catch {
                isConnected = false
                status = "Unavailable: \(String(describing: error))"
            }
        }
    }

    private func send() {
        guard !input.isEmpty else { return }
        let command = input
        input = ""
        Task {
            let session = pane.terminalSession
            guard await session.send(.literal(command)) else {
                status = "Input failed"
                return
            }
            _ = await session.send(.enter)
        }
    }
}
