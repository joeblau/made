import ChromiumKit
import Combine
import Foundation
import SwiftUI

/// Checked-in Swift constants mirrored from
/// `apple/Packages/ChromiumKit/cef-artifacts.json`.
enum ChromiumArtifactRevision {
    static let releaseID = "150.0.14-g7c1aa68-chromium-150.0.7871.129-blau.1"
    static let cefVersion = "150.0.14+g7c1aa68+chromium-150.0.7871.129"
    static let cefCommit = "7c1aa68455db1f1fad159c2b83070ad318212b3d"
    static let chromiumVersion = "150.0.7871.129"
    static let chromiumCommit = "e69b30bba288603e514cffb4c79c359cac68e923"
}

enum ChromiumRuntimeStatus: Equatable, Sendable {
    case notStarted
    case starting
    case running
    case unavailable
    case rendererTerminated

    var displayName: String {
        switch self {
        case .notStarted: "Not started"
        case .starting: "Starting"
        case .running: "Running"
        case .unavailable: "Unavailable"
        case .rendererTerminated: "Renderer terminated"
        }
    }
}

/// Serializes all process-wide CEF profile access. Both methods are main-actor
/// isolated so no pane can start Chromium after a clear operation has reserved
/// the profile and before its detached filesystem work completes.
@MainActor
final class ChromiumProfileAccessCoordinator: ObservableObject {
    typealias ClearOperation = @Sendable (
        URL,
        ChromiumProfileLocation
    ) async throws -> Void

    static let shared = ChromiumProfileAccessCoordinator()

    @Published private(set) var isClearing = false

    private let clearOperation: ClearOperation

    private init() {
        clearOperation = Self.clearProfileOnDisk
    }

    init(clearOperation: @escaping ClearOperation) {
        self.clearOperation = clearOperation
    }

    func startEngine(profileDirectory: URL) throws {
        guard !isClearing else {
            throw ChromiumProfileSecurityError.profileClearInProgress
        }
        if !ChromiumEngine.shared.isRunning {
            // Extension directories must be handed over before start: CEF reads
            // the command line once during initialization, and the paths also
            // determine the chrome-extension:// origins the wallet UI is served
            // from, so they cannot change afterwards.
            ChromiumEngine.shared.setExtensionDirectories(
                WalletExtensionRegistry.discover().map(\.directory)
            )
            _ = try ChromiumEngine.shared.start(
                profileDirectory: profileDirectory
            )
        }
    }

    func clearProfile(
        at profileURL: URL,
        location: ChromiumProfileLocation
    ) async throws {
        guard !isClearing else {
            throw ChromiumProfileSecurityError.profileClearInProgress
        }
        guard !ChromiumEngine.shared.isRunning else {
            throw ChromiumBrowsingDataController.ClearError.runtimeRunning
        }
        guard location.isManagedProfileDirectory(profileURL) else {
            throw ChromiumBrowsingDataController.ClearError.profileUnavailable
        }

        isClearing = true
        defer { isClearing = false }
        try await clearOperation(profileURL, location)
    }

    private nonisolated static func clearProfileOnDisk(
        _ profileURL: URL,
        _ location: ChromiumProfileLocation
    ) async throws {
        try await Task.detached(priority: .utility) {
            guard location.isManagedProfileDirectory(profileURL) else {
                throw ChromiumBrowsingDataController.ClearError.profileUnavailable
            }
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: profileURL.path) {
                try fileManager.removeItem(at: profileURL)
            }
            try fileManager.createDirectory(
                at: profileURL,
                withIntermediateDirectories: true
            )
            guard location.isManagedProfileDirectory(profileURL) else {
                throw ChromiumBrowsingDataController.ClearError.profileUnavailable
            }
        }.value
    }
}

@MainActor
final class ChromiumDiagnosticsCenter: ObservableObject {
    static let shared = ChromiumDiagnosticsCenter()

    @Published private(set) var runtimeStatus: ChromiumRuntimeStatus = .notStarted
    @Published private(set) var lastInitializationFailure: ChromiumDiagnosticRecord?
    @Published private(set) var lastRendererTermination: ChromiumDiagnosticRecord?

    private init() {}

    func recordStarting() {
        runtimeStatus = .starting
    }

    func recordRunning() {
        runtimeStatus = .running
    }

    func recordInitializationFailure(_ diagnostic: ChromiumDiagnosticRecord) {
        lastInitializationFailure = diagnostic
        runtimeStatus = .unavailable
    }

    func recordRendererTermination(_ diagnostic: ChromiumDiagnosticRecord) {
        lastRendererTermination = diagnostic
        runtimeStatus = .rendererTerminated
    }

    func refreshRuntimeStatus() {
        if ChromiumEngine.shared.isRunning {
            runtimeStatus = .running
        } else if lastInitializationFailure != nil {
            runtimeStatus = .unavailable
        } else if lastRendererTermination != nil {
            runtimeStatus = .rendererTerminated
        } else {
            runtimeStatus = .notStarted
        }
    }
}

enum ChromiumBrowsingDataClearAvailability: Equatable, Sendable {
    case available
    case runtimeRunning
    case clearInProgress
    case profileUnavailable

    var unavailableReason: String? {
        switch self {
        case .available:
            nil
        case .runtimeRunning:
            "Close Chromium and relaunch Cockpit before clearing its browsing data."
        case .clearInProgress:
            "Cockpit is already clearing Chromium browsing data."
        case .profileUnavailable:
            "Cockpit could not resolve its managed Chromium profile."
        }
    }
}

enum ChromiumBrowsingDataController {
    enum ClearError: Error {
        case runtimeRunning
        case profileUnavailable
    }

    @MainActor
    static var availability: ChromiumBrowsingDataClearAvailability {
        if ChromiumProfileAccessCoordinator.shared.isClearing {
            return .clearInProgress
        }
        if ChromiumEngine.shared.isRunning {
            return .runtimeRunning
        }
        return managedProfileURL() == nil ? .profileUnavailable : .available
    }

    @MainActor
    static func clear() async throws {
        guard !ChromiumEngine.shared.isRunning else {
            throw ClearError.runtimeRunning
        }
        guard let profileURL = managedProfileURL() else {
            throw ClearError.profileUnavailable
        }
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ClearError.profileUnavailable
        }
        let location = ChromiumProfileLocation(
            applicationSupportDirectory: applicationSupport
        )
        try await ChromiumProfileAccessCoordinator.shared.clearProfile(
            at: profileURL,
            location: location
        )
    }

    @MainActor
    static var profileLocationCategory: String {
        managedProfileURL() == nil
            ? "Unavailable"
            : "Cockpit Application Support (isolated)"
    }

    @MainActor
    private static func managedProfileURL() -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let location = ChromiumProfileLocation(
            applicationSupportDirectory: applicationSupport
        )
        let profileURL = location.defaultProfileURL
        guard location.isManagedProfileDirectory(profileURL) else { return nil }
        return profileURL
    }
}

@MainActor
struct ChromiumDiagnosticsSettingsSection: View {
    @ObservedObject private var diagnostics = ChromiumDiagnosticsCenter.shared
    @State private var isConfirmingClear = false
    @State private var isClearing = false
    @State private var resultMessage: String?

    var body: some View {
        Section {
            LabeledContent("Release") {
                diagnosticValue(ChromiumArtifactRevision.releaseID)
            }
            LabeledContent("CEF") {
                diagnosticValue(ChromiumArtifactRevision.cefVersion)
            }
            LabeledContent("CEF commit") {
                diagnosticValue(ChromiumArtifactRevision.cefCommit)
            }
            LabeledContent("Chromium") {
                diagnosticValue(ChromiumArtifactRevision.chromiumVersion)
            }
            LabeledContent("Chromium commit") {
                diagnosticValue(ChromiumArtifactRevision.chromiumCommit)
            }
            LabeledContent("Runtime") {
                Text(diagnostics.runtimeStatus.displayName)
                    .foregroundStyle(runtimeTint)
            }
            LabeledContent("Profile") {
                Text(ChromiumBrowsingDataController.profileLocationCategory)
                    .foregroundStyle(.secondary)
            }

            if let diagnostic = diagnostics.lastInitializationFailure {
                LabeledContent("Last initialization failure") {
                    diagnosticValue(diagnostic.description)
                }
            }
            if let diagnostic = diagnostics.lastRendererTermination {
                LabeledContent("Last renderer termination") {
                    diagnosticValue(diagnostic.description)
                }
            }

            Button("Clear Chromium Browsing Data", role: .destructive) {
                isConfirmingClear = true
            }
            .disabled(clearAvailability != .available || isClearing)

            if let reason = clearAvailability.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Chromium", systemImage: "globe")
        } footer: {
            Text(
                "Chromium profiles are isolated from WebKit, workspaces, and system Chrome. "
                    + "Diagnostics omit credentials, URL details, headers, local paths, and page content."
            )
        }
        .onAppear {
            diagnostics.refreshRuntimeStatus()
        }
        .alert("Clear Chromium Browsing Data?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearBrowsingData()
            }
        } message: {
            Text("This removes the managed Chromium profile's cookies, cache, storage, and history.")
        }
        .alert(
            "Chromium Browsing Data",
            isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )
        ) {
            Button("OK") {
                resultMessage = nil
            }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var clearAvailability: ChromiumBrowsingDataClearAvailability {
        ChromiumBrowsingDataController.availability
    }

    private var runtimeTint: Color {
        switch diagnostics.runtimeStatus {
        case .running:
            .green
        case .unavailable, .rendererTerminated:
            .red
        case .notStarted, .starting:
            .secondary
        }
    }

    private func diagnosticValue(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
    }

    private func clearBrowsingData() {
        isClearing = true
        Task {
            do {
                try await ChromiumBrowsingDataController.clear()
                resultMessage = "Chromium browsing data was cleared."
            } catch {
                resultMessage = "Chromium browsing data could not be cleared."
            }
            isClearing = false
            diagnostics.refreshRuntimeStatus()
        }
    }
}
