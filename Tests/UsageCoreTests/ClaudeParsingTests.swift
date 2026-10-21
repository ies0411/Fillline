import Foundation
import Testing
import UsageCore

@Suite("Claude usage parsing")
struct ClaudeParsingTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)

    @Test("parses limits[] into session, weekly, and scoped windows")
    func parsesLimits() async throws {
        let fixture = try TestFixtures.data("claude_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let provider = ClaudeCodeProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "test-token", planHint: "max")
        )

        let snapshot = await provider.fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.provider == .claudeCode)
        #expect(snapshot.source == .api)
        #expect(snapshot.plan == "max")
        #expect(snapshot.windows.count == 3)

        let session = try #require(snapshot.window(kind: .session5h))
        #expect(abs(session.usedFraction - 0.02) < 1e-9)
        #expect(abs(session.remainingFraction - 0.98) < 1e-9)
        let sessionReset = try #require(session.resetsAt)
        // 2026-10-21T08:39:59.776536+00:00 — 6-digit fractional seconds.
        #expect(abs(sessionReset.timeIntervalSince1970 - 1_792_571_999.776536) < 0.01)

        let weekly = try #require(snapshot.window(kind: .weekly7d))
        #expect(abs(weekly.usedFraction - 0.20) < 1e-9)
        let weeklyReset = try #require(weekly.resetsAt)
        #expect(abs(weeklyReset.timeIntervalSince1970 - 1_792_857_599.776553) < 0.01)

        let scoped = try #require(snapshot.window(kind: .weeklyScoped))
        #expect(scoped.label == "Fable")
        #expect(scoped.usedFraction == 0)
        #expect(scoped.isEstimated == false)
    }

    @Test("sends the mandatory Claude Code User-Agent, beta, and bearer headers")
    func requestHeaders() async throws {
        let fixture = try TestFixtures.data("claude_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let provider = ClaudeCodeProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "test-token")
        )

        _ = await provider.fetch(now: now)

        let requests = await http.requests
        let request = try #require(requests.first)
        #expect(request.url == ClaudeCodeEndpoints.usage)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.80")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test("falls back to five_hour when limits[] is absent")
    func fallsBackToBuckets() async throws {
        let json = """
        {
          "five_hour": {
            "utilization": 12.5,
            "resets_at": "2026-10-21T08:39:59.776536+00:00"
          },
          "seven_day": null,
          "seven_day_opus": null
        }
        """
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: Data(json.utf8))])
        let provider = ClaudeCodeProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "test-token")
        )

        let snapshot = await provider.fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 1)
        let window = try #require(snapshot.window(kind: .session5h))
        #expect(abs(window.usedFraction - 0.125) < 1e-9)
        #expect(abs(window.remainingFraction - 0.875) < 1e-9)
    }

    @Test("maps 401 to needsLogin and 429 to rateLimited with Retry-After")
    func statusMapping() async throws {
        let unauthorizedHTTP = ScriptedHTTPClient([.init(statusCode: 401)])
        let unauthorizedProvider = ClaudeCodeProvider(
            httpClient: unauthorizedHTTP,
            credentialStore: StubCredentialStore(token: "test-token")
        )
        let unauthorized = await unauthorizedProvider.fetch(now: now)
        #expect(unauthorized.status == .needsLogin)
        #expect(unauthorized.windows.isEmpty)

        let limitedHTTP = ScriptedHTTPClient([
            .init(statusCode: 429, headers: ["Retry-After": "300"])
        ])
        let limitedProvider = ClaudeCodeProvider(
            httpClient: limitedHTTP,
            credentialStore: StubCredentialStore(token: "test-token")
        )
        let limited = await limitedProvider.fetch(now: now)
        guard case .rateLimited(let retryAfter) = limited.status else {
            Issue.record("expected .rateLimited, got \(limited.status)")
            return
        }
        #expect(retryAfter == 300)
    }

    @Test("a malformed payload does not become a fake 0%")
    func malformedPayload() async throws {
        let http = ScriptedHTTPClient([
            .init(statusCode: 200, body: Data("not-json".utf8))
        ])
        let provider = ClaudeCodeProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "test-token")
        )

        let snapshot = await provider.fetch(now: now)
        #expect(snapshot.status == .error("decoding-failed"))
        #expect(snapshot.windows.isEmpty)
    }
}
