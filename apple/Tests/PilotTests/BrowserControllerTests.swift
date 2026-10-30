import AppKit
import Foundation
import Security
import Testing
import WebKit
@testable import Pilot

@Suite("Browser controller routing")
@MainActor
struct BrowserControllerTests {
    @Test("Transient browser command URLs route to typed controller commands")
    func routesTypedCommands() throws {
        let controller = FakeBrowserController()
        let inputs = [
            "blau://back",
            "blau://forward",
            "blau://reload",
            "blau://stop",
        ]

        for input in inputs {
            BrowserControllerCommandRouter.route(
                try #require(URL(string: input)),
                to: controller
            )
        }

        #expect(controller.commands == [.back, .forward, .reload, .stop])
    }

    @Test("Ordinary and command-lookalike URLs remain navigations")
    func preservesNavigations() throws {
        let controller = FakeBrowserController()
        let ordinaryURL = try #require(URL(string: "https://example.test/path"))
        let lookalikeURL = try #require(URL(string: "blau://reload/extra"))

        BrowserControllerCommandRouter.route(ordinaryURL, to: controller)
        BrowserControllerCommandRouter.route(lookalikeURL, to: controller)

        #expect(controller.commands == [
            .navigate(ordinaryURL),
            .navigate(lookalikeURL),
        ])
    }

    @Test("Commands reach only the selected pane controller")
    func keepsControllersIndependent() throws {
        let selected = FakeBrowserController()
        let background = FakeBrowserController()
        let target = try #require(URL(string: "http://127.0.0.1:8080/"))

        BrowserControllerCommandRouter.route(target, to: selected)
        selected.performBrowserCommand(.setZoom(1.25))
        selected.performBrowserCommand(.focus)
        selected.performBrowserCommand(.setDeveloperToolsVisible(true))
        selected.performBrowserCommand(.close)

        #expect(selected.commands == [
            .navigate(target),
            .setZoom(1.25),
            .focus,
            .setDeveloperToolsVisible(true),
            .close,
        ])
        #expect(background.commands.isEmpty)
    }

    @Test("Chromium zoom conversion preserves Pilot's linear scale")
    func convertsChromiumZoomLevels() {
        #expect(
            abs(
                BrowserZoomConversion.chromiumLevel(forLinearScale: 1)
            ) < 0.000_001
        )
        #expect(
            abs(
                BrowserZoomConversion.chromiumLevel(forLinearScale: 1.2) - 1
            ) < 0.000_001
        )
        #expect(
            abs(
                BrowserZoomConversion.linearScale(forChromiumLevel: -1)
                    - (1 / 1.2)
            ) < 0.000_001
        )
        #expect(
            BrowserZoomConversion.chromiumLevel(forLinearScale: 0) == 0
        )
        #expect(
            BrowserZoomConversion.linearScale(
                forChromiumLevel: .infinity
            ) == 1
        )
    }
}

@MainActor
private final class FakeBrowserController: BrowserControlling {
    private(set) var commands: [BrowserControllerCommand] = []

    func performBrowserCommand(_ command: BrowserControllerCommand) {
        commands.append(command)
    }
}

@Suite("Browser certificate warnings", .serialized)
@MainActor
struct BrowserCertificateTests {
    @Test("Certificate identity is HTTPS-only and hashes the exact certificate")
    func identityRequiresHTTPSAndCertificate() throws {
        let certificate = Data("abc".utf8)
        let url = try #require(URL(string: "https://glkvm01.local/"))
        let identity = try #require(BrowserCertificateIdentity(
            url: url, certificateDER: certificate
        ))
        #expect(identity.origin.serialized == "https://glkvm01.local")
        #expect(identity.fingerprint == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for rawURL in ["http://glkvm01.local", "file:///tmp/device", "https://user:password@glkvm01.local"] {
            let invalidURL = try #require(URL(string: rawURL))
            #expect(BrowserCertificateIdentity(url: invalidURL, certificateDER: certificate) == nil)
        }
        #expect(BrowserCertificateIdentity(url: url, certificateDER: Data()) == nil)
    }

    @Test("Approval is isolated by host, port, and certificate and can be cleared")
    func exceptionScope() throws {
        func identity(_ rawURL: String, certificate: String = "first") throws -> BrowserCertificateIdentity {
            let url = try #require(URL(string: rawURL))
            return try #require(BrowserCertificateIdentity(
                url: url, certificateDER: Data(certificate.utf8)
            ))
        }
        let original = try identity("https://glkvm01.local")
        var exceptions = BrowserCertificateExceptions()
        #expect(!exceptions.allows(original))
        exceptions.allow(original)
        #expect(exceptions.allows(original))
        #expect(exceptions.allows(try identity("https://GLKVM01.LOCAL:443/path")))
        #expect(!exceptions.allows(try identity("https://glkvm02.local")))
        #expect(!exceptions.allows(try identity("https://glkvm01.local:8443")))
        #expect(!exceptions.allows(try identity("https://glkvm01.local", certificate: "replacement")))
        exceptions.removeAll()
        #expect(!exceptions.allows(original))
    }

    @Test("WebKit remembers explicit certificate approval even when the pane moves into the background")
    func webKitApprovedCertificate() async throws {
        let url = try #require(URL(string: "https://localhost:8443/device"))
        var prompts = 0
        let harness = WebKitCertificateHarness(url: url) { identity in
            #expect(identity.origin.serialized == "https://localhost:8443")
            prompts += 1
            return true
        }
        defer { harness.close() }
        let challenge = try makeChallenge(url: url)
        let first = await harness.coordinator.webView(harness.view, respondTo: challenge)
        #expect(first.0 == .useCredential)
        #expect(first.1 != nil)
        let second = await harness.coordinator.webView(harness.view, respondTo: challenge)
        #expect(second.0 == .useCredential)
        harness.view.isPaneSelected = false
        harness.view.isHidden = true
        let background = await harness.coordinator.webView(harness.view, respondTo: challenge)
        #expect(background.0 == .useCredential)
        #expect(prompts == 1)
    }

    @Test("WebKit loads a real self-signed HTTPS page after one approval", .timeLimit(.minutes(1)))
    func webKitLoadsSelfSignedPage() async throws {
        let server = try ChromiumOpenSSLFixtureServer.bundled()
        try server.start()
        defer { server.stop() }
        let url = server.baseURL
        var prompts = 0
        let harness = WebKitCertificateHarness(url: url) { identity in
            #expect(identity.origin == ChromiumOrigin(url: url))
            prompts += 1
            return true
        }
        defer { harness.close() }
        // Exercise WebKit's actual main-frame policy and authentication callbacks.
        harness.coordinator.trackMainFrameNavigation(to: nil)
        harness.view.load(URLRequest(url: url))

        var body = ""
        for _ in 0..<200 {
            body = (try? await harness.view.evaluateJavaScript("document.body?.textContent ?? ''")) as? String ?? ""
            if body.contains("s_server") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(body.contains("s_server"))
        #expect(harness.view.url == url)
        #expect(prompts == 1)
    }

    @Test("WebKit leaves trusted certificates and other authentication to normal handling")
    func webKitDefaultHandling() async throws {
        let url = try #require(URL(string: "https://localhost:8443/device"))
        var prompts = 0
        let harness = WebKitCertificateHarness(url: url) { _ in prompts += 1; return false }
        defer { harness.close() }
        let trusted = try makeChallenge(url: url, trusted: true)
        let accepted = await harness.coordinator.webView(harness.view, respondTo: trusted)
        #expect(accepted.0 == .performDefaultHandling)
        let password = URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: "localhost", port: 8443, protocol: "https", realm: nil,
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            ),
            proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
            error: nil, sender: CertificateChallengeSender()
        )
        let delegated = await harness.coordinator.webView(harness.view, respondTo: password)
        #expect(delegated.0 == .performDefaultHandling)
        #expect(prompts == 0)
    }

    @Test("WebKit rejects unapproved, background, cross-origin, and stale certificate challenges", arguments: [
        "cancel", "background", "hidden", "other-origin", "new-navigation", "closed", "closed-during-prompt",
    ])
    func webKitRejectsUnapprovedChallenges(scenario: String) async throws {
        let url = try #require(URL(string: "https://localhost:8443/device"))
        weak var activeHarness: WebKitCertificateHarness?
        var prompts = 0
        let harness = WebKitCertificateHarness(url: url) { _ in
            prompts += 1
            if scenario == "new-navigation" {
                activeHarness?.state.requestNavigationCommand("https://other.example")
                return true
            }
            if scenario == "closed-during-prompt" {
                activeHarness?.coordinator.invalidate()
                return true
            }
            return false
        }
        activeHarness = harness
        defer { harness.close() }
        switch scenario {
        case "background": harness.view.isPaneSelected = false
        case "hidden": harness.view.isHidden = true
        case "other-origin": harness.coordinator.trackMainFrameNavigation(to: URL(string: "https://other.example"))
        case "closed": harness.coordinator.invalidate()
        default: break
        }
        let disposition = await harness.coordinator.webView(harness.view, respondTo: try makeChallenge(url: url))
        #expect(disposition.0 == .cancelAuthenticationChallenge)
        #expect(disposition.1 == nil)
        #expect(prompts == (["cancel", "new-navigation", "closed-during-prompt"].contains(scenario) ? 1 : 0))
    }

    private func makeChallenge(url: URL, trusted: Bool = false) throws -> URLAuthenticationChallenge {
        let directory = try ChromiumFixtureServer.bundledFixtureDirectory()
        let pem = try String(contentsOf: directory.appendingPathComponent("self-signed-localhost-cert.pem"), encoding: .utf8)
        let encoded = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let data = try #require(Data(base64Encoded: encoded))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "localhost" as CFString), &trust)
                == errSecSuccess)
        let serverTrust = try #require(trust)
        #expect(SecTrustSetNetworkFetchAllowed(serverTrust, false) == errSecSuccess)
        if trusted {
            #expect(SecTrustSetAnchorCertificates(serverTrust, [certificate] as CFArray) == errSecSuccess)
            #expect(SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess)
        }
        return URLAuthenticationChallenge(
            protectionSpace: CertificateProtectionSpace(url: url, trust: serverTrust),
            proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
            error: nil, sender: CertificateChallengeSender()
        )
    }
}

@MainActor
private final class WebKitCertificateHarness {
    let state = BrowserState()
    let view = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    let coordinator: WebViewRepresentable.Coordinator

    init(url: URL, confirm: @escaping @MainActor (BrowserCertificateIdentity) -> Bool) {
        coordinator = WebViewRepresentable.Coordinator(
            state: state, targetTerminalPaneID: { nil }, confirmCertificate: confirm
        )
        view.navigationDelegate = coordinator
        view.isPaneSelected = true
        coordinator.observeURL(of: view)
        coordinator.trackMainFrameNavigation(to: url)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
    }

    func close() {
        coordinator.invalidate()
        view.navigationDelegate = nil
        window.close()
    }
}

private final class CertificateProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(url: URL, trust: SecTrust) {
        self.trust = trust
        super.init(
            host: url.host ?? "", port: url.port ?? 443, protocol: "https", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var serverTrust: SecTrust? { trust }
}

private final class CertificateChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
