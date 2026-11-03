import Darwin
import Foundation

enum ProofSocketError: Error, Equatable {
    case disconnected
    case posix(Int32)
    case invalidPort
}

final class ProofSocket {
    private var descriptor: Int32?

    private init(descriptor: Int32) throws {
        self.descriptor = descriptor
        var noSIGPIPE: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSIGPIPE,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw Self.lastError() }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw Self.lastError() }
    }

    deinit {
        close()
    }

    static func listener() throws -> (socket: ProofSocket, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw lastError() }
        do {
            var reuse: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuse,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else { throw lastError() }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(descriptor, 1) == 0 else { throw lastError() }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { throw lastError() }
            return (try ProofSocket(descriptor: descriptor), UInt16(bigEndian: address.sin_port))
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func connect(port: UInt16) throws -> ProofSocket {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw lastError() }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw lastError() }
            return try ProofSocket(descriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func accept() throws -> ProofSocket {
        let descriptor = try requireDescriptor()
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let accepted = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(descriptor, $0, &length)
            }
        }
        guard accepted >= 0 else { throw Self.lastError() }
        return try ProofSocket(descriptor: accepted)
    }

    func write(_ data: Data) throws {
        let descriptor = try requireDescriptor()
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(descriptor, base + offset, data.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw Self.lastError() }
                offset += written
            }
        }
    }

    func readFrame() throws -> Data {
        let prefix = try readExactly(DroneWire.headerSize)
        return try readExactly(DroneWire.payloadLength(prefix))
    }

    func writeFrame(_ record: Data) throws {
        try write(DroneWire.frame(record))
    }

    func close() {
        guard let descriptor = descriptor else { return }
        self.descriptor = nil
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
    }

    private func readExactly(_ count: Int) throws -> Data {
        let descriptor = try requireDescriptor()
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < count {
                let received = Darwin.recv(descriptor, base + offset, count - offset, 0)
                if received < 0, errno == EINTR { continue }
                if received == 0 { throw ProofSocketError.disconnected }
                guard received > 0 else { throw Self.lastError() }
                offset += received
            }
        }
        return data
    }

    private func requireDescriptor() throws -> Int32 {
        guard let descriptor else { throw ProofSocketError.disconnected }
        return descriptor
    }

    private static func lastError() -> ProofSocketError {
        .posix(errno)
    }
}
