import Darwin
import Foundation

enum AirPlayReceiverStatus: Equatable, Sendable {
    case starting, waiting, pairing(String), streaming, stopped, failed(String)
}

/// Owns one child and one pipe. All blocking/decoding work stays on a dedicated
/// queue. The UI reads a single locked snapshot; frame traffic cannot flood it
/// with tasks. Stop is a flag, never a synchronous wait or library thread join.
final class AirPlayReceiverWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var status: AirPlayReceiverStatus = .starting
    private var finished = false

    var snapshot: AirPlayReceiverStatus { lock.withLock { status } }
    var isFinished: Bool { lock.withLock { finished } }
    func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }
    private func publish(_ value: AirPlayReceiverStatus) { lock.withLock { status = value } }

    func start(executable: URL, name: String, renderer: AirPlayVideoRenderer) {
        run(executable: executable, arguments: ["--receive", name], consume: renderer.consume, cleanup: renderer.reset)
    }

    /// Injectable command and consumer also exercise real pipe/child failures in tests.
    func run(
        executable: URL, arguments: [String],
        consume: @escaping @Sendable (Data) throws -> Bool,
        cleanup: @escaping @Sendable () -> Void = {}
    ) {
        DispatchQueue(label: "app.blau.airplay.receiver", qos: .userInitiated).async { [self] in
            defer {
                cleanup()
                lock.withLock { finished = true }
            }
            do {
                try receive(executable: executable, arguments: arguments, consume: consume)
            } catch {
                if !isCancelled { publish(.failed("Wireless receiver failed. Try again.")) }
            }
            if isCancelled { publish(.stopped) }
        }
    }

    private func receive(
        executable: URL, arguments: [String], consume: @Sendable (Data) throws -> Bool
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-airplay-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments + [directory.appendingPathComponent("pairing.pem").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        guard !isCancelled else { return }
        try process.run()
        try pipe.fileHandleForWriting.close()
        defer { terminate(process) }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            throw AirPlayPacketDecoder.Failure.invalidPacket
        }
        var decoder = AirPlayPacketDecoder()
        let started = ProcessInfo.processInfo.systemUptime
        var watchdog = AirPlayWatchdog(started: started, lastHeartbeat: started)
        var scratch = [UInt8](repeating: 0, count: 65_536)
        while !isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            if let message = watchdog.failure(at: now) { publish(.failed(message)); return }
            let count = Darwin.read(descriptor, &scratch, scratch.count)
            if count > 0 {
                let packets = try decoder.append(Data(scratch.prefix(count)))
                for packet in packets {
                    switch packet.kind {
                    case .discoveryFailure:
                        publish(.failed(AirPlayDiscoveryFailure.message(for: packet.payload)))
                        return
                    case .ready:
                        guard !watchdog.ready else { throw AirPlayPacketDecoder.Failure.invalidPacket }
                        watchdog.ready = true
                        watchdog.lastHeartbeat = now
                        publish(.waiting)
                    case .heartbeat:
                        watchdog.lastHeartbeat = now
                    case .peerActivity:
                        watchdog.lastPeerActivity = now
                    case .pin:
                        watchdog.pairingSince = watchdog.pairingSince ?? now
                        publish(.pairing(String(decoding: packet.payload, as: UTF8.self)))
                    case .video:
                        guard watchdog.ready else { throw AirPlayPacketDecoder.Failure.invalidPacket }
                        watchdog.lastPeerActivity = now
                        if try consume(packet.payload) {
                            watchdog.pairingSince = nil
                            publish(.streaming)
                        }
                    case .stopped:
                        publish(.stopped)
                        return
                    }
                }
                if !packets.isEmpty { watchdog.partialMessageSince = nil }
                watchdog.partialMessageSince = decoder.buffered.isEmpty ? nil : (watchdog.partialMessageSince ?? now)
            } else if count == 0 {
                try decoder.finish()
                publish(.failed("Wireless receiver closed. Connect again."))
                return
            } else if errno != EAGAIN && errno != EINTR {
                throw AirPlayPacketDecoder.Failure.invalidPacket
            } else {
                // Check child exit separately: descendants can inherit its pipe.
                guard process.isRunning else {
                    publish(.failed("Wireless receiver exited. Try again."))
                    return
                }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&pollDescriptor, 1, 50)
            }
        }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Process reaps asynchronously. Never waitUntilExit, including after SIGKILL.
    }
}
