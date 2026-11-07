import Foundation
import Testing
@testable import Pilot

/// Secret masking patterns, separators, PEM blocks, redact-before-truncate,
/// nested JSON strings, and false positives.
@Suite("Agent output redaction")
struct AgentRedactionTests {
    private let mask = "••••"

    private func masked(_ text: String) -> String { redactOutput(text, maximumLines: nil).text }

    @Test
    func ordinaryTextPassesThroughUnchanged() {
        #expect(redactOutput("git status\nOn branch main") == AgentRedaction(
            text: "git status\nOn branch main", redacted: false, truncatedLines: 0
        ))
        #expect(redactInline("Read README.md") == "Read README.md")
    }

    // MARK: Headers

    @Test(arguments: [
        ("Authorization: Bearer abcdefghijklmnop1234", "Authorization: Bearer ••••"),
        ("authorization: basic dXNlcjpwYXNz", "authorization: basic ••••"),
        ("-H \"Authorization: Token abc123\"", "-H \"Authorization: Token ••••\""),
        (#"{"Authorization": "Bearer abcdefghijklmnop1234"}"#, #"{"Authorization": "Bearer ••••"}"#),
        ("Proxy-Authorization: Basic Zm9vOmJhcg==", "Proxy-Authorization: Basic ••••"),
        ("AUTHORIZATION=shortsecret", "AUTHORIZATION=••••"),
    ])
    func authorizationHeadersMaskTheCredential(input: String, expected: String) {
        #expect(masked(input) == expected)
    }

    @Test
    func bearerTokensNeedSixteenCharacters() {
        #expect(masked("curl -H 'x: Bearer abcdefghijklmnopqrstuvwxyz'") == "curl -H 'x: Bearer ••••'")
        #expect(masked("BEARER ABCDEFGHIJKLMNOP") == "BEARER ••••")
        #expect(masked("the bearer short123 is fine") == "the bearer short123 is fine")
        #expect(masked("a basic idea") == "a basic idea")
    }

    // MARK: Keyed values

    @Test(arguments: [
        ("password=hunter2", "password=••••"),
        ("PASSWORD = hunter2", "PASSWORD = ••••"),
        ("passwd: hunter2", "passwd: ••••"),
        ("secret: abc", "secret: ••••"),
        ("token=abc", "token=••••"),
        ("api_key=abc", "api_key=••••"),
        ("apikey: abc", "apikey: ••••"),
        ("ApiKey: abc", "ApiKey: ••••"),
        ("access_token=abc", "access_token=••••"),
        ("refresh_token=abc", "refresh_token=••••"),
        ("private_key: abc", "private_key: ••••"),
        ("client_secret=abc", "client_secret=••••"),
        ("cookie: session=abc", "cookie: ••••"),
        ("export OPENAI_API_KEY=abc123", "export OPENAI_API_KEY=••••"),
        ("AWS_SECRET_ACCESS_KEY=abc", "AWS_SECRET_ACCESS_KEY=••••"),
        ("STRIPE_SECRET=abc", "STRIPE_SECRET=••••"),
        ("GITHUB_TOKEN=abc", "GITHUB_TOKEN=••••"),
        ("DB_PASSWORD=abc", "DB_PASSWORD=••••"),
        ("x-api-key: abc", "x-api-key: ••••"),
        ("spring.datasource.password=abc", "spring.datasource.password=••••"),
        ("https://h.io/cb?access_token=abc&state=1", "https://h.io/cb?access_token=••••&state=1"),
    ])
    func keyedValuesKeepTheirKey(input: String, expected: String) {
        #expect(masked(input) == expected)
    }

    @Test(arguments: [
        (#"{"token": "abc"}"#, #"{"token": "••••"}"#),
        (#"{"api_key":"abc","n":1}"#, #"{"api_key":"••••","n":1}"#),
        ("token: 'abc def'", "token: '••••'"),
        (#"password: "two words""#, #"password: "••••""#),
        (#"{\"secret\": \"abc\"}"#, #"{\"secret\": \"••••\"}"#),
    ])
    func keyedValuesHandleQuotes(input: String, expected: String) {
        #expect(masked(input) == expected)
    }

    @Test(arguments: [
        ("gh auth login --token abc123", "gh auth login --token ••••"),
        ("tool --api-key abc123 --verbose", "tool --api-key •••• --verbose"),
        ("tool --password 'two words'", "tool --password '••••'"),
        ("tool --token=abc123", "tool --token=••••"),
    ])
    func cliFlagsMaskTheirArgument(input: String, expected: String) {
        #expect(masked(input) == expected)
    }

    @Test(arguments: [
        ("Cookie: _ga=GA1.2.3; sessionid=abc123", "Cookie: ••••"),
        ("set-cookie: sid=abc; Path=/; HttpOnly", "set-cookie: ••••"),
        ("curl -H 'Cookie: a=b; csrftoken=xyz' https://x.io", "curl -H 'Cookie: ••••' https://x.io"),
        (#"{"Cookie": "a=b; sid=c", "n": 1}"#, #"{"Cookie": "••••", "n": 1}"#),
        ("Cookie: a=b\nnext line", "Cookie: ••••\nnext line"),
    ])
    func cookieHeadersMaskEveryPair(input: String, expected: String) {
        #expect(masked(input) == expected)
    }

    @Test(arguments: [
        ("postgres://admin:s3cr3t@db.internal:5432/app", "postgres://admin:••••@db.internal:5432/app"),
        ("redis://:hunter2@cache:6379/0", "redis://:••••@cache:6379/0"),
        ("DATABASE_URL=mysql://u:p4ss@h/db", "DATABASE_URL=mysql://u:••••@h/db"),
        ("git clone https://bot:ghtoken123@github.com/o/r.git", "git clone https://bot:••••@github.com/o/r.git"),
    ])
    func urlCredentialsMaskThePassword(input: String, expected: String) {
        #expect(masked(input) == expected)
        #expect(redactProse(input).contains("••••"), "prose masks URL credentials too")
    }

    @Test
    func urlsWithoutCredentialsAreUntouched() {
        for text in [
            "https://example.com:8080/path?x=1", "git@github.com:org/repo.git", "ssh://git@github.com/org/repo",
            "http://localhost:3000/@user/profile",
        ] {
            #expect(masked(text) == text, "\(text)")
        }
    }

    @Test
    func keyedValuesSkipLiteralsAndReferences() {
        for text in [
            #"{"token": null}"#, "token: true", "max_token: 4096", "password=$DB_PASSWORD",
            #"{"secret": {"nested": 1}}"#,
        ] {
            #expect(masked(text) == text, "\(text)")
        }
    }

    // MARK: Prefixed tokens

    @Test
    func prefixedTokensKeepAFourCharacterHint() {
        let cases: [(String, String)] = [
            ("sk-ant-api03-" + String(repeating: "a1", count: 20), "sk-a"),
            ("sk-proj-" + String(repeating: "Ab3", count: 10), "sk-p"),
            ("sk-" + String(repeating: "x", count: 19) + "9", "sk-x"),
            ("ghp_" + String(repeating: "A", count: 36), "ghp_"),
            ("gho_" + String(repeating: "b", count: 36), "gho_"),
            ("ghs_" + String(repeating: "c", count: 36), "ghs_"),
            ("ghu_" + String(repeating: "d", count: 36), "ghu_"),
            ("github_pat_" + String(repeating: "e", count: 40), "gith"),
            ("xoxb-1234567890-abcdef", "xoxb"),
            ("xoxp-1234567890-abcdef", "xoxp"),
            ("AKIAIOSFODNN7EXAMPLE", "AKIA"),
            ("ASIAIOSFODNN7EXAMPLE", "ASIA"),
            ("AIza" + String(repeating: "Z", count: 35), "AIza"),
            ("glpat-" + String(repeating: "f", count: 20), "glpa"),
            ("npm_" + String(repeating: "G", count: 36), "npm_"),
            ("sk_live_" + String(repeating: "H", count: 24), "sk_l"),
            ("rk_test_" + String(repeating: "j", count: 24), "rk_t"),
            ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "eyJh"),
        ]
        for (token, hint) in cases {
            let result = redactOutput("value \(token) end")
            #expect(result.text == "value \(hint)\(mask) end", "\(token)")
            #expect(result.redacted)
        }
    }

    @Test
    func prefixedTokensRequireTheirMinimumLength() {
        for text in [
            "sk-learn", "sk-learn is a library", "ghp_short", "xoxb-123", "AKIA1234", "glpat-short",
            "npm_tooShort", "eyJabc.def.ghi", "use scikit sk-learn-and-numpy-pandas-tools", "sk_live_short",
        ] {
            #expect(masked(text) == text, "\(text)")
        }
    }

    // MARK: PEM

    @Test
    func pemBlocksKeepArmorAndMaskTheBody() {
        let pem = "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nIBAAKC\n-----END RSA PRIVATE KEY-----\nafter"
        let result = redactOutput(pem)
        #expect(result.text == "before\n-----BEGIN RSA PRIVATE KEY-----\n••••\n-----END RSA PRIVATE KEY-----\nafter")
        #expect(result.redacted)
        let openSSH = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl\n-----END OPENSSH PRIVATE KEY-----"
        #expect(masked(openSSH) == "-----BEGIN OPENSSH PRIVATE KEY-----\n••••\n-----END OPENSSH PRIVATE KEY-----")
    }

    @Test
    func unterminatedPemMasksToTheEnd() {
        let text = "key:\n-----BEGIN PRIVATE KEY-----\nMIIE\nmore\nlines token=abc"
        #expect(masked(text) == "key:\n-----BEGIN PRIVATE KEY-----\n••••\n")
    }

    @Test
    func publicCertificatesAreNotMasked() {
        let cert = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
        #expect(masked(cert) == cert)
    }

    // MARK: Truncation

    @Test
    func truncatesAfterRedacting() {
        let lines = (1...250).map { "line \($0)" }
        let result = redactOutput(lines.joined(separator: "\n"))
        #expect(result.truncatedLines == 50)
        #expect(result.text == lines.prefix(200).joined(separator: "\n"))
        #expect(!result.redacted)
    }

    @Test
    func aSecretStraddlingTheCutIsMaskedBeforeTruncation() {
        let text = "a\n-----BEGIN PRIVATE KEY-----\nsecretbody\n-----END PRIVATE KEY-----"
        let result = redactOutput(text, maximumLines: 2)
        #expect(result.text == "a\n-----BEGIN PRIVATE KEY-----")
        #expect(result.redacted)
        #expect(result.truncatedLines == 2)
        #expect(!result.text.contains("secretbody"))
    }

    @Test
    func truncationCountsLinesExactly() {
        #expect(redactOutput("a\nb\n", maximumLines: 2).truncatedLines == 0)
        #expect(redactOutput("a\nb\nc", maximumLines: 2) == AgentRedaction(text: "a\nb", redacted: false, truncatedLines: 1))
        #expect(redactOutput("a\r\nb\r\nc", maximumLines: 1).text == "a")
        #expect(redactOutput("", maximumLines: 0).truncatedLines == 0)
        #expect(redactOutput("x\ny", maximumLines: 0) == AgentRedaction(text: "", redacted: false, truncatedLines: 2))
        #expect(redactOutput("x\ny", maximumLines: nil).truncatedLines == 0)
    }

    // MARK: JSON

    @Test
    func jsonMasksSecretKeysAndEveryStringValue() {
        let input: JSONValue = [
            "command": "curl -H 'Authorization: Bearer abcdefghijklmnopqrstu' https://x.io",
            "env": ["OPENAI_API_KEY": "abc", "PATH": "/usr/bin"],
            "nested": [["deep": ["note": .string("use ghp_" + String(repeating: "Q", count: 36))]]],
            "count": 3,
            "password": 1234,
        ]
        let (value, redacted) = redactJSON(input)
        #expect(redacted)
        #expect(value["command"] == "curl -H 'Authorization: Bearer ••••' https://x.io")
        #expect(value["env"]?["OPENAI_API_KEY"] == "••••")
        #expect(value["env"]?["PATH"] == "/usr/bin")
        #expect(value["nested"]?.arrayValue?.first?["deep"]?["note"] == "use ghp_••••")
        #expect(value["count"] == 3)
        #expect(value["password"] == 1234)
    }

    @Test
    func jsonMasksSecretShapedKeys() {
        let token = "ghp_" + String(repeating: "K", count: 36)
        let (value, redacted) = redactJSON(.object([token: "owner", "plain": "x"]))
        #expect(redacted)
        #expect(value == ["ghp_••••": "owner", "plain": "x"])
    }

    @Test
    func jsonMasksTheArgumentAfterASecretFlag() {
        let (value, redacted) = redactJSON(["gh", "auth", "--token", "abc123", "--hostname", "github.com"])
        #expect(redacted)
        #expect(value == ["gh", "auth", "--token", "••••", "--hostname", "github.com"])
    }

    @Test
    func jsonUsageCountsAreNotSecrets() throws {
        let usage = try JSONValue.parse(Data(#"""
        {"input_tokens": 123, "output_tokens": 45, "cache_read_input_tokens": 9000,
         "max_tokens": 4096, "token_count": 7, "usage": {"total_tokens": 168}}
        """#.utf8))
        let (value, redacted) = redactJSON(usage)
        #expect(!redacted)
        #expect(value == usage)
        let text = #"{"input_tokens": 123, "output_tokens": 45, "prompt_tokens_details": {"cached_tokens": 0}}"#
        #expect(masked(text) == text)
    }

    // MARK: False positives

    @Test
    func ordinaryShapesAreNotMasked() {
        for text in [
            "commit 3f9c1a2b7d4e5f60718293a4b5c6d7e8f9012345",
            "git checkout 3f9c1a2",
            "/Users/me/src/made/apple/Sources/Pilot/AgentChat/AgentTranscript.swift",
            "~/Library/Application Support/Cockpit/sessions.json",
            "pip install scikit-learn sk-learn",
            "The token is invalid; please sign in again.",
            "key: ArrowUp",
            "Tokenizer finished: 512 tokens",
            "primary key constraint failed",
            "SELECT * FROM api_keys WHERE id = 1",
        ] {
            #expect(redactOutput(text) == AgentRedaction(text: text, redacted: false, truncatedLines: 0), "\(text)")
        }
    }

    // MARK: Inline, prose, files

    @Test
    func inlineFoldsLinesAndEscapesBidi() {
        #expect(redactInline("  ran\n\tgit status  \r\n") == "ran git status")
        #expect(redactInline("a\u{202E}b") == "a\\u{202E}b")
        #expect(redactInline("x\u{0007}y") == "x y")
        #expect(redactInline("export TOKEN=abc\nnext") == "export TOKEN=•••• next")
    }

    @Test
    func proseMasksOnlyKnownSecretShapes() {
        let prose = "Set password: hunter2 then\nuse sk-ant-api03-\(String(repeating: "k9", count: 15)) here."
        #expect(redactProse(prose) == "Set password: hunter2 then\nuse sk-a•••• here.")
        #expect(redactProse("The token is invalid.") == "The token is invalid.")
        #expect(redactProse("Set the cookie: it expires in a day.") == "Set the cookie: it expires in a day.")
    }

    @Test(arguments: [
        ".env", ".env.local", "/repo/.env.production", "cert.pem", "~/.ssh/id_rsa", "id_rsa.pub", "id_ed25519",
        "/home/u/.netrc", ".npmrc", "credentials", "/u/.aws/credentials.json",
    ])
    func secretLikeFilesMaskWholeContent(path: String) {
        #expect(isSecretLikePath(path))
        #expect(redactFileContent(path: path, text: "A=1\nB=2") == AgentRedaction(text: "••••", redacted: true, truncatedLines: 0))
    }

    @Test
    func ordinaryFilesUseThePatternTable() {
        for path in ["README.md", "/src/env.swift", "environment.ts", "pem.go", "my_credentials_test.go"] {
            #expect(!isSecretLikePath(path), "\(path)")
        }
        #expect(redactFileContent(path: "main.swift", text: "let a = 1").text == "let a = 1")
        #expect(redactFileContent(path: "config.yml", text: "token: abc").text == "token: ••••")
        #expect(redactFileContent(path: ".env", text: "") == AgentRedaction(text: "", redacted: false, truncatedLines: 0))
    }

    // MARK: Off-main and cache

    @Test
    func largeTextRedactsOffMainWithTheSameResult() async {
        let line = "token=abc and some filler text to reach the threshold quickly\n"
        let text = String(repeating: line, count: 2_000)
        #expect(text.utf8.count > AgentRedactionPolicy.offMainThresholdBytes)
        let background = await redactOutputInBackground(text)
        #expect(background == redactOutput(text))
        #expect(background.redacted)
        #expect(background.truncatedLines == 1_800)
        let small = await redactOutputInBackground("token=abc", maximumLines: nil)
        #expect(small.text == "token=••••")
    }

    @Test @MainActor
    func cacheIsKeyedByKeyRevisionAndVariant() {
        let cache = AgentRedactionCache(capacity: 3)
        var computed = 0
        func lookup(_ key: String, _ revision: Int, _ variant: String = "") -> AgentRedaction {
            cache.redaction(key: key, revision: revision, variant: variant) {
                computed += 1
                return redactOutput("token=\(key)\(revision)")
            }
        }
        _ = lookup("root/a", 1)
        _ = lookup("root/a", 1)
        #expect(computed == 1)
        _ = lookup("root/a", 1, "input")
        #expect(computed == 2)
        _ = lookup("root/a", 2)
        #expect(computed == 3)
        #expect(cache.cached(key: "root/a", revision: 1) == nil)
        #expect(cache.cached(key: "root/a", revision: 2)?.text == "token=••••")
        _ = lookup("root/b", 1)
        _ = lookup("root/c", 1)
        #expect(cache.count == 3)
        cache.removeAll()
        #expect(cache.cached(key: "root/c", revision: 1) == nil)
    }

    @Test
    func longValuesAreBoundedAndQuick() {
        let hostile = "token=" + String(repeating: "a", count: 200_000) + " " + String(repeating: "Bearer ", count: 5_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = redactOutput(hostile, maximumLines: nil) }
        #expect(elapsed < .seconds(2))
    }

    /// 256 KiB (the terminal-output bound) of shapes that make the keyed,
    /// flag, cookie, and URL patterns try hard at every position.
    @Test(arguments: [
        String(repeating: "a.", count: 131_072),
        String(repeating: "x_key", count: 52_000),
        String(repeating: "--token ", count: 32_000),
        "Cookie: " + String(repeating: "a=b; ", count: 50_000),
        String(repeating: "ab://user:", count: 26_000),
        String(repeating: "eyJ" + String(repeating: "a", count: 20) + ".", count: 11_000),
    ])
    func adversarialShapesStayLinear(hostile: String) {
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = redactOutput(hostile, maximumLines: nil) }
        #expect(elapsed < .seconds(2), "\(hostile.prefix(16))… took \(elapsed)")
    }
}
