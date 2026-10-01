import Foundation

/// Errors surfaced by the Docker socket transport. Everything the daemon sends
/// back is untrusted input, so malformed framing and oversized payloads are
/// distinct, reportable failures rather than crashes.
enum DockerTransportError: Error, Equatable, LocalizedError {
    case daemonUnreachable(String)
    case malformedResponse(String)
    case responseTooLarge(Int)
    case timedOut
    case httpStatus(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .daemonUnreachable(let detail):
            "Can't reach the Docker daemon: \(detail)"
        case .malformedResponse(let detail):
            "The Docker daemon sent an unreadable response: \(detail)"
        case .responseTooLarge(let bytes):
            "The Docker daemon sent more than \(bytes) bytes"
        case .timedOut:
            "The Docker daemon did not respond in time"
        case .httpStatus(let code, let message):
            message.isEmpty ? "Docker returned HTTP \(code)" : message
        }
    }
}

/// One Engine API request. Held as method/path/body rather than a `URLRequest`
/// because the transport writes raw HTTP/1.1 bytes onto a Unix domain socket —
/// `URLSession` has no AF_UNIX transport.
struct DockerRequest: Sendable {
    var method: String
    /// Percent-encoded path with query, e.g. `/v1.43/containers/json?all=1`.
    var path: String
    var body: Data?

    init(method: String = "GET", path: String, body: Data? = nil) {
        self.method = method
        self.path = path
        self.body = body
    }

    /// Serialize to the wire. HTTP/1.1 requires a `Host`, which is meaningless
    /// over AF_UNIX; Docker clients conventionally send a placeholder. We always
    /// ask for `Connection: close` because every request opens its own socket —
    /// there is no connection pool to keep warm, and close-delimited responses
    /// give the parser an unambiguous end for streaming endpoints.
    func serialized() -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: docker\r\n"
        head += "Accept: application/json\r\n"
        head += "User-Agent: Cockpit\r\n"
        head += "Connection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }
}

/// A fully collected response from a one-shot request.
struct DockerResponse: Sendable {
    let status: Int
    let body: Data

    var isSuccess: Bool { (200..<300).contains(status) }

    /// Docker reports failures as `{"message": "..."}`; fall back to the raw
    /// body (bounded) when it isn't JSON so the UI still shows something useful.
    var failureMessage: String {
        struct Envelope: Decodable { let message: String }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body) {
            return UntrustedText.sanitized(envelope.message, limit: 400)
        }
        return UntrustedText.sanitized(String(decoding: body.prefix(400), as: UTF8.self), limit: 400)
    }
}

/// What the transport hands back as it reads: the status line first, then body
/// bytes as they arrive. Streaming callers (`/events`) need the status before
/// the body ever ends, so the two are separate events rather than one struct.
enum DockerStreamEvent: Sendable {
    case head(status: Int, headers: [String: String])
    case body(Data)
}

/// Incremental HTTP/1.1 response reader.
///
/// Deliberately not a general-purpose HTTP client: it handles exactly the three
/// framings the Engine API uses (chunked, `Content-Length`, and read-until-close)
/// and enforces a byte ceiling before allocating, because the daemon is a local
/// socket that any process on the machine could be standing in for.
///
/// Feed it raw socket bytes with ``consume(_:)``; it returns the decoded body
/// bytes produced by that read (possibly empty) and flips ``isBodyComplete``
/// when the message ends.
struct DockerHTTPResponseParser {
    enum BodyFraming: Equatable {
        case chunked
        case contentLength(Int)
        /// No length and no chunking — the body ends when the socket closes.
        case untilClose
    }

    private(set) var statusCode: Int?
    private(set) var headers: [String: String] = [:]
    private(set) var framing: BodyFraming?
    private(set) var isBodyComplete = false

    let maxHeaderBytes: Int
    let maxBodyBytes: Int

    private var pending: [UInt8] = []
    private var bodyBytesDelivered = 0
    private var remainingFixedBytes = 0
    private var remainingChunkBytes = 0
    private var isInsideChunkBody = false

    /// A chunk-size line is a hex count plus optional extensions. Anything long
    /// past that is a framing bug or a hostile daemon, not a real chunk header.
    private static let maxChunkHeaderBytes = 1024

    init(maxHeaderBytes: Int = 64 * 1024, maxBodyBytes: Int = 8 * 1024 * 1024) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    /// Feed bytes read from the socket; returns any body bytes they completed.
    mutating func consume(_ data: Data) throws -> Data {
        guard !isBodyComplete else { return Data() }
        pending.append(contentsOf: data)

        if statusCode == nil {
            guard let headEnd = Self.firstIndex(of: Self.headTerminator, in: pending) else {
                if pending.count > maxHeaderBytes {
                    throw DockerTransportError.responseTooLarge(maxHeaderBytes)
                }
                return Data()
            }
            let head = Array(pending[..<headEnd])
            pending.removeFirst(headEnd + Self.headTerminator.count)
            try parseHead(head)
        }

        switch framing {
        case .chunked:
            return try consumeChunked()
        case .contentLength:
            return consumeFixedLength()
        case .untilClose:
            return consumeUntilClose()
        case nil:
            return Data()
        }
    }

    /// The socket closed. Legal only for `untilClose` bodies (or one already
    /// finished); anything else means the response was cut short.
    mutating func finishOnEOF() throws {
        guard !isBodyComplete else { return }
        guard statusCode != nil else {
            throw DockerTransportError.malformedResponse("connection closed before the status line")
        }
        guard framing == .untilClose else {
            throw DockerTransportError.malformedResponse("connection closed mid-body")
        }
        isBodyComplete = true
    }

    // MARK: - Framing

    private mutating func consumeFixedLength() -> Data {
        let take = min(remainingFixedBytes, pending.count)
        guard take > 0 else {
            if remainingFixedBytes == 0 { isBodyComplete = true }
            return Data()
        }
        let out = Data(pending[..<take])
        pending.removeFirst(take)
        remainingFixedBytes -= take
        bodyBytesDelivered += take
        if remainingFixedBytes == 0 { isBodyComplete = true }
        return out
    }

    private mutating func consumeUntilClose() -> Data {
        guard !pending.isEmpty else { return Data() }
        let out = Data(pending)
        bodyBytesDelivered += pending.count
        pending.removeAll(keepingCapacity: true)
        return out
    }

    private mutating func consumeChunked() throws -> Data {
        var out = Data()
        while true {
            if isInsideChunkBody {
                if remainingChunkBytes == 0 {
                    // Every chunk body is followed by its own CRLF.
                    guard pending.count >= 2 else { return out }
                    guard pending[0] == Self.cr, pending[1] == Self.lf else {
                        throw DockerTransportError.malformedResponse("missing chunk terminator")
                    }
                    pending.removeFirst(2)
                    isInsideChunkBody = false
                    continue
                }
                let take = min(remainingChunkBytes, pending.count)
                guard take > 0 else { return out }
                out.append(contentsOf: pending[..<take])
                pending.removeFirst(take)
                remainingChunkBytes -= take
                bodyBytesDelivered += take
                try enforceBodyCeiling()
                continue
            }

            guard let lineEnd = Self.firstIndex(of: Self.crlf, in: pending) else {
                if pending.count > Self.maxChunkHeaderBytes {
                    throw DockerTransportError.malformedResponse("chunk header too long")
                }
                return out
            }
            let line = String(decoding: pending[..<lineEnd], as: UTF8.self)
            pending.removeFirst(lineEnd + Self.crlf.count)

            // `size[;extension]` — extensions are legal and always ignorable.
            let sizeToken = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw DockerTransportError.malformedResponse("unparseable chunk size “\(sizeToken)”")
            }
            if size == 0 {
                // Terminal chunk. Any trailers that follow are dropped with the
                // rest of the buffer — the Engine API never sends meaningful ones.
                isBodyComplete = true
                pending.removeAll(keepingCapacity: false)
                return out
            }
            guard size <= maxBodyBytes else {
                throw DockerTransportError.responseTooLarge(maxBodyBytes)
            }
            remainingChunkBytes = size
            isInsideChunkBody = true
        }
    }

    private func enforceBodyCeiling() throws {
        guard bodyBytesDelivered <= maxBodyBytes else {
            throw DockerTransportError.responseTooLarge(maxBodyBytes)
        }
    }

    // MARK: - Head

    private mutating func parseHead(_ head: [UInt8]) throws {
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw DockerTransportError.malformedResponse("empty response head")
        }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw DockerTransportError.malformedResponse("bad status line “\(statusLine)”")
        }
        statusCode = code

        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            framing = .chunked
        } else if let raw = headers["content-length"] {
            guard let length = Int(raw), length >= 0 else {
                throw DockerTransportError.malformedResponse("bad Content-Length “\(raw)”")
            }
            guard length <= maxBodyBytes else {
                throw DockerTransportError.responseTooLarge(maxBodyBytes)
            }
            framing = .contentLength(length)
            remainingFixedBytes = length
            if length == 0 { isBodyComplete = true }
        } else if code == 204 || code == 304 {
            // Docker answers the lifecycle endpoints with a bodiless 204.
            framing = .contentLength(0)
            isBodyComplete = true
        } else {
            framing = .untilClose
        }
    }

    // MARK: - Byte helpers

    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let crlf: [UInt8] = [0x0D, 0x0A]
    private static let headTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        let limit = bytes.count - pattern.count
        var index = 0
        while index <= limit {
            if bytes[index] == pattern[0] {
                var offset = 1
                while offset < pattern.count, bytes[index + offset] == pattern[offset] {
                    offset += 1
                }
                if offset == pattern.count { return index }
            }
            index += 1
        }
        return nil
    }
}

/// Container names, image tags, status strings, and error messages all originate
/// outside Pilot (image authors, compose files, the daemon itself). Strip control
/// characters and bound the length before any of it reaches a `Text`.
enum UntrustedText {
    static func sanitized(_ raw: String, limit: Int) -> String {
        let cleaned = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count <= limit ? cleaned : String(cleaned.prefix(limit)) + "…"
    }
}
