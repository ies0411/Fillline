import Foundation
import Testing
import UsageCore

// MARK: - Shared test support
//
// All test files compile into the same `UsageCoreTests` module, so these helpers are
// declared once here and reused by the provider parsing tests.

enum TestFixtures {
    enum FixtureError: Error {
        case missing(String)
    }

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }
}

/// HTTP client that replays a fixed script. Never touches the network (AGENTS §6).
actor ScriptedHTTPClient: HTTPClient {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        init(statusCode: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    private var responses: [Response]
    private(set) var callCount = 0
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        requests.append(request)

        guard !responses.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let next = responses.removeFirst()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: next.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: next.headers
              )
        else {
            throw URLError(.badServerResponse)
        }
        return (next.body, response)
    }
}

/// Credential store returning a fixed token, or `.needsLogin` when `credential` is nil.
struct StubCredentialStore: CredentialStore {
    let credential: ProviderCredential?

    init(token: String? = "test-token", accountID: String? = nil, expiresAt: Date? = nil, planHint: String? = nil) {
        self.credential = token.map {
            ProviderCredential(
                accessToken: Credential($0),
                accountID: accountID.map(Credential.init),
                expiresAt: expiresAt,
                planHint: planHint
            )
        }
    }

    init(credential: ProviderCredential?) {
        self.credential = credential
    }

    func loadCredentials() throws -> ProviderCredential {
        guard let credential else { throw CredentialError.needsLogin }
        return credential
    }
}

/// Mutable clock for scheduler tests. Injected through `PollScheduler(clock:)`.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

// MARK: - Tests

@Suite("Poll scheduler")
struct PollSchedulerTests {
    private let start = Date(timeIntervalSince1970: 1_792_572_000)

    @Test("ok → rateLimited → ok, retaining last-good windows while limited")
    func statusTransitions() async throws {
        let fixture = try TestFixtures.data("claude_usage")
        let http = ScriptedHTTPClient([
            .init(statusCode: 200, body: fixture),
            .init(statusCode: 429, body: Data(), headers: ["Retry-After": "120"]),
            .init(statusCode: 200, body: fixture)
        ])
        let clock = TestClock(start)
        let provider = ClaudeCodeProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "test-token")
        )
        let scheduler = PollScheduler(providers: [provider], clock: { clock.now })

        let firstResult = await scheduler.poll(.claudeCode)
        let first = try #require(firstResult)
        #expect(first.status == .ok)
        #expect(first.windows.count == 3)

        let firstNextPoll = await scheduler.nextPollDate(for: .claudeCode)
        #expect(firstNextPoll == clock.now.addingTimeInterval(60))

        // Still cooling down: no extra network call.
        clock.advance(30)
        _ = await scheduler.poll(.claudeCode)
        let callsDuringCooldown = await http.callCount
        #expect(callsDuringCooldown == 1)

        // 429 with Retry-After: 120 wins over the 60s base backoff.
        clock.advance(30)
        let secondResult = await scheduler.poll(.claudeCode)
        let second = try #require(secondResult)
        guard case .rateLimited(let retryAfter) = second.status else {
            Issue.record("expected .rateLimited, got \(second.status)")
            return
        }
        #expect(retryAfter == 120)
        #expect(second.windows == first.windows)
        #expect(second.capturedAt == first.capturedAt)

        let limitedNextPoll = await scheduler.nextPollDate(for: .claudeCode)
        #expect(limitedNextPoll == clock.now.addingTimeInterval(120))

        clock.advance(119)
        _ = await scheduler.poll(.claudeCode)
        let callsWhileLimited = await http.callCount
        #expect(callsWhileLimited == 2)

        clock.advance(1)
        let thirdResult = await scheduler.poll(.claudeCode)
        let third = try #require(thirdResult)
        #expect(third.status == .ok)
        #expect(third.capturedAt == clock.now)

        let callsAfterRecovery = await http.callCount
        #expect(callsAfterRecovery == 3)
    }

    @Test("agedSnapshots turns an old ok snapshot into stale(age:)")
    func staleAging() async throws {
        let fixture = try TestFixtures.data("claude_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let clock = TestClock(start)
        let provider = ClaudeCodeProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "test-token")
        )
        let scheduler = PollScheduler(providers: [provider], clock: { clock.now })

        _ = await scheduler.poll(.claudeCode)
        clock.advance(600)

        let aged = await scheduler.agedSnapshots()
        let snapshot = try #require(aged[.claudeCode])
        guard case .stale(let age) = snapshot.status else {
            Issue.record("expected .stale, got \(snapshot.status)")
            return
        }
        #expect(abs(age - 600) < 0.001)
        #expect(snapshot.windows.count == 3)
    }

    @Test("HTTP 500 keeps last-good windows and retries after backoff")
    func errorRetainsValues() async throws {
        let fixture = try TestFixtures.data("claude_usage")
        let http = ScriptedHTTPClient([
            .init(statusCode: 200, body: fixture),
            .init(statusCode: 500)
        ])
        let clock = TestClock(start)
        let provider = ClaudeCodeProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "test-token")
        )
        let scheduler = PollScheduler(providers: [provider], clock: { clock.now })

        let firstResult = await scheduler.poll(.claudeCode)
        let first = try #require(firstResult)

        clock.advance(60)
        let secondResult = await scheduler.poll(.claudeCode)
        let second = try #require(secondResult)

        #expect(second.status == .error("http-500"))
        #expect(second.windows == first.windows)
        #expect(second.capturedAt == first.capturedAt)

        let nextPoll = await scheduler.nextPollDate(for: .claudeCode)
        #expect(nextPoll == clock.now.addingTimeInterval(60))
    }

    @Test("401 needs login and backs off without hammering")
    func needsLoginBackoff() async throws {
        let http = ScriptedHTTPClient([.init(statusCode: 401)])
        let clock = TestClock(start)
        let provider = ClaudeCodeProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "test-token")
        )
        let scheduler = PollScheduler(providers: [provider], clock: { clock.now })

        let result = await scheduler.poll(.claudeCode)
        let snapshot = try #require(result)
        #expect(snapshot.status == .needsLogin)

        let nextPoll = await scheduler.nextPollDate(for: .claudeCode)
        #expect(nextPoll == clock.now.addingTimeInterval(1_800))
    }

    @Test("providers keep independent schedules (Claude override 180s, Codex 60s)")
    func independentSchedules() async throws {
        let claudeFixture = try TestFixtures.data("claude_usage")
        let codexFixture = try TestFixtures.data("codex_usage")

        let claudeHTTP = ScriptedHTTPClient([
            .init(statusCode: 200, body: claudeFixture),
            .init(statusCode: 200, body: claudeFixture)
        ])
        let codexHTTP = ScriptedHTTPClient([
            .init(statusCode: 200, body: codexFixture),
            .init(statusCode: 200, body: codexFixture)
        ])

        let clock = TestClock(start)
        let claude = ClaudeCodeProvider(
            httpClient: claudeHTTP,
            credentialStore: StubCredentialStore(token: "test-token")
        )
        let codex = CodexProvider(
            httpClient: codexHTTP,
            credentialStore: StubCredentialStore(token: "codex-token"),
            strategies: [.http]
        )
        let configuration = PollScheduler.Configuration(
            minimumIntervalOverrides: [.claudeCode: 180]
        )
        let scheduler = PollScheduler(
            providers: [claude, codex],
            configuration: configuration,
            clock: { clock.now }
        )

        _ = await scheduler.pollAll()
        let claudeCallsAfterFirst = await claudeHTTP.callCount
        let codexCallsAfterFirst = await codexHTTP.callCount
        #expect(claudeCallsAfterFirst == 1)
        #expect(codexCallsAfterFirst == 1)

        clock.advance(60)
        _ = await scheduler.pollAll()
        let claudeCallsAfterMinute = await claudeHTTP.callCount
        let codexCallsAfterMinute = await codexHTTP.callCount
        #expect(claudeCallsAfterMinute == 1)
        #expect(codexCallsAfterMinute == 2)
    }

    @Test("configuration enforces the 60s floor")
    func minimumIntervalFloor() {
        let configuration = PollScheduler.Configuration(
            baseInterval: 5,
            minimumIntervalOverrides: [.codex: 10]
        )
        #expect(configuration.interval(for: .claudeCode) == 60)
        #expect(configuration.interval(for: .codex) == 60)
    }
}
