import Foundation
import Testing
import UsageCore

// MARK: - Fake transport (no real process is ever spawned, AGENTS §6)

/// Records the request handed to the app-server transport and replays canned JSON lines.
actor FakeCodexProcessRunner: CodexProcessRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let requestLines: [String]
        let timeout: TimeInterval
    }

    private let outcome: Result<[String], CodexAppServerError>
    private(set) var calls: [Call] = []

    init(lines: [String]) {
        outcome = .success(lines)
    }

    init(error: CodexAppServerError) {
        outcome = .failure(error)
    }

    func run(
        executable: String,
        arguments: [String],
        requestLines: [String],
        timeout: TimeInterval
    ) async throws -> [String] {
        calls.append(
            Call(
                executable: executable,
                arguments: arguments,
                requestLines: requestLines,
                timeout: timeout
            )
        )
        return try outcome.get()
    }
}

@Suite("Codex app-server strategy")
struct CodexAppServerTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)
    /// Always present on macOS; used as the "installed" binary path so no process is spawned.
    private let installedPath = "/usr/bin/true"
    private let missingPath = "/nonexistent/codex-\(UUID().uuidString)"

    // MARK: Fixtures

    private static let documentedResult = """
    {
      "rateLimitsByLimitId": {
        "codex": {
          "primary": {"usedPercent": 55, "windowMinutes": 300, "resetsAt": 1778670307},
          "secondary": {"usedPercent": 51, "windowMinutes": 10080, "resetsAt": 1779157165},
          "credits": {"hasCredits": true, "unlimited": false, "balance": "0"},
          "planType": "plus",
          "limitReached": false
        },
        "codex_other": {
          "primary": {"usedPercent": 12, "windowMinutes": 300}
        }
      },
      "rateLimits": {"primary": {"usedPercent": 55, "windowMinutes": 300}},
      "rateLimitResetCredits": {"availableCount": 2, "credits": [{"id": "x", "expiresAt": "2026-11-01T00:00:00Z"}]}
    }
    """

    private var documentedLines: [String] {
        [
            #"{"id":1,"result":{"userAgent":"codex-cli"}}"#,
            #"{"method":"initialized"}"#,
            Self.line(id: 2, result: Self.documentedResult)
        ]
    }

    private static func line(id: Int, result: String) -> String {
        #"{"id":\#(id),"result":\#(result)}"#
    }

    private func provider(
        runner: FakeCodexProcessRunner,
        http: ScriptedHTTPClient = ScriptedHTTPClient([]),
        strategies: [CodexStrategy] = [.appServer],
        executable: String? = nil,
        environment: CredentialEnvironment? = nil
    ) -> CodexProvider {
        let client = CodexAppServerClient(
            runner: runner,
            executable: executable ?? installedPath,
            environment: environment ?? CredentialEnvironment(),
            clientVersion: "0.1.0"
        )
        return CodexProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "codex-token"),
            appServerClient: client,
            strategies: strategies
        )
    }

    // MARK: Protocol shape

    @Test("sends initialize then account/rateLimits/read without a jsonrpc field")
    func requestShape() async throws {
        let runner = FakeCodexProcessRunner(lines: documentedLines)
        let snapshot = await provider(runner: runner).fetch(now: now)
        #expect(snapshot.status == .ok)

        let calls = await runner.calls
        let call = try #require(calls.first)
        #expect(call.executable == installedPath)
        #expect(call.arguments == ["app-server", "--listen", "stdio://"])
        #expect(call.timeout == 10)
        #expect(call.requestLines.count == 2)
        #expect(call.requestLines.allSatisfy { !$0.contains("\"jsonrpc\"") })

        let initialize = try #require(
            try JSONSerialization.jsonObject(with: Data(call.requestLines[0].utf8)) as? [String: Any]
        )
        #expect(initialize["id"] as? Int == 1)
        #expect(initialize["method"] as? String == "initialize")
        let params = try #require(initialize["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "Fillline")
        #expect(clientInfo["version"] as? String == "0.1.0")

        let read = try #require(
            try JSONSerialization.jsonObject(with: Data(call.requestLines[1].utf8)) as? [String: Any]
        )
        #expect(read["id"] as? Int == 2)
        #expect(read["method"] as? String == "account/rateLimits/read")
    }

    // MARK: Mapping

    @Test("maps buckets, epoch resets, credits, and reset credits")
    func mapsDocumentedResponse() async throws {
        let runner = FakeCodexProcessRunner(lines: documentedLines)
        let http = ScriptedHTTPClient([.init(statusCode: 500)])
        let snapshot = await provider(runner: runner, http: http).fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.source == .appServer)
        // Credits live in their own field now; the plan string stays a plain plan name.
        #expect(snapshot.plan == "plus")
        #expect(snapshot.resetCredits == 2)
        #expect(snapshot.windows.count == 4)

        let session = try #require(snapshot.window(kind: .session5h))
        #expect(abs(session.usedFraction - 0.55) < 1e-9)
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1_778_670_307))
        #expect(session.isEstimated == false)

        let weekly = try #require(snapshot.window(kind: .weekly7d))
        #expect(abs(weekly.usedFraction - 0.51) < 1e-9)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_779_157_165))

        let other = try #require(snapshot.windows.first { $0.id.hasSuffix(".codex_other.primary") })
        #expect(other.kind == .session5h)
        #expect(other.label == "Session (5h) (other)")
        #expect(abs(other.usedFraction - 0.12) < 1e-9)

        let credits = try #require(snapshot.window(kind: .credits))
        #expect(credits.label == "Credits · 0")
        #expect(credits.usedFraction == 0)
        #expect(credits.isEstimated == false)

        let calls = await http.callCount
        #expect(calls == 0)
    }

    @Test("accepts snake_case keys and an ISO-8601 reset time")
    func snakeCaseAndISO8601() async throws {
        let result = """
        {"rate_limits_by_limit_id":{"codex":{
          "primary":{"used_percent":42,"window_minutes":300,"reset_at":"2026-11-01T00:00:00Z"},
          "plan_type":"pro"}}}
        """
        let runner = FakeCodexProcessRunner(lines: [Self.line(id: 2, result: result)])
        let snapshot = await provider(runner: runner).fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.plan == "pro")
        let window = try #require(snapshot.window(kind: .session5h))
        #expect(abs(window.usedFraction - 0.42) < 1e-9)
        #expect(window.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
    }

    @Test("unknown windows get hour/day labels and the rolling kind")
    func windowLabels() async throws {
        let result = """
        {"rateLimitsByLimitId":{"codex":{
          "primary":{"usedPercent":10,"windowMinutes":4320},
          "secondary":{"usedPercent":20,"windowMinutes":90}}}}
        """
        let runner = FakeCodexProcessRunner(lines: [Self.line(id: 2, result: result)])
        let snapshot = await provider(runner: runner).fetch(now: now)

        let long = try #require(snapshot.windows.first { $0.id.hasSuffix(".primary") })
        #expect(long.kind == .rolling)
        #expect(long.label == "3d")

        let medium = try #require(snapshot.windows.first { $0.id.hasSuffix(".secondary") })
        #expect(medium.kind == .rolling)
        #expect(medium.label == "1h")
    }

    @Test("credits are hidden unless hasCredits is true and unlimited is false")
    func creditsVisibility() async throws {
        let noCredits = #"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":5,"windowMinutes":300},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}}}}"#
        let unlimited = #"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":5,"windowMinutes":300},"credits":{"hasCredits":true,"unlimited":true,"balance":"0"}}}}"#

        for result in [noCredits, unlimited] {
            let runner = FakeCodexProcessRunner(lines: [Self.line(id: 2, result: result)])
            let snapshot = await provider(runner: runner).fetch(now: now)
            #expect(snapshot.status == .ok)
            #expect(snapshot.window(kind: .credits) == nil)
        }
    }

    // MARK: Strategy order

    @Test("app-server wins and HTTP is never called")
    func prefersAppServer() async throws {
        let runner = FakeCodexProcessRunner(lines: documentedLines)
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: Data("{}".utf8))])
        let snapshot = await provider(
            runner: runner,
            http: http,
            strategies: [.appServer, .http]
        ).fetch(now: now)

        #expect(snapshot.status == .ok)
        let calls = await http.callCount
        #expect(calls == 0)
    }

    @Test("a missing binary reports notInstalled and falls back to HTTP")
    func missingBinaryFallsBack() async throws {
        let runner = FakeCodexProcessRunner(lines: documentedLines)
        let fixture = try TestFixtures.data("codex_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])

        let snapshot = await provider(
            runner: runner,
            http: http,
            strategies: [.appServer, .http],
            executable: missingPath
        ).fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.plan == "plus")
        let runnerCalls = await runner.calls
        #expect(runnerCalls.isEmpty)
        let httpCalls = await http.callCount
        #expect(httpCalls == 1)
    }

    @Test("a missing binary alone is notInstalled, never a generic error")
    func missingBinaryOnly() async throws {
        let runner = FakeCodexProcessRunner(lines: documentedLines)
        let snapshot = await provider(
            runner: runner,
            strategies: [.appServer],
            executable: missingPath
        ).fetch(now: now)

        #expect(snapshot.status == .notInstalled)
        #expect(snapshot.windows.isEmpty)
    }

    @Test("an app-server timeout falls back to wham/usage")
    func timeoutFallsBack() async throws {
        let runner = FakeCodexProcessRunner(error: .timedOut)
        let fixture = try TestFixtures.data("codex_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])

        let snapshot = await provider(
            runner: runner,
            http: http,
            strategies: [.appServer, .http]
        ).fetch(now: now)

        #expect(snapshot.status == .ok)
        let httpCalls = await http.callCount
        #expect(httpCalls == 1)
    }

    @Test("the last strategy failure is reported when both fail")
    func bothFail() async throws {
        let runner = FakeCodexProcessRunner(error: .timedOut)
        let http = ScriptedHTTPClient([.init(statusCode: 401)])
        let snapshot = await provider(
            runner: runner,
            http: http,
            strategies: [.appServer, .http]
        ).fetch(now: now)

        #expect(snapshot.status == .needsLogin)
    }

    // MARK: Failure mapping

    @Test("typed app-server failures map to status codes only")
    func failureCodes() async throws {
        let cases: [(CodexAppServerError, ProviderStatus)] = [
            (.timedOut, .error("app-server-timeout")),
            (.launchFailed, .error("app-server-launch")),
            (.ioFailed, .error("app-server-io")),
            (.incompleteResponse, .error("app-server-incomplete")),
            (.malformedResponse, .error("app-server-malformed")),
            (.rpcError(code: -32601), .error("app-server-rpc-32601")),
            (.rpcError(code: -32600, isAuthenticationRequired: true), .needsLogin)
        ]
        for (error, expected) in cases {
            let snapshot = await provider(
                runner: FakeCodexProcessRunner(error: error),
                strategies: [.appServer]
            ).fetch(now: now)
            #expect(snapshot.status == expected)
            #expect(snapshot.windows.isEmpty)
        }
    }

    @Test("an unauthenticated app-server is a login state, not a transport fallback")
    func appServerAuthRequiredIsNeedsLogin() async throws {
        // Captured from `codex-cli 0.163.0` with no logged-in account.
        let lines = [
            #"{"id":1,"result":{"userAgent":"Fillline/0.163.0 (macOS)","platformFamily":"unix"}}"#,
            #"{"id":2,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}"#
        ]
        let fixture = try TestFixtures.data("codex_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])

        let snapshot = await provider(
            runner: FakeCodexProcessRunner(lines: lines),
            http: http,
            strategies: [.appServer, .http]
        ).fetch(now: now)

        #expect(snapshot.status == .needsLogin)
        let httpCalls = await http.callCount
        #expect(httpCalls == 0)
    }

    @Test("an RPC error reply surfaces only its numeric code, never the message")
    func rpcErrorMessageIsNotLeaked() async throws {
        let lines = [
            "warning: not json, printed by the CLI",
            #"{"id":1,"result":{}}"#,
            #"{"id":2,"error":{"code":-32000,"message":"token=secret-value"}}"#
        ]
        let snapshot = await provider(
            runner: FakeCodexProcessRunner(lines: lines),
            strategies: [.appServer]
        ).fetch(now: now)

        #expect(snapshot.status == .error("app-server-rpc-32000"))
        #expect(snapshot.windows.isEmpty)
    }

    @Test("a reply without usable windows is empty-usage, not 0% remaining")
    func emptyResult() async throws {
        let runner = FakeCodexProcessRunner(lines: [Self.line(id: 2, result: "{}")])
        let snapshot = await provider(runner: runner).fetch(now: now)

        #expect(snapshot.status == .error("empty-usage"))
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.plan == nil)
    }

    @Test("a stream without the rate-limits reply is incomplete, not 0%")
    func incompleteStream() async throws {
        let lines = [#"{"id":1,"result":{}}"#, #"{"method":"initialized"}"#]
        let snapshot = await provider(
            runner: FakeCodexProcessRunner(lines: lines),
            strategies: [.appServer]
        ).fetch(now: now)

        #expect(snapshot.status == .error("app-server-incomplete"))
        #expect(snapshot.windows.isEmpty)
    }

    // MARK: Executable resolution

    @Test("resolves codex from PATH without spawning it")
    func resolvesFromPATH() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let environment = CredentialEnvironment(
            variables: ["PATH": root.path],
            homeDirectory: root
        )
        #expect(
            CodexAppServerClient.resolveExecutable("codex", environment: environment)
                == executable.path
        )

        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let emptyEnvironment = CredentialEnvironment(
            variables: ["PATH": empty.path],
            homeDirectory: root
        )
        #expect(CodexAppServerClient.resolveExecutable("codex", environment: emptyEnvironment) == nil)
        #expect(CodexAppServerClient.resolveExecutable(missingPath, environment: emptyEnvironment) == nil)
    }

    @Test("an explicit executable path bypasses PATH")
    func explicitPath() {
        let client = CodexAppServerClient(
            runner: FakeCodexProcessRunner(lines: []),
            executable: installedPath,
            environment: CredentialEnvironment(variables: ["PATH": ""])
        )
        #expect(client.resolvedExecutable() == installedPath)
    }
}
