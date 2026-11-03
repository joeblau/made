import AppKit
import SwiftUI

struct DroneSettingsView: View {
    @Bindable var store: DroneStore
    @State private var showsManualPairing = false
    @State private var editingDrone: DroneRecord?
    @State private var diagnosticsDrone: DroneRecord?
    @State private var dronePendingForget: DroneRecord?
    @State private var actionError: String?

    var body: some View {
        Form {
            PilotSettingsPageHeader(
                title: "Drones",
                subtitle: "Pair and supervise secure remote execution workers on your local network.",
                systemImage: "server.rack",
                tint: .blue
            )

            if let persistenceError = store.persistenceError {
                Section {
                    Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if !store.pairingRequests.isEmpty {
                Section("Pairing Approval") {
                    ForEach(Array(store.pairingRequests.values).sorted(by: {
                        $0.peerID.rawValue.uuidString < $1.peerID.rawValue.uuidString
                    })) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.isKeyChange ? "This Drone’s identity changed. Verify before approving." : "Verify this code on both Macs before approving.")
                            Text(request.verificationCode)
                                .font(.title3.monospaced())
                                .textSelection(.enabled)
                            HStack {
                                Button("Approve") { store.resolvePairing(requestID: request.id, approved: true) }
                                Button("Reject", role: .destructive) {
                                    store.resolvePairing(requestID: request.id, approved: false)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                if store.records.isEmpty {
                    Text("No saved Drones. Pair a discovered worker or add one by address.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.records) { record in
                        DroneSavedRow(
                            record: record,
                            state: store.states[record.id] ?? .pairing,
                            isForgetting: store.forgettingIDs.contains(record.id),
                            retry: { store.retry(id: record.id) },
                            rename: { editingDrone = record },
                            diagnostics: { diagnosticsDrone = record },
                            forget: { dronePendingForget = record }
                        )
                    }
                }
            } header: {
                Text("Saved Drones (\(store.records.count)/\(DroneLimits.maxPairedWorkers))")
            } footer: {
                Text("Offline and unauthorized Drones stay listed. Cockpit never substitutes Local when a Drone is unavailable.")
            }

            Section {
                switch store.discovery.browseState {
                case .idle:
                    ProgressView().controlSize(.small)
                case .browsing:
                    EmptyView()
                case .needsPermission(let message), .failed(let message):
                    Label(message, systemImage: "wifi.exclamationmark")
                    Button("Retry Discovery") { store.discovery.retry() }
                }
                ForEach(store.availableCandidates) { candidate in
                    LabeledContent {
                        Button("Pair") {
                            do {
                                _ = try store.pair(candidate)
                                actionError = nil
                            } catch {
                                actionError = Self.describe(error)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.displayName)
                            Text(candidate.advertisedProtocolVersions.isEmpty
                                 ? "Unverified Bonjour candidate"
                                 : "Unverified · advertises protocol \(candidate.advertisedProtocolVersions.map(String.init).joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if store.availableCandidates.isEmpty {
                    Text("No unpaired Drone advertisements found.")
                        .foregroundStyle(.secondary)
                }
                Button("Add by Address…") { showsManualPairing = true }
            } header: {
                Text("Discover")
            } footer: {
                Text("Bonjour names, addresses, and protocol advertisements are hints only. A Drone becomes connected only after authenticated identity and capability negotiation.")
            }
        }
        .formStyle(.grouped)
        .onAppear { store.startDiscovery() }
        .onDisappear { store.stopDiscovery() }
        .sheet(isPresented: $showsManualPairing) {
            DroneManualPairSheet { name, host, port in
                do {
                    _ = try store.addManual(name: name, host: host, port: port)
                    actionError = nil
                    return nil
                } catch {
                    return Self.describe(error)
                }
            }
        }
        .sheet(item: $editingDrone) { record in
            DroneRenameSheet(currentName: record.name) { name in
                do {
                    try store.rename(id: record.id, to: name)
                    actionError = nil
                    return nil
                } catch {
                    return Self.describe(error)
                }
            }
        }
        .sheet(item: $diagnosticsDrone) { record in
            DroneDiagnosticsView(
                record: record,
                state: store.states[record.id] ?? .pairing,
                diagnostics: store.diagnostics[record.id] ?? DroneDiagnostics()
            )
        }
        .confirmationDialog(
            "Forget and Revoke Drone?",
            isPresented: Binding(
                get: { dronePendingForget != nil },
                set: { if !$0 { dronePendingForget = nil } }
            )
        ) {
            if let record = dronePendingForget {
                Button("Forget and Revoke", role: .destructive) {
                    Task { await store.forget(id: record.id) }
                }
                Button("Cancel", role: .cancel) { dronePendingForget = nil }
            }
        } message: {
            if let record = dronePendingForget {
                Text("This closes \(record.name), removes its saved metadata, and deletes its local pairing pin. Remote sessions are not terminated.")
            }
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? DroneRegistryError {
        case .invalidName:
            "Enter a name between 1 and 80 UTF-8 bytes."
        case .invalidEndpoint:
            "Enter a valid hostname or IP address and a port from 1 to 65535."
        case .registryFull:
            "Cockpit supports at most \(DroneLimits.maxPairedWorkers) saved Drones."
        case .duplicateDrone:
            "This discovered Drone is already saved."
        case .persistenceUnavailable:
            "The saved registry is read-only because it could not be loaded."
        default:
            "Cockpit could not save the Drone registry. Check disk permissions and available space."
        }
    }
}

private struct DroneSavedRow: View {
    let record: DroneRecord
    let state: DroneConnectionState
    let isForgetting: Bool
    let retry: () -> Void
    let rename: () -> Void
    let diagnostics: () -> Void
    let forget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name).font(.headline)
                    if !record.hardware.displayText.isEmpty {
                        Text(record.hardware.displayText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(record.endpoints.map(\.displayText).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Label(status.title, systemImage: status.symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(status.tint)
            }
            Text(status.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Retry", action: retry)
                    .disabled(isForgetting)
                Button("Diagnostics", action: diagnostics)
                Menu("Manage") {
                    Button("Rename…", action: rename)
                    Button("Forget and Revoke…", role: .destructive, action: forget)
                }
                .disabled(isForgetting)
                if isForgetting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var status: (title: String, detail: String, symbol: String, tint: Color) {
        switch state {
        case .pairing:
            return ("Pairing required", DroneConnectionIssue.pairingRequired.recoveryInstruction, "person.badge.key", Color.orange)
        case .connecting(let attempt):
            return ("Connecting", "Identity and protocol probe, attempt \(attempt). Nothing is sent before authentication.", "arrow.triangle.2.circlepath", Color.blue)
        case .connected(let peer):
            let version = peer.hello.selectedVersion.map(String.init) ?? "unknown"
            let capabilities = peer.hello.capabilities.joined(separator: ", ")
            return ("Connected", "Protocol \(version) · \(capabilities)", "checkmark.circle.fill", Color.green)
        case .offline(let issue, let retryAttempt):
            let retry = retryAttempt.map { " Automatic retry \($0) is scheduled." } ?? ""
            return (issue.title, issue.recoveryInstruction + retry, "wifi.slash", Color.orange)
        case .unauthorized(let issue):
            return (issue.title, issue.recoveryInstruction, "lock.shield", Color.red)
        case .incompatible:
            return ("Incompatible", DroneConnectionIssue.incompatible.recoveryInstruction, "exclamationmark.triangle.fill", Color.red)
        case .busy(let attempt):
            return ("Busy", "\(DroneConnectionIssue.busy.recoveryInstruction) Retry \(attempt) is scheduled.", "hourglass", Color.orange)
        case .forgetting:
            return ("Forgetting", "Closing the connection and revoking the local pin.", "minus.circle", Color.gray)
        }
    }
}

private struct DroneManualPairSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var error: String?
    let save: (String, String, String) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Drone by Address").font(.title2.bold())
            Text("The address is only a connection hint. Pairing and pinned identity verification are required before work can be sent.")
                .foregroundStyle(.secondary)
            TextField("Display name (optional)", text: $name)
            TextField("Hostname or IP address", text: $host)
            TextField("Port", text: $port)
                .frame(width: 120)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add and Pair") {
                    if let error = save(name, host, port) {
                        self.error = error
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || port.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct DroneRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    let save: (String) -> String?

    init(currentName: String, save: @escaping (String) -> String?) {
        _name = State(initialValue: currentName)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Drone").font(.title2.bold())
            TextField("Display name", text: $name)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    if let error = save(name) {
                        self.error = error
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

private struct DroneDiagnosticsView: View {
    let record: DroneRecord
    let state: DroneConnectionState
    let diagnostics: DroneDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(record.name) Diagnostics").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Text("Drone ID"); Text(record.id.uuidString).textSelection(.enabled) }
                GridRow { Text("State"); Text(String(describing: state)) }
                GridRow { Text("Generation"); Text(String(diagnostics.generation)) }
                GridRow { Text("Connect attempts"); Text(String(diagnostics.connectAttempts)) }
                GridRow { Text("Successful connections"); Text(String(diagnostics.successfulConnections)) }
                GridRow { Text("Verified identity"); Text(record.verifiedIdentityFingerprint ?? "Not paired") }
                GridRow { Text("Endpoint"); Text(diagnostics.lastEndpoint?.displayText ?? "None") }
                GridRow { Text("Last issue"); Text(diagnostics.lastIssue?.title ?? "None") }
            }
            .font(.callout)
            Text("Recent non-secret events").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(diagnostics.entries.enumerated()), id: \.offset) { _, entry in
                        Text("\(entry.timestamp.formatted(date: .omitted, time: .standard)) · \(entry.event)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticText, forType: .string)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 500)
    }

    private var diagnosticText: String {
        let header = [
            "Drone: \(record.name)",
            "Drone ID: \(record.id.uuidString)",
            "State: \(state)",
            "Generation: \(diagnostics.generation)",
            "Connect attempts: \(diagnostics.connectAttempts)",
            "Successful connections: \(diagnostics.successfulConnections)",
            "Verified identity: \(record.verifiedIdentityFingerprint ?? "Not paired")",
            "Endpoint: \(diagnostics.lastEndpoint?.displayText ?? "None")",
            "Last issue: \(diagnostics.lastIssue?.title ?? "None")",
        ]
        let entries = diagnostics.entries.map {
            "\($0.timestamp.formatted(date: .omitted, time: .standard)) · \($0.event)"
        }
        return (header + entries).joined(separator: "\n")
    }
}
