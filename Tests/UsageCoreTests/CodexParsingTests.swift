import Foundation
import Testing
import UsageCore

@Suite("Codex usage parsing")
struct CodexParsingTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)

    @Test("parses primary and secondary windows from the contract fixture")
    func parsesFixture() async throws {
        let fixture = try TestFixtures.data("codex_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let provider = CodexProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "codex-token", accountID: "acct_123"),
            strategies: [.http]
        )

        let snapshot = await provider.fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.provider == .codex)
        #expect(snapshot.plan == "plus")
        #expect(snapshot.windows.count == 2)

        let primary = try #require(snapshot.window(kind: .session5h))
        #expect(abs(primary.usedFraction - 0.55) < 1e-9)
        #expect(abs(primary.remainingFraction - 0.45) < 1e-9)
        // `reset_at` is epoch seconds: 1778670307.
        #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_778_670_307))
        #expect(primary.isEstimated == false)

        let secondary = try #require(snapshot.window(kind: .weekly7d))
        #expect(abs(secondary.usedFraction - 0.51) < 1e-9)
        #expect(secondary.resetsAt == Date(timeIntervalSince1970: 1_779_157_165))
        #expect(secondary.isEstimated == false)
    }

    @Test("sends bearer, account id, and codex-cli user agent")
    func requestHeaders() async throws {
        let fixture = try TestFixtures.data("codex_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let provider = CodexProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "codex-token", accountID: "acct_123"),
            strategies: [.http]
        )

        _ = await provider.fetch(now: now)

        let requests = await http.requests
        let request = try #require(requests.first)
        #expect(request.url == CodexEndpoints.usage)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer codex-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct_123")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "codex-cli")
    }

    @Test("missing auth.json surfaces as notInstalled without a network call")
    func notInstalled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = CredentialEnvironment(
            variables: ["CODEX_HOME": root.path],
            homeDirectory: root
        )
        let http = ScriptedHTTPClient([])
        let provider = CodexProvider(
            httpClient: http,
            credentialStore: CodexAuthStore(environment: environment),
            strategies: [.http]
        )

        let snapshot = await provider.fetch(now: now)

        #expect(snapshot.status == .notInstalled)
        let calls = await http.callCount
        #expect(calls == 0)
    }

    @Test("an empty rate_limit block is an error, not 100% remaining")
    func emptyUsage() async throws {
        let json = #"{"plan_type":"plus","rate_limit":{"primary_window":null,"secondary_window":null}}"#
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: Data(json.utf8))])
        let provider = CodexProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "codex-token"),
            strategies: [.http]
        )

        let snapshot = await provider.fetch(now: now)
        #expect(snapshot.status == .error("empty-usage"))
        #expect(snapshot.windows.isEmpty)
    }

    @Test("reset_after_seconds is used but marked estimated")
    func estimatedReset() async throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 600
            }
          }
        }
        """
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: Data(json.utf8))])
        let provider = CodexProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "codex-token"),
            strategies: [.http]
        )

        let snapshot = await provider.fetch(now: now)
        let window = try #require(snapshot.window(kind: .session5h))
        #expect(window.resetsAt == now.addingTimeInterval(600))
        #expect(window.isEstimated == true)
    }
}
