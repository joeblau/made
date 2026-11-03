import Darwin
import Foundation

final class DroneLog: @unchecked Sendable {
    static let maximumLimit = 256 * 1_024

    private let lock = NSLock()
    private let file: URL
    private let rotatedFile: URL
    private let limit: Int

    init(paths: DronePaths) {
        file = paths.logs.appendingPathComponent("droned.log")
        rotatedFile = paths.logs.appendingPathComponent("droned.log.1")
        limit = paths.logLimit
    }

    init(file: URL, limit: Int = DroneLog.maximumLimit) {
        self.file = file
        rotatedFile = file.appendingPathExtension("1")
        self.limit = max(1, limit)
    }

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        let safeEvent = String(event.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }.prefix(128))
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(safeEvent)\n".utf8)
        do {
            try prepareForWrite(line.count)
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw DroneWorkerError.operationFailed }
            defer { _ = Darwin.close(descriptor) }
            try DroneFileSystem.setMode(0o600, for: file)
            try DroneUnixSocket.writeAll(line, to: descriptor)
        } catch {
            return
        }
    }

    func totalSize() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return [file, rotatedFile].reduce(0) { total, url in
            total + size(of: url)
        }
    }

    func isBounded() -> Bool {
        totalSize() <= limit * 2
    }

    private func prepareForWrite(_ incomingBytes: Int) throws {
        guard size(of: file) + incomingBytes > limit else { return }
        if FileManager.default.fileExists(atPath: rotatedFile.path) {
            try FileManager.default.removeItem(at: rotatedFile)
        }
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.moveItem(at: file, to: rotatedFile)
            try DroneFileSystem.setMode(0o600, for: rotatedFile)
        }
    }

    private func size(of url: URL) -> Int {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return Int(clamping: info.st_size)
    }
}
