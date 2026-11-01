import Darwin
import Foundation
import Network
import Security

final class ChromiumFixtureServer: @unchecked Sendable {
    enum ServerError: Error {
        case alreadyRunning
        case invalidFixtureDirectory
        case invalidTLSIdentity
        case listenerFailed(Error)
        case pkcs12ImportFailed(OSStatus)
        case startupTimedOut
    }

    private let fixtureDirectory: URL
    private let maxRequestBytes: Int
    private let maxResponseBytes: Int
    private let tlsIdentity: sec_identity_t?
    private let queue = DispatchQueue(label: "app.blau.tests.chromium-fixture")
    private var listener: NWListener?
    private var listeningPort: NWEndpoint.Port?
    private var startupError: Error?
    private var connections: [UUID: NWConnection] = [:]

    init(
        fixtureDirectory: URL,
        maxRequestBytes: Int = 16 * 1024,
        maxResponseBytes: Int = 2 * 1024 * 1024,
        tlsIdentity: sec_identity_t? = nil
    ) throws {
        let values = try fixtureDirectory.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        guard values.isDirectory == true,
              maxRequestBytes > 0,
              maxResponseBytes > 0
        else {
            throw ServerError.invalidFixtureDirectory
        }
        self.fixtureDirectory = fixtureDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.maxRequestBytes = maxRequestBytes
        self.maxResponseBytes = maxResponseBytes
        self.tlsIdentity = tlsIdentity
    }

    static func bundledFixtureDirectory() throws -> URL {
        guard let directory = Bundle(for: ChromiumFixtureServer.self)
            .resourceURL?
            .appendingPathComponent("ChromiumBrowser"),
              FileManager.default.fileExists(atPath: directory.path)
        else {
            throw ServerError.invalidFixtureDirectory
        }
        return directory
    }

    static func bundledSelfSignedTLSIdentity() throws -> sec_identity_t {
        let identityURL = try bundledFixtureDirectory()
            .appendingPathComponent(
                "self-signed-localhost.p12.base64",
                isDirectory: false
            )
        guard let encoded = try? String(
            contentsOf: identityURL,
            encoding: .utf8
        ),
              let pkcs12 = Data(
                base64Encoded: encoded,
                options: .ignoreUnknownCharacters
              )
        else {
            throw ServerError.invalidTLSIdentity
        }

        // Keep the fixture identity in process memory. On macOS a plain
        // SecPKCS12Import writes the key into the login keychain with an ACL
        // pinned to the importing build's cdhash; every later (unsigned,
        // rebuilt) test host then needs keychain consent to sign the TLS
        // handshake, which stalls Network.framework for the rest of the run.
        let options = [
            kSecImportExportPassphrase as String: "pilot-chromium-tls",
            kSecImportToMemoryOnly as String: true,
        ] as CFDictionary
        var imported: CFArray?
        let status = SecPKCS12Import(
            pkcs12 as CFData,
            options,
            &imported
        )
        guard status == errSecSuccess else {
            throw ServerError.pkcs12ImportFailed(status)
        }
        guard let items = imported as? [[String: Any]],
              let identityValue = items.first?[
                kSecImportItemIdentity as String
              ]
        else {
            throw ServerError.invalidTLSIdentity
        }
        let identityReference = identityValue as CFTypeRef
        guard CFGetTypeID(identityReference) == SecIdentityGetTypeID()
        else {
            throw ServerError.invalidTLSIdentity
        }
        let securityIdentity = unsafeDowncast(
            identityReference,
            to: SecIdentity.self
        )
        guard let identity = sec_identity_create(securityIdentity) else {
            throw ServerError.invalidTLSIdentity
        }
        return identity
    }

    var isRunning: Bool {
        queue.sync { listener != nil && listeningPort != nil }
    }

    var baseURL: URL {
        queue.sync {
            precondition(listeningPort != nil, "Start the fixture server first")
            let scheme = tlsIdentity == nil ? "http" : "https"
            return URL(
                string: "\(scheme)://127.0.0.1:\(listeningPort!.rawValue)/"
            )!
        }
    }

    func start(timeout: TimeInterval = 2) throws {
        let ready = DispatchSemaphore(value: 0)
        let parameters: NWParameters
        if let tlsIdentity {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                tlsIdentity
            )
            sec_protocol_options_add_tls_application_protocol(
                tlsOptions.securityProtocolOptions,
                "http/1.1"
            )
            parameters = NWParameters(
                tls: tlsOptions,
                tcp: NWProtocolTCP.Options()
            )
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let newListener = try NWListener(using: parameters, on: .any)

        try queue.sync {
            guard listener == nil else {
                throw ServerError.alreadyRunning
            }
            startupError = nil
            listener = newListener
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listeningPort = newListener.port
                    ready.signal()
                case .failed(let error):
                    self.startupError = error
                    ready.signal()
                default:
                    break
                }
            }
            newListener.start(queue: queue)
        }

        guard ready.wait(timeout: .now() + timeout) == .success else {
            stop()
            throw ServerError.startupTimedOut
        }
        let result = queue.sync { (listeningPort, startupError) }
        if let error = result.1 {
            stop()
            throw ServerError.listenerFailed(error)
        }
        guard result.0 != nil else {
            stop()
            throw ServerError.startupTimedOut
        }
    }

    func stop(timeout: TimeInterval = 2) {
        let cancelled = DispatchSemaphore(value: 0)
        let didCancel = queue.sync { () -> Bool in
            guard let listener else {
                return false
            }
            listener.stateUpdateHandler = { state in
                if case .cancelled = state {
                    cancelled.signal()
                }
            }
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
            listener.cancel()
            self.listener = nil
            listeningPort = nil
            startupError = nil
            return true
        }
        if didCancel {
            _ = cancelled.wait(timeout: .now() + timeout)
        }
    }

    deinit {
        stop()
    }

    private func accept(_ connection: NWConnection) {
        let identifier = UUID()
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(
        on connection: NWConnection,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: min(4096, maxRequestBytes + 1)
        ) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = accumulated
            if let content {
                request.append(content)
            }
            if request.count > self.maxRequestBytes {
                self.send(
                    status: 431,
                    body: Data("request headers too large\n".utf8),
                    to: connection
                )
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.route(request, on: connection)
                return
            }
            if isComplete || error != nil {
                self.send(
                    status: 400,
                    body: Data("incomplete request\n".utf8),
                    to: connection
                )
                return
            }
            self.receiveRequest(on: connection, accumulated: request)
        }
    }

    private func route(_ request: Data, on connection: NWConnection) {
        guard let header = String(data: request, encoding: .utf8),
              let requestLine = header.components(
                  separatedBy: "\r\n"
              ).first
        else {
            send(status: 400, body: Data("invalid request\n".utf8), to: connection)
            return
        }
        let fields = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3 else {
            send(status: 400, body: Data("invalid request line\n".utf8), to: connection)
            return
        }
        let method = String(fields[0])
        guard method == "GET" || method == "HEAD" else {
            send(status: 405, body: Data("method not allowed\n".utf8), to: connection)
            return
        }
        let target = String(fields[1])
        guard target.hasPrefix("/"),
              let components = URLComponents(
                  string: "http://127.0.0.1\(target)"
              ),
              let decodedPath = components.percentEncodedPath
                  .removingPercentEncoding,
              !decodedPath.contains("\0"),
              !decodedPath.contains("\\")
        else {
            send(status: 400, body: Data("invalid target\n".utf8), to: connection)
            return
        }
        let pathComponents = decodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !pathComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            send(status: 403, body: Data("path traversal rejected\n".utf8), to: connection)
            return
        }
        if decodedPath == "/authentication-required" {
            send(
                status: 401,
                body: Data("authentication required\n".utf8),
                extraHeaders: [
                    "WWW-Authenticate": "Basic realm=\"Pilot Chromium fixture\"",
                ],
                includeBody: method != "HEAD",
                to: connection
            )
            return
        }

        let relativePath = decodedPath == "/"
            ? "index.html"
            : String(decodedPath.dropFirst())
        let candidate = fixtureDirectory
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let fixturePrefix = fixtureDirectory.path + "/"
        guard candidate.path.hasPrefix(fixturePrefix) else {
            send(status: 403, body: Data("path outside fixture root\n".utf8), to: connection)
            return
        }
        guard let values = try? candidate.resourceValues(
            forKeys: [.isRegularFileKey]
        ),
              values.isRegularFile == true,
              let body = try? Data(contentsOf: candidate)
        else {
            send(status: 404, body: Data("fixture not found\n".utf8), to: connection)
            return
        }
        guard body.count <= maxResponseBytes else {
            send(status: 413, body: Data("fixture response too large\n".utf8), to: connection)
            return
        }

        var extraHeaders: [String: String] = [:]
        if candidate.lastPathComponent == "download.txt" {
            extraHeaders["Content-Disposition"] =
                "attachment; filename=\"pilot-fixture-download.txt\""
        }
        send(
            status: 200,
            body: body,
            contentType: contentType(for: candidate.pathExtension),
            extraHeaders: extraHeaders,
            includeBody: method != "HEAD",
            to: connection
        )
    }

    private func send(
        status: Int,
        body: Data,
        contentType: String = "text/plain; charset=utf-8",
        extraHeaders: [String: String] = [:],
        includeBody: Bool = true,
        to connection: NWConnection
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Error"
        }
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Length: \(body.count)",
            "Content-Type: \(contentType)",
            "Cache-Control: no-store",
            "Connection: close",
        ]
        for key in extraHeaders.keys.sorted() {
            headers.append("\(key): \(extraHeaders[key]!)")
        }
        headers.append("")
        headers.append("")
        var response = Data(headers.joined(separator: "\r\n").utf8)
        if includeBody {
            response.append(body)
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func contentType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        default: "text/plain; charset=utf-8"
        }
    }
}

final class ChromiumOpenSSLFixtureServer: @unchecked Sendable {
    enum ServerError: Error {
        case invalidFixture
        case processExited(Int32)
        case startupTimedOut
    }

    private let certificateURL: URL
    private let privateKeyURL: URL
    private let lock = NSLock()
    private var process: Process?
    private var listeningPort: NWEndpoint.Port?
    private var standardOutput: Pipe?
    private var standardError: Pipe?

    init(certificateURL: URL, privateKeyURL: URL) throws {
        guard FileManager.default.fileExists(atPath: certificateURL.path),
              FileManager.default.fileExists(atPath: privateKeyURL.path),
              FileManager.default.isExecutableFile(
                atPath: "/usr/bin/openssl"
              )
        else {
            throw ServerError.invalidFixture
        }
        self.certificateURL = certificateURL
        self.privateKeyURL = privateKeyURL
    }

    static func bundled() throws -> ChromiumOpenSSLFixtureServer {
        let directory = try ChromiumFixtureServer.bundledFixtureDirectory()
        return try ChromiumOpenSSLFixtureServer(
            certificateURL: directory.appendingPathComponent(
                "self-signed-localhost-cert.pem"
            ),
            privateKeyURL: directory.appendingPathComponent(
                "self-signed-localhost-key.pem"
            )
        )
    }

    var baseURL: URL {
        lock.withLock {
            precondition(listeningPort != nil, "Start the TLS server first")
            return URL(
                string: "https://127.0.0.1:\(listeningPort!.rawValue)/"
            )!
        }
    }

    func start(timeout: TimeInterval = 2) throws {
        let port = try Self.availablePort(timeout: timeout)
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "s_server",
            "-accept", String(port.rawValue),
            "-cert", certificateURL.path,
            "-key", privateKeyURL.path,
            "-alpn", "http/1.1",
            "-www",
            "-quiet",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error

        try lock.withLock {
            guard self.process == nil else {
                throw ChromiumFixtureServer.ServerError.alreadyRunning
            }
            try process.run()
            self.process = process
            listeningPort = port
            standardOutput = output
            standardError = error
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            if Self.canConnect(to: port) {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        stop()
        if process.isRunning {
            throw ServerError.startupTimedOut
        }
        throw ServerError.processExited(process.terminationStatus)
    }

    func stop() {
        let runningProcess = lock.withLock { () -> Process? in
            defer {
                process = nil
                listeningPort = nil
                standardOutput = nil
                standardError = nil
            }
            return process
        }
        guard let runningProcess, runningProcess.isRunning else { return }
        runningProcess.terminate()
        runningProcess.waitUntilExit()
    }

    deinit {
        stop()
    }

    private static func availablePort(
        timeout: TimeInterval
    ) throws -> NWEndpoint.Port {
        _ = timeout
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw posixError()
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            throw posixError()
        }

        var resolvedLength = addressLength
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getsockname(descriptor, $0, &resolvedLength)
            }
        }
        guard nameResult == 0,
              let port = NWEndpoint.Port(
                rawValue: UInt16(bigEndian: address.sin_port)
              )
        else {
            throw posixError()
        }
        return port
    }

    private static func canConnect(to port: NWEndpoint.Port) -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(
            label: "app.blau.tests.chromium-openssl-readiness"
        )
        let connection = NWConnection(
            host: "127.0.0.1",
            port: port,
            using: .tcp
        )
        let connected = ChromiumFixtureLockedValue(false)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connected.withValue { $0 = true }
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = ready.wait(timeout: .now() + 0.1)
        connection.cancel()
        return connected.withValue { $0 }
    }

    private static func posixError() -> Error {
        let code = POSIXErrorCode(rawValue: errno) ?? .EINVAL
        return ChromiumFixtureServer.ServerError.listenerFailed(
            NWError.posix(code)
        )
    }
}

private final class ChromiumFixtureLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(
        _ operation: (inout Value) throws -> Result
    ) rethrows -> Result {
        try lock.withLock {
            try operation(&value)
        }
    }
}
