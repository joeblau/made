import SwiftUI

struct DroneTerminalView: View {
    let pane: Pane

    @State private var presentation: DroneTerminalPresentation
    @State private var input = ""

    init(pane: Pane) {
        self.pane = pane
        _presentation = State(initialValue: DroneTerminalPresentation(pane: pane))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(pane.terminalDestination.droneName ?? "Drone", systemImage: "server.rack")
                Spacer()
                Text(presentation.status)
                    .foregroundStyle(presentation.isConnected ? .secondary : Color.orange)
            }
            .font(.caption)
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(presentation.contents.isEmpty ? "Waiting for remote output…" : presentation.contents)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("terminal-output")
                }
                .background(Color.black.opacity(0.92))
                .foregroundStyle(.white)
                .onChange(of: presentation.contents) {
                    proxy.scrollTo("terminal-output", anchor: .bottom)
                }
            }

            HStack {
                TextField("Remote command", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(!presentation.isConnected)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(!presentation.isConnected || input.isEmpty)
            }
            .padding(8)
        }
        .task(id: pane.id) { presentation.start() }
        .onDisappear { presentation.stop() }
    }

    private func send() {
        guard !input.isEmpty else { return }
        let command = input
        input = ""
        Task {
            if await presentation.send(command) == false, input.isEmpty { input = command }
        }
    }
}
