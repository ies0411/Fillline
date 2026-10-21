import Foundation
import Testing
import UsageCore

// MARK: - Fake transport (no real process is ever spawned, AGENTS §6)

/// Records exactly what the provider hands to the transport and replays a canned result.
actor FakeAntigravityProcessRunner: AntigravityProcessRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval
    }

    private let outcome: Result<AntigravityProcessOutput, AntigravityProcessError>
    private(set) var calls: [Call] = []

    init(
        stdout: Data, exitCode: Int32 = 0, stderrHint: AntigravityStderrHint = .none, stderrByteCount: Int = 0
    ) {
        outcome = .success(
            AntigravityProcessOutput(
                exitCode: exitCode,
                stdout: stdout,
                stderrHint: stderrHint,
                stderrByteCount: stderrByteCount
            )
        )
    }

    init(error: AntigravityProcessError) {
        outcome = .failure(error)
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> AntigravityProcessOutput {
        calls.append(
            Call(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        )
        return try outcome.get()
    }
}

@Suite("Antigravity provider")
struct AntigravityTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)
    /// Always executable on macOS; used as the "installed" path so nothing is spawned.
    private let installedPath = "/usr/bin/true"

    // MARK: Helpers

    private func provider(
        runner: FakeAntigravityProcessRunner,
        executable: String? = nil,
        variables: [String: String] = ["PATH": "/usr/bin:/bin"]
    ) -> AntigravityProvider {
        AntigravityProvider(
            runner: runner,
            executable: executable ?? installedPath,
            environment: CredentialEnvironment(
                variables: variables,
                homeDirectory: URL(fileURLWithPath: "/tmp")
            ),
            timeout: AntigravityEndpoints.timeout
        )
    }

    private func fetch(json: String) async -> UsageSnapshot {
        let runner = FakeAntigravityProcessRunner(stdout: Data(json.utf8))
        return await provider(runner: runner).fetch(now: now)
    }

    // MARK: Invocation contract

    @Test("invokes agy with the documented argv, private env, and 95s deadline")
    func invocationContract() async throws {
        let runner = FakeAntigravityProcessRunner(
            stdout: Data(#"{"command":{"name":"usage","data":{"groups":[]}}}"#.utf8))
        let variables = [
            "PATH": "/usr/bin:/bin",
            "ANTIGRAVITY_CLI_PATH": installedPath,
            "DISPLAY": ":0",
            "GOOGLE_APPLICATION_CREDENTIALS": "/secrets/ya29.never-read",
        ]
        let snapshot = await provider(runner: runner, executable: nil, variables: variables)
            .fetch(now: now)

        #expect(snapshot.status == .unsupported)

        let calls = await runner.calls
        let call = try #require(calls.first)
        #expect(call.executable == installedPath)
        #expect(call.arguments == ["-p", "/usage", "--output-format", "json", "--print-timeout", "90s"])
        #expect(call.timeout == 95)
        // A silent-auth failure must not be able to pop a browser.
        #expect(call.environment["BROWSER"] == "/usr/bin/false")
        #expect(call.environment["DISPLAY"] == nil)
        // The environment is inherited, not rewritten: no credential is stripped or added.
        #expect(call.environment["PATH"] == "/usr/bin:/bin")
    }

    // MARK: Mapping

    @Test("maps two groups × two windows and inverts remaining into used")
    func mapsFixture() async throws {
        let runner = FakeAntigravityProcessRunner(stdout: try TestFixtures.data("antigravity_usage"))
        let snapshot = await provider(runner: runner).fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.provider == .antigravity)
        #expect(snapshot.source == .api)
        #expect(snapshot.plan == nil)
        #expect(snapshot.windows.count == 4)

        let gemini5h = snapshot.windows[0]
        #expect(gemini5h.id == "antigravity.gemini-5h")
        #expect(gemini5h.kind == .session5h)
        #expect(gemini5h.label == "Gemini · 5h")
        // 0.82 REMAINING → 0.18 used.
        #expect(abs(gemini5h.usedFraction - 0.18) < 0.000_001)
        #expect(abs(gemini5h.remainingFraction - 0.82) < 0.000_001)
        #expect(gemini5h.isEstimated == false)
        #expect(gemini5h.resetsAt == Date(timeIntervalSince1970: 1_792_584_000))

        let geminiWeekly = snapshot.windows[1]
        #expect(geminiWeekly.kind == .weekly7d)
        #expect(geminiWeekly.label == "Gemini · Weekly")
        #expect(abs(geminiWeekly.usedFraction - 0.36) < 0.000_001)

        let threeP5h = snapshot.windows[2]
        #expect(threeP5h.kind == .session5h)
        #expect(threeP5h.label == "3P · 5h")
        #expect(abs(threeP5h.usedFraction - 0.65) < 0.000_001)

        let threePWeekly = snapshot.windows[3]
        #expect(threePWeekly.kind == .weekly7d)
        #expect(threePWeekly.label == "3P · Weekly")
        #expect(abs(threePWeekly.usedFraction - 0.29) < 0.000_001)
    }

    @Test("free-tier weekly-only report never gains a synthetic 5h row")
    func weeklyOnly() async {
        let json = """
            {"command":{"name":"usage","data":{"groups":[
              {"displayName":"Gemini Models","buckets":[
                {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2026-10-27T00:00:00Z","remainingFraction":0.64}
              ]}
            ]}}}
            """
        let snapshot = await fetch(json: json)

        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.window(kind: .weekly7d) != nil)
        #expect(snapshot.window(kind: .session5h) == nil)
    }

    @Test("accepts snake_case keys and a fractional ISO reset time")
    func snakeCaseAndISO8601() async throws {
        let json = """
            {"data":{"groups":[
              {"display_name":"Claude and GPT models","buckets":[
                {"bucket_id":"3p-5h","window":"5h","reset_time":"2026-10-21T12:00:00.123Z","remaining_fraction":0.4}
              ]}
            ]}}
            """
        let snapshot = await fetch(json: json)

        #expect(snapshot.status == .ok)
        let window = try #require(snapshot.windows.first)
        #expect(window.label == "3P · 5h")
        #expect(abs(window.usedFraction - 0.6) < 0.000_001)
        #expect(window.resetsAt != nil)
        // Millisecond precision is preserved, not truncated away.
        let millis = try #require(window.resetsAt).timeIntervalSince1970
        #expect(abs(millis - 1_792_584_000.123) < 0.01)
    }

    @Test("skips buckets that carry only a reset time")
    func skipsRowsWithoutFraction() async {
        let json = """
            {"data":{"groups":[
              {"displayName":"Gemini Models","buckets":[
                {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2026-10-27T00:00:00Z","remainingFraction":0.64},
                {"bucketId":"gemini-5h","window":"5h","resetTime":"2026-10-21T12:00:00Z"}
              ]}
            ]}}
            """
        let snapshot = await fetch(json: json)

        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.id == "antigravity.gemini-weekly")
    }

    @Test("enterprise report without a usage panel is unsupported, not 0%")
    func panelMissing() async {
        let json = #"{"command":{"name":"usage","data":{"message":"Usage is not shown for this plan."}}}"#
        let snapshot = await fetch(json: json)

        #expect(snapshot.status == .unsupported)
        #expect(snapshot.windows.isEmpty)
    }

    // MARK: Failure modes

    @Test("missing binary reports notInstalled and never runs anything")
    func missingBinary() async {
        let runner = FakeAntigravityProcessRunner(stdout: Data("{}".utf8))
        let missing = "/nonexistent/agy-\(UUID().uuidString)"
        let snapshot = await provider(runner: runner, executable: missing).fetch(now: now)

        #expect(snapshot.status == .notInstalled)
        let calls = await runner.calls
        #expect(calls.isEmpty)
    }

    @Test("auth-looking stderr maps to needsLogin")
    func authFailure() async {
        let runner = FakeAntigravityProcessRunner(
            stdout: Data(),
            exitCode: 1,
            stderrHint: .authenticationRequired,
            stderrByteCount: 128
        )
        let snapshot = await provider(runner: runner).fetch(now: now)

        #expect(snapshot.status == .needsLogin)
        #expect(snapshot.windows.isEmpty)
    }

    @Test("non-auth non-zero exit keeps the exit code only")
    func otherFailure() async {
        let runner = FakeAntigravityProcessRunner(
            stdout: Data(),
            exitCode: 3,
            stderrHint: .other,
            stderrByteCount: 64
        )
        let snapshot = await provider(runner: runner).fetch(now: now)

        #expect(snapshot.status == .error("exit-3"))
    }

    @Test("timeout maps to the stable timeout code")
    func timeout() async {
        let runner = FakeAntigravityProcessRunner(error: .timedOut)
        let snapshot = await provider(runner: runner).fetch(now: now)

        guard case .error(let code) = snapshot.status else {
            Issue.record("expected .error, got \(snapshot.status)")
            return
        }
        #expect(code == "timeout")
    }

    // MARK: Unrecognised envelope

    @Test("unrecognised envelope falls back to plain text and marks windows estimated")
    func textFallback() async throws {
        let runner = FakeAntigravityProcessRunner(stdout: Data(Self.plainTextReport.utf8))
        let snapshot = await provider(runner: runner).fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 2)

        let gemini = try #require(snapshot.windows.first)
        #expect(gemini.kind == .session5h)
        #expect(gemini.label == "Gemini · 5h")
        #expect(abs(gemini.usedFraction - 0.18) < 0.000_001)
        #expect(gemini.isEstimated)

        let threeP = snapshot.windows[1]
        #expect(threeP.kind == .weekly7d)
        #expect(threeP.label == "3P · Weekly")
        #expect(abs(threeP.usedFraction - 0.29) < 0.000_001)
        #expect(threeP.isEstimated)
    }

    @Test("text wrapped in an unrecognised JSON envelope is still recovered")
    func textFallbackInsideJSON() async {
        let escaped = Self.plainTextReport
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = #"{"result":"\#(escaped)"}"#
        let snapshot = await fetch(json: json)

        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.allSatisfy { $0.isEstimated })
    }

    @Test("garbage output is a decoding failure, not an invented value")
    func undecodable() async {
        let snapshot = await fetch(json: #"{"unexpected":true}"#)
        #expect(snapshot.status == .error("decoding-failed"))
        #expect(snapshot.windows.isEmpty)
    }

    // MARK: Privacy

    @Test("no credential or environment value leaks into any status")
    func noCredentialLeakage() async {
        let secrets = ["ya29.super-secret", "user@example.com", "oc_sk_shouldnotappear"]
        let variables = [
            "PATH": "/usr/bin:/bin",
            "ANTIGRAVITY_CLI_PATH": installedPath,
            "GOOGLE_APPLICATION_CREDENTIALS": "/secrets/ya29.super-secret",
            "OPENCODE_API_KEY": "oc_sk_shouldnotappear",
            "ANTIGRAVITY_ACCOUNT": "user@example.com",
        ]

        let cases: [FakeAntigravityProcessRunner] = [
            FakeAntigravityProcessRunner(stdout: Data(#"{"unexpected":true}"#.utf8)),
            FakeAntigravityProcessRunner(stdout: Data(), exitCode: 1, stderrHint: .authenticationRequired),
            FakeAntigravityProcessRunner(error: .timedOut),
        ]

        for runner in cases {
            let snapshot = await provider(runner: runner, variables: variables).fetch(now: now)
            let rendered = [
                String(describing: snapshot.status),
                snapshot.plan ?? "",
                snapshot.windows.map(\.label).joined(separator: ","),
                snapshot.windows.map(\.id).joined(separator: ","),
            ].joined(separator: "|")

            for secret in secrets {
                #expect(!rendered.contains(secret))
            }
            #expect(snapshot.windows.isEmpty)
        }
    }

    // MARK: Fixtures

    private static let plainTextReport = """
        Antigravity usage
        Gemini Models: 5h 82% left
        Claude and GPT models: Weekly 71% remaining
        Reset credits: 2 available
        """
}
