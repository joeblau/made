import Foundation
import Network

enum TranscriptionNetworkStatus: Sendable, Equatable {
    case unknown
    case offline
    case unmetered
    case expensive
    case constrained
}

enum TranscriptionModelPreparation: Equatable {
    case loadCached(SpeechModelCache.Entry)
    case download
}

enum TranscriptionModelPreparationError: LocalizedError, Equatable {
    case networkStatusUnavailable
    case offline
    case expensiveNetwork
    case constrainedNetwork

    var errorDescription: String? {
        switch self {
        case .networkStatusUnavailable:
            "The iPhone is still checking the network. Wait a moment and retry the speech-model download."
        case .offline:
            "The speech model is not cached and the iPhone is offline. Connect to Wi-Fi and retry."
        case .expensiveNetwork:
            "The speech model is about 630 MB. Connect to Wi-Fi or choose Use Cellular when you retry."
        case .constrainedNetwork:
            "Low Data Mode is active. Connect to an unrestricted network or explicitly allow this download."
        }
    }
}

struct TranscriptionDownloadPolicy {
    static func preparation(
        cachedEntry: SpeechModelCache.Entry?,
        network: TranscriptionNetworkStatus,
        allowRestrictedNetwork: Bool
    ) throws -> TranscriptionModelPreparation {
        if let cachedEntry {
            return .loadCached(cachedEntry)
        }
        switch network {
        case .offline:
            throw TranscriptionModelPreparationError.offline
        case .expensive where !allowRestrictedNetwork:
            throw TranscriptionModelPreparationError.expensiveNetwork
        case .constrained where !allowRestrictedNetwork:
            throw TranscriptionModelPreparationError.constrainedNetwork
        case .unknown:
            throw TranscriptionModelPreparationError.networkStatusUnavailable
        case .unmetered, .expensive, .constrained:
            return .download
        }
    }
}

final class TranscriptionNetworkObserver: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "app.blau.copilot.transcription-network")
    private let lock = NSLock()
    private var value: TranscriptionNetworkStatus = .unknown

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let next: TranscriptionNetworkStatus
            if path.status != .satisfied {
                next = .offline
            } else if path.isConstrained {
                next = .constrained
            } else if path.isExpensive {
                next = .expensive
            } else {
                next = .unmetered
            }
            self?.lock.withLock { self?.value = next }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var status: TranscriptionNetworkStatus {
        lock.withLock { value }
    }
}

/// Parakeet has its own cache; Whisper weights and tokenizer files cannot be reused.
struct SpeechModelCache: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let modelFolder: URL
    }

    static let modelName = "parakeet-ultra-coreml"
    static let displayName = "Parakeet v3 Ultra"
    static let downloadSize = "About 630 MB"
    static let requiredModelNames = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    static let vocabularyName = "parakeet_vocab.json"

    let documentsURL: URL
    let fileManager: FileManager

    init(documentsURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.documentsURL = documentsURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    var modelFolder: URL {
        documentsURL.appendingPathComponent("speech-models", isDirectory: true)
            .appendingPathComponent(Self.modelName, isDirectory: true)
    }

    var validEntry: Entry? {
        let entry = Entry(modelFolder: modelFolder)
        return isComplete(entry) ? entry : nil
    }

    // Count partial downloads too, so failed transfers can be removed in Settings.
    var storedBytes: Int64 { bytes(in: modelFolder) }

    func remove() throws {
        if fileManager.fileExists(atPath: modelFolder.path) {
            try fileManager.removeItem(at: modelFolder)
        }
    }

    func isComplete(_ entry: Entry) -> Bool {
        guard entry.modelFolder.standardizedFileURL == modelFolder.standardizedFileURL else { return false }
        for name in Self.requiredModelNames {
            let component = modelFolder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                guard let values = try? component.appendingPathComponent(file)
                    .resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return false }
            }
        }
        guard let data = try? Data(contentsOf: modelFolder.appendingPathComponent(Self.vocabularyName)),
              let vocabulary = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        // Ultra uses the v3 vocabulary: every token before blank ID 8192 must exist.
        return (0..<8192).allSatisfy { vocabulary[String($0)] != nil }
    }

    private func bytes(in root: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

struct TranscriptionLoadGate {
    private(set) var isLoading = false

    mutating func begin() -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        return true
    }

    mutating func finish() {
        isLoading = false
    }

    mutating func cancel() {
        isLoading = false
    }
}
