import ChromiumKit
import Combine
import Foundation
import AppKit

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
final class ChromiumDiagnosticsViewController: NSViewController {
    private let diagnostics = ChromiumDiagnosticsCenter.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var clearTask: Task<Void, Never>?
    private let runtime = BrowserNativeUI.label("")
    private let initialization = BrowserNativeUI.label("", secondary: true)
    private let termination = BrowserNativeUI.label("", secondary: true)
    private let reason = BrowserNativeUI.label("", secondary: true)
    private let result = BrowserNativeUI.label("", secondary: true)
    private var clearButton: BrowserNativeButton!

    init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let title = BrowserNativeUI.label("Chromium")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(title)
        let values = [
            ("Release", ChromiumArtifactRevision.releaseID),
            ("CEF", ChromiumArtifactRevision.cefVersion),
            ("CEF commit", ChromiumArtifactRevision.cefCommit),
            ("Chromium", ChromiumArtifactRevision.chromiumVersion),
            ("Chromium commit", ChromiumArtifactRevision.chromiumCommit),
            ("Profile", ChromiumBrowsingDataController.profileLocationCategory)
        ]
        for (name, value) in values {
            let label = BrowserNativeUI.label(name + ": " + value, secondary: true)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.isSelectable = true
            stack.addArrangedSubview(label)
        }
        [runtime, initialization, termination].forEach { stack.addArrangedSubview($0) }
        clearButton = BrowserNativeButton("Clear Chromium Browsing Data…") { [weak self] in self?.confirmClear() }
        stack.addArrangedSubview(clearButton)
        stack.addArrangedSubview(reason)
        stack.addArrangedSubview(result)
        stack.addArrangedSubview(BrowserNativeUI.label(
            "Chromium profiles are isolated from WebKit, workspaces, and system Chrome. Diagnostics omit credentials, URL details, headers, local paths, and page content.", secondary: true))
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        diagnostics.refreshRuntimeStatus()
        diagnostics.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronize() }
        }.store(in: &subscriptions)
        ChromiumProfileAccessCoordinator.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronize() }
        }.store(in: &subscriptions)
        synchronize()
    }

    private func synchronize() {
        runtime.stringValue = "Runtime: " + diagnostics.runtimeStatus.displayName
        initialization.stringValue = diagnostics.lastInitializationFailure.map { "Last initialization failure: " + $0.description } ?? ""
        initialization.isHidden = diagnostics.lastInitializationFailure == nil
        termination.stringValue = diagnostics.lastRendererTermination.map { "Last renderer termination: " + $0.description } ?? ""
        termination.isHidden = diagnostics.lastRendererTermination == nil
        let availability = ChromiumBrowsingDataController.availability
        clearButton.isEnabled = availability == .available && clearTask == nil
        reason.stringValue = availability.unavailableReason ?? ""
        reason.isHidden = reason.stringValue.isEmpty
        result.isHidden = result.stringValue.isEmpty
    }

    private func confirmClear() {
        guard clearTask == nil, ChromiumBrowsingDataController.availability == .available else { return }
        let alert = NSAlert()
        alert.messageText = "Clear Chromium Browsing Data?"
        alert.informativeText = "This removes the managed Chromium profile's cookies, cache, storage, and history."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        BrowserNativeUI.present(alert, for: view) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            self.clearTask = Task { @MainActor [weak self] in
                do {
                    try await ChromiumBrowsingDataController.clear()
                    self?.result.stringValue = "Chromium browsing data was cleared."
                } catch {
                    self?.result.stringValue = "Chromium browsing data could not be cleared."
                }
                self?.clearTask = nil
                self?.diagnostics.refreshRuntimeStatus()
                self?.synchronize()
            }
            self.synchronize()
        }
    }

    isolated deinit { clearTask?.cancel() }
}
