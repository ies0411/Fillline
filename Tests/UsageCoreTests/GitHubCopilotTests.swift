import Foundation
import Testing
import UsageCore

@Suite("GitHub Copilot usage parsing")
struct GitHubCopilotTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)

    private func makeProvider(
        http: ScriptedHTTPClient,
        token: String? = "fixture-copilot-token"
    ) -> GitHubCopilotProvider {
        GitHubCopilotProvider(
            httpClient: http,
            tokenStore: StubGitHubTokenProvider(token: token)
        )
    }

    @Test("maps percent_remaining to used fraction and skips unmetered buckets")
    func parsesFixture() async throws {
        let fixture = try TestFixtures.data("copilot_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let snapshot = await makeProvider(http: http).fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.provider == .githubCopilot)
        #expect(snapshot.plan == "Individual")
        // `premium_requests` has a zero entitlement and `completions` is unlimited: neither
        // may become a 0% or 100% bar (issue #14 trap).
        #expect(snapshot.windows.count == 2)

        let premium = try #require(snapshot.window(kind: .monthly))
        #expect(premium.label == "Premium")
        #expect(abs(premium.usedFraction - 0.6) < 1e-9)
        #expect(abs(premium.remainingFraction - 0.4) < 1e-9)
        #expect(premium.resetsAt == Date(timeIntervalSince1970: 1_793_520_000))

        let chat = try #require(snapshot.windows.first { $0.id.hasSuffix(".chat") })
        // `entitlement` and `percent_remaining` arrive as strings here.
        #expect(abs(chat.usedFraction - 0.25) < 1e-9)
        #expect(chat.resetsAt == Date(timeIntervalSince1970: 1_793_491_200))

        #expect(snapshot.windows.contains { $0.id.hasSuffix(".completions") } == false)
        #expect(snapshot.windows.contains { $0.id.hasSuffix(".premium_requests") } == false)
    }

    @Test("a zero quota_reset_at is ignored; the UTC reset date is used")
    func zeroResetEpoch() async throws {
        // Shape observed on a free limited account (2026-10-22): every `quota_reset_at` is 0,
        // `has_quota` marks the unmetered bucket, and the real reset is `quota_reset_date_utc`.
        let body = Data(
            #"""
            {"copilot_plan":"individual","quota_reset_date":"2026-11-01",
             "quota_reset_date_utc":"2026-11-01T00:00:00.000Z",
             "quota_snapshots":{
               "premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":0.0,
                 "unlimited":false,"quota_reset_at":0,"has_quota":false},
               "chat":{"entitlement":200,"remaining":150,"percent_remaining":75.0,
                 "unlimited":false,"quota_reset_at":0,"has_quota":true}}}
            """#.utf8
        )
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: body)])
        let snapshot = await makeProvider(http: http).fetch(now: now)

        #expect(snapshot.windows.count == 1)
        let chat = try #require(snapshot.window(kind: .monthly))
        #expect(chat.label == "Chat")
        #expect(abs(chat.usedFraction - 0.25) < 1e-9)
        #expect(chat.resetsAt == Date(timeIntervalSince1970: 1_793_491_200))
    }

    @Test("an all-unlimited payload reports no windows instead of 100%")
    func allUnlimited() async throws {
        let body = Data(
            #"{"copilot_plan":"business","quota_snapshots":{"chat":{"unlimited":true,"entitlement":0},"completions":{"unlimited":"true"}}}"#
                .utf8
        )
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: body)])
        let snapshot = await makeProvider(http: http).fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.hasValues == false)
        #expect(snapshot.plan == "Business")
    }

    @Test("401 is a login problem, 403 has no seat, 404 is unsupported")
    func statusMapping() async {
        let unauthorized = await makeProvider(
            http: ScriptedHTTPClient([.init(statusCode: 401)])
        ).fetch(now: now)
        #expect(unauthorized.status == .needsLogin)

        let forbidden = await makeProvider(
            http: ScriptedHTTPClient([.init(statusCode: 403)])
        ).fetch(now: now)
        #expect(forbidden.status == .notSubscribed)

        let missing = await makeProvider(
            http: ScriptedHTTPClient([.init(statusCode: 404)])
        ).fetch(now: now)
        #expect(missing.status == .unsupported)
    }

    @Test("a missing token never reaches the network")
    func missingToken() async {
        let http = ScriptedHTTPClient([.init(statusCode: 200)])
        let provider = GitHubCopilotProvider(
            httpClient: http,
            tokenStore: StubGitHubTokenProvider(token: nil, error: .needsLogin)
        )

        let snapshot = await provider.fetch(now: now)

        #expect(snapshot.status == .needsLogin)
        let requests = await http.requests
        #expect(requests.isEmpty)
    }

    @Test("sends the Copilot editor headers")
    func requestHeaders() async throws {
        let fixture = try TestFixtures.data("copilot_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])

        _ = await makeProvider(http: http).fetch(now: now)

        let requests = await http.requests
        let request = try #require(requests.first)
        #expect(request.url == GitHubCopilotEndpoints.usage)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-copilot-token")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == GitHubCopilotEndpoints.userAgent)
        #expect(
            request.value(forHTTPHeaderField: "Editor-Version")
                == GitHubCopilotEndpoints.editorVersion
        )
        #expect(
            request.value(forHTTPHeaderField: "Editor-Plugin-Version")
                == GitHubCopilotEndpoints.editorPluginVersion
        )
    }
}

@Suite("GitHub Copilot token discovery")
struct GitHubCopilotTokenTests {
    private func environment(_ variables: [String: String]) -> CredentialEnvironment {
        CredentialEnvironment(
            variables: variables,
            homeDirectory: URL(fileURLWithPath: "/tmp/fillline-tests")
        )
    }

    @Test("GH_TOKEN wins over GITHUB_TOKEN and over gh")
    func environmentOrder() async throws {
        let recorder = GitHubCLIRecorder()
        let store = GitHubTokenStore(
            environment: environment(["GH_TOKEN": "first-token", "GITHUB_TOKEN": "second-token"]),
            runner: StubGitHubCLI(
                recorder: recorder,
                output: .init(exitCode: 0, stdout: Data(), stderrByteCount: 0)
            ),
            executable: "/usr/bin/true"
        )

        let credential = try await store.loadToken()

        #expect(credential.accessToken.reveal() == "first-token")
        #expect(recorder.count == 0)
    }

    @Test("falls back to GITHUB_TOKEN")
    func githubTokenVariable() async throws {
        let store = GitHubTokenStore(
            environment: environment(["GITHUB_TOKEN": "second-token"]),
            runner: StubGitHubCLI(
                recorder: nil,
                output: .init(exitCode: 0, stdout: Data(), stderrByteCount: 0)
            ),
            executable: "/usr/bin/true"
        )

        #expect(try await store.loadToken().accessToken.reveal() == "second-token")
    }

    @Test("runs `gh auth token` with no browser and no shell")
    func cliFallback() async throws {
        let recorder = GitHubCLIRecorder()
        let store = GitHubTokenStore(
            environment: environment(["HOME": "/tmp/fillline-tests", "PATH": "/usr/bin"]),
            runner: StubGitHubCLI(
                recorder: recorder,
                output: .init(exitCode: 0, stdout: Data("fixture-gh-token\n".utf8), stderrByteCount: 12)
            ),
            executable: "/usr/bin/true"
        )

        let credential = try await store.loadToken()

        #expect(credential.accessToken.reveal() == "fixture-gh-token")
        let invocation = try #require(recorder.last)
        #expect(invocation.executable == "/usr/bin/true")
        #expect(invocation.arguments == ["auth", "token"])
        #expect(invocation.environment["BROWSER"] == "/usr/bin/false")
        #expect(invocation.environment["GH_PROMPT_DISABLED"] == "1")
    }

    @Test("a signed-out gh is a login state, not an error")
    func signedOut() async {
        let store = GitHubTokenStore(
            environment: environment(["HOME": "/tmp/fillline-tests"]),
            runner: StubGitHubCLI(
                recorder: nil,
                output: .init(exitCode: 1, stdout: Data(), stderrByteCount: 64)
            ),
            executable: "/usr/bin/true"
        )

        await #expect(throws: CredentialError.needsLogin) {
            _ = try await store.loadToken()
        }
    }

    @Test("a missing gh binary is notInstalled and spawns nothing")
    func notInstalled() async {
        let recorder = GitHubCLIRecorder()
        let store = GitHubTokenStore(
            environment: environment(["HOME": "/tmp/fillline-tests"]),
            runner: StubGitHubCLI(
                recorder: recorder,
                output: .init(exitCode: 0, stdout: Data(), stderrByteCount: 0)
            ),
            executable: "/nonexistent/gh-for-tests"
        )

        #expect(store.isCLIInstalled == false)
        await #expect(throws: CredentialError.notInstalled) {
            _ = try await store.loadToken()
        }
        #expect(recorder.count == 0)
    }

    @Test("a hung gh times out with a stable code")
    func timeout() async {
        let store = GitHubTokenStore(
            environment: environment(["HOME": "/tmp/fillline-tests"]),
            runner: StubGitHubCLI(recorder: nil, error: .timedOut),
            executable: "/usr/bin/true"
        )

        await #expect(throws: CredentialError.malformed("gh-token-timeout")) {
            _ = try await store.loadToken()
        }
    }
}

// MARK: - Doubles

struct StubGitHubTokenProvider: GitHubTokenProviding {
    let token: String?
    let error: CredentialError?

    init(token: String? = nil, error: CredentialError? = nil) {
        self.token = token
        self.error = error
    }

    func loadToken() async throws -> ProviderCredential {
        if let error { throw error }
        guard let token else { throw CredentialError.needsLogin }
        return ProviderCredential(accessToken: Credential(token))
    }
}

/// Records invocations so the tests can assert the exact child process shape.
final class GitHubCLIRecorder: @unchecked Sendable {
    struct Invocation: Sendable, Hashable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations.count
    }

    var last: Invocation? {
        lock.lock()
        defer { lock.unlock() }
        return invocations.last
    }

    func record(_ invocation: Invocation) {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(invocation)
    }
}

struct StubGitHubCLI: GitHubCLIRunning {
    let recorder: GitHubCLIRecorder?
    let output: GitHubCLIOutput?
    let error: GitHubCLIError?

    init(recorder: GitHubCLIRecorder?, output: GitHubCLIOutput? = nil, error: GitHubCLIError? = nil) {
        self.recorder = recorder
        self.output = output
        self.error = error
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> GitHubCLIOutput {
        recorder?.record(
            GitHubCLIRecorder.Invocation(
                executable: executable,
                arguments: arguments,
                environment: environment
            )
        )
        if let error { throw error }
        return output ?? GitHubCLIOutput(exitCode: 0, stdout: Data(), stderrByteCount: 0)
    }
}
