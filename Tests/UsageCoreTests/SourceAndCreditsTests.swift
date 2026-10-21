import Foundation
import Testing
import UsageCore

/// Provenance (`Source`) and reset-credit provenance for Codex (AGENTS §10 #8/#9).
@Suite("Source and reset credits")
struct SourceAndCreditsTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)
    /// Always present on macOS; used as the "installed" binary path so no process is spawned.
    private let installedPath = "/usr/bin/true"

    // MARK: - Helpers

    /// Runs the app-server strategy against a canned `account/rateLimits/read` result.
    private func appServerSnapshot(result: String) async -> UsageSnapshot {
        let line = #"{"id":2,"result":\#(result)}"#
        let runner = FakeCodexProcessRunner(lines: [line])
        let client = CodexAppServerClient(
            runner: runner,
            executable: installedPath,
            environment: CredentialEnvironment(),
            clientVersion: "0.1.0"
        )
        let provider = CodexProvider(
            httpClient: ScriptedHTTPClient([]),
            credentialStore: StubCredentialStore(token: "codex-token"),
            appServerClient: client,
            strategies: [.appServer]
        )
        return await provider.fetch(now: now)
    }

    private static let withResetCredits = """
    {
      "rateLimitsByLimitId": {
        "codex": {
          "primary": {"usedPercent": 55, "windowMinutes": 300, "resetsAt": 1778670307},
          "secondary": {"usedPercent": 51, "windowMinutes": 10080, "resetsAt": 1779157165},
          "planType": "plus",
          "limitReached": false
        }
      },
      "rateLimitResetCredits": {"availableCount": 2}
    }
    """

    private static let withoutResetCredits = """
    {
      "rateLimits": {
        "primary": {"usedPercent": 20, "windowMinutes": 300},
        "planType": "plus"
      }
    }
    """

    private func snapshot(resetCredits: Int?) -> UsageSnapshot {
        UsageSnapshot(
            provider: .codex,
            plan: "plus",
            resetCredits: resetCredits,
            windows: [
                LimitWindow(
                    id: "codex.primary",
                    kind: .session5h,
                    label: "Session (5h)",
                    usedFraction: 0.55,
                    resetsAt: nil,
                    capturedAt: now.addingTimeInterval(-600)
                )
            ],
            source: .appServer,
            status: .ok,
            capturedAt: now.addingTimeInterval(-600)
        )
    }

    // MARK: - Codex app-server

    @Test("app-server reports the plan and reset credits in their own fields")
    func appServerSetsFields() async throws {
        let snapshot = await appServerSnapshot(result: Self.withResetCredits)

        #expect(snapshot.status == .ok)
        #expect(snapshot.source == .appServer)
        #expect(snapshot.plan == "plus")
        #expect(snapshot.resetCredits == 2)
        #expect(snapshot.plan?.contains("reset") == false)
    }

    @Test("no reset-credit block means nil, not zero")
    func appServerWithoutResetCredits() async {
        let snapshot = await appServerSnapshot(result: Self.withoutResetCredits)

        #expect(snapshot.status == .ok)
        #expect(snapshot.source == .appServer)
        #expect(snapshot.plan == "plus")
        #expect(snapshot.resetCredits == nil)
    }

    // MARK: - Codex HTTP fallback

    @Test("the HTTP strategy is .api and never claims reset credits")
    func httpStrategyIsAPI() async throws {
        let fixture = try TestFixtures.data("codex_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let provider = CodexProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "codex-token", accountID: "acct_123"),
            strategies: [.http]
        )

        let snapshot = await provider.fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.source == .api)
        #expect(snapshot.resetCredits == nil)
        #expect(snapshot.plan == "plus")
    }

    // MARK: - Snapshot mutations keep the count

    @Test("aged() keeps reset credits while promoting to stale")
    func agedKeepsResetCredits() {
        let aged = snapshot(resetCredits: 2).aged(now: now, staleAfter: 180)

        #expect(aged.resetCredits == 2)
        #expect(aged.status == .stale(age: 600))
        #expect(aged.capturedAt == now.addingTimeInterval(-600))
    }

    @Test("replacing(status:) keeps reset credits")
    func replacingKeepsResetCredits() {
        let replaced = snapshot(resetCredits: 3).replacing(status: .needsLogin)

        #expect(replaced.resetCredits == 3)
        #expect(replaced.plan == "plus")
        #expect(replaced.source == .appServer)
        #expect(replaced.status == .needsLogin)
    }

    @Test("a snapshot without reset credits stays nil through both mutations")
    func mutationsPreserveNil() {
        #expect(snapshot(resetCredits: nil).aged(now: now).resetCredits == nil)
        #expect(snapshot(resetCredits: nil).replacing(status: .needsLogin).resetCredits == nil)
    }

    // MARK: - Source truth table

    @Test("isDocumented is true only for the app-server path")
    func isDocumentedTruthTable() {
        #expect(Source.appServer.isDocumented)
        #expect(!Source.api.isDocumented)
        #expect(!Source.localLogs.isDocumented)
        #expect(!Source.cache.isDocumented)
    }

    @Test("isLive is true for provider-facing sources only")
    func isLiveTruthTable() {
        #expect(Source.api.isLive)
        #expect(Source.appServer.isLive)
        #expect(!Source.localLogs.isLive)
        #expect(!Source.cache.isLive)
    }

    @Test("labels stay stable and the raw value is app-server")
    func labels() {
        #expect(Source.appServer.rawValue == "app-server")
        #expect(Source.appServer.displayLabel == "app server")
        #expect(Source.api.displayLabel == "api")
        #expect(Source.localLogs.rawValue == "local-logs")
        #expect(Source.localLogs.displayLabel == "local logs")
        #expect(Source.cache.displayLabel == "cached")
    }

    @Test("source and credits round-trip through Codable; legacy JSON still decodes")
    func codable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let roundTripped = try decoder.decode(
            UsageSnapshot.self,
            from: try encoder.encode(snapshot(resetCredits: 2))
        )
        #expect(roundTripped.source == .appServer)
        #expect(roundTripped.resetCredits == 2)

        let encoded = try #require(String(data: try encoder.encode(Source.appServer), encoding: .utf8))
        #expect(encoded.contains("app-server"))

        // A cache entry written before `resetCredits` existed must still decode.
        let legacy = """
        {"provider":"codex","windows":[],"source":"api","status":{"type":"ok"},"capturedAt":792572000}
        """
        let decoded = try decoder.decode(UsageSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.resetCredits == nil)
        #expect(decoded.source == .api)
    }
}
