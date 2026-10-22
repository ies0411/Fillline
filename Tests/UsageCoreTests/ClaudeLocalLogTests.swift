import Foundation
import Testing
import UsageCore

/// Local-log aggregation (issue #16).
///
/// Isolation rule: every test copies `Fixtures/claude_projects` into its own temporary
/// directory (or builds a fresh one) and nothing here ever points at the developer's real
/// `~/.claude` (AGENTS §6).
@Suite("Claude local log aggregation")
struct ClaudeLocalLogTests {
    // MARK: Helpers

    private func date(_ iso: String) throws -> Date {
        try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso)
    }

    private var windowEnd: String { "2026-10-21T12:00:00.000Z" }

    private func fixtureProjects() throws -> URL {
        let bundle = Bundle.module
        if let url = bundle.url(
            forResource: "claude_projects",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) {
            return url
        }
        if let url = bundle.url(forResource: "claude_projects", withExtension: nil) {
            return url
        }
        throw TestFixtures.FixtureError.missing("claude_projects")
    }

    /// Private copy of the committed fixture tree, safe to append to and rewrite.
    private func copyOfFixtures() throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("fillline-claude-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: try fixtureProjects(), to: destination)
        return destination
    }

    private func emptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fillline-claude-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func newSessionFile(in root: URL) throws -> URL {
        let project = root.appendingPathComponent("example-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session-new.jsonl")
        try Data().write(to: file)
        return file
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func assistantLine(
        requestID: String,
        at iso: String,
        input: Int = 0,
        output: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0
    ) -> String {
        """
        {"type":"assistant","timestamp":"\(iso)","requestId":"\(requestID)","message":{"model":"claude-opus-5-5","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func write(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func provider(
        logs: URL,
        http: ScriptedHTTPClient = ScriptedHTTPClient([]),
        credentials: StubCredentialStore = StubCredentialStore(token: "test-token"),
        readEnabled: Bool
    ) -> ClaudeCodeProvider {
        ClaudeCodeProvider(
            httpClient: http,
            credentialStore: credentials,
            credentialReadEnabled: readEnabled,
            localLogs: ClaudeLocalLogAggregator(directory: logs)
        )
    }

    // MARK: Totals

    @Test("5h/7d totals count every request once, including cache tokens")
    func totalsFromFixture() async throws {
        let logs = try copyOfFixtures()
        defer { remove(logs) }

        let totals = await ClaudeLocalLogAggregator(directory: logs).totals(now: try date(windowEnd))

        // Fixture A: 3300 + 1000 + 10 + 100 + 1000 (outside 7d) + one duplicate + junk.
        // Fixture B (another project): 900. Total = 6310 over seven days, 5300 over five hours.
        #expect(totals.fiveHourTokens == 5300)
        #expect(totals.sevenDayTokens == 6310)
        // Six unique assistant turns; `req_a` appears twice and `req_old` is outside the window.
        #expect(totals.requestsConsidered == 6)
        // One crash-truncated line; `user`, `api-request`, `attachment` and `permission-mode`
        // records are ignored rather than counted as malformed.
        #expect(totals.skippedLines == 1)
        #expect(totals.hasUsableData)
        #expect(totals.newestSampleAt == (try date("2026-10-21T11:30:00.000Z")))
    }

    @Test("a record exactly on the 5h boundary counts; one millisecond earlier does not")
    func fiveHourBoundary() async throws {
        let logs = try emptyDirectory()
        defer { remove(logs) }
        let file = try newSessionFile(in: logs)
        let now = try date(windowEnd)

        try write(
            [
                assistantLine(requestID: "req_boundary", at: "2026-10-21T07:00:00.000Z", input: 100),
                assistantLine(requestID: "req_before", at: "2026-10-21T06:59:59.999Z", input: 1000),
            ],
            to: file
        )

        let totals = await ClaudeLocalLogAggregator(directory: logs).totals(now: now)

        #expect(totals.fiveHourTokens == 100)
        #expect(totals.sevenDayTokens == 1100)
        #expect(totals.requestsConsidered == 2)
    }

    @Test("the same requestId is counted once even when it appears in two records")
    func duplicateRequestIDs() async throws {
        let logs = try emptyDirectory()
        defer { remove(logs) }
        let file = try newSessionFile(in: logs)

        try write(
            [
                assistantLine(requestID: "req_dup", at: "2026-10-21T11:00:00.000Z", input: 500),
                assistantLine(requestID: "req_dup", at: "2026-10-21T11:00:00.000Z", input: 500),
            ],
            to: file
        )

        let totals = await ClaudeLocalLogAggregator(directory: logs).totals(now: try date(windowEnd))

        #expect(totals.fiveHourTokens == 500)
        #expect(totals.requestsConsidered == 1)
    }

    @Test("missing usage fields count as zero instead of dropping the record")
    func missingUsageFields() async throws {
        let logs = try emptyDirectory()
        defer { remove(logs) }
        let file = try newSessionFile(in: logs)

        try write(
            [
                """
                {"type":"assistant","timestamp":"2026-10-21T11:00:00.000Z","requestId":"req_sparse","message":{"usage":{"output_tokens":40}}}
                """,
                """
                {"type":"assistant","timestamp":"2026-10-21T11:01:00.000Z","requestId":"req_empty","message":{"usage":{}}}
                """,
            ],
            to: file
        )

        let totals = await ClaudeLocalLogAggregator(directory: logs).totals(now: try date(windowEnd))

        #expect(totals.fiveHourTokens == 40)
        #expect(totals.requestsConsidered == 2)
        #expect(totals.skippedLines == 0)
    }

    // MARK: Incremental reads

    @Test("only appended bytes are parsed on the next poll")
    func incrementalAppend() async throws {
        let logs = try emptyDirectory()
        defer { remove(logs) }
        let file = try newSessionFile(in: logs)
        let aggregator = ClaudeLocalLogAggregator(directory: logs)
        let now = try date(windowEnd)

        try write(
            [assistantLine(requestID: "req_a", at: "2026-10-21T11:00:00.000Z", input: 100)],
            to: file
        )
        let first = await aggregator.totals(now: now)
        #expect(first.fiveHourTokens == 100)
        #expect(first.skippedLines == 0)

        try append(
            [assistantLine(requestID: "req_b", at: "2026-10-21T11:30:00.000Z", input: 200)],
            to: file
        )
        let second = await aggregator.totals(now: now)
        #expect(second.fiveHourTokens == 300)
        #expect(second.sevenDayTokens == 300)

        // No new bytes: nothing is parsed again and no record is double-counted.
        let unchanged = await aggregator.totals(now: now)
        #expect(unchanged.fiveHourTokens == 300)
        #expect(unchanged.skippedLines == 0)

        // A malformed line is only counted once, which proves the earlier lines were not re-read.
        try append(["{\"type\":\"assistant\",\"timestamp\": \"2026-10-21T11:40:00.000Z\""], to: file)
        let afterJunk = await aggregator.totals(now: now)
        #expect(afterJunk.skippedLines == 1)
        #expect(afterJunk.fiveHourTokens == 300)
    }

    @Test("a rewritten or truncated file is re-read from the start")
    func rewrittenFile() async throws {
        let logs = try emptyDirectory()
        defer { remove(logs) }
        let file = try newSessionFile(in: logs)
        let aggregator = ClaudeLocalLogAggregator(directory: logs)
        let now = try date(windowEnd)

        try write(
            [
                assistantLine(requestID: "req_a", at: "2026-10-21T11:00:00.000Z", input: 100),
                assistantLine(requestID: "req_b", at: "2026-10-21T11:10:00.000Z", input: 200),
            ],
            to: file
        )
        let first = await aggregator.totals(now: now)
        #expect(first.fiveHourTokens == 300)

        // Rewritten with less content: the old offsets describe bytes that no longer exist.
        try write(
            [assistantLine(requestID: "req_c", at: "2026-10-21T11:20:00.000Z", input: 7)],
            to: file
        )
        let rewritten = await aggregator.totals(now: now)
        #expect(rewritten.fiveHourTokens == 7)
        #expect(rewritten.requestsConsidered == 1)

        // Emptied: nothing usable, and no stale records survive.
        try Data().write(to: file)
        let emptied = await aggregator.totals(now: now)
        #expect(emptied.hasUsableData == false)
        #expect(emptied.sevenDayTokens == 0)

        // And the offset resumes from the new end after the reset.
        try append(
            [assistantLine(requestID: "req_d", at: "2026-10-21T11:50:00.000Z", input: 11)],
            to: file
        )
        let resumed = await aggregator.totals(now: now)
        #expect(resumed.fiveHourTokens == 11)
    }

    // MARK: Provider integration

    @Test("token read off → two quantity rows, never a percentage")
    func localEstimateSnapshot() async throws {
        let logs = try copyOfFixtures()
        defer { remove(logs) }

        let snapshot = await provider(logs: logs, readEnabled: false).fetch(now: try date(windowEnd))

        #expect(snapshot.status == .ok)
        #expect(snapshot.source == .localLogs)
        #expect(snapshot.plan == nil)
        #expect(snapshot.windows.count == 2)

        let fiveHour = try #require(snapshot.window(kind: .rolling))
        #expect(fiveHour.label == "5.3K tokens · 5h")
        #expect(fiveHour.usedFraction == 0)
        #expect(fiveHour.resetsAt == nil)
        #expect(fiveHour.isEstimated)
        #expect(fiveHour.isPlaceholder == false)

        let weekly = try #require(snapshot.window(kind: .weekly7d))
        #expect(weekly.label == "6.3K tokens · 7d")
        #expect(weekly.usedFraction == 0)
        #expect(weekly.isEstimated)
    }

    @Test("large totals are formatted in millions")
    func millionScaleLabels() async throws {
        let logs = try emptyDirectory()
        defer { remove(logs) }
        let file = try newSessionFile(in: logs)
        try write(
            [assistantLine(requestID: "req_big", at: "2026-10-21T11:00:00.000Z", input: 1_234_567)],
            to: file
        )

        let snapshot = await provider(logs: logs, readEnabled: false).fetch(now: try date(windowEnd))
        let fiveHour = try #require(snapshot.window(kind: .rolling))
        #expect(fiveHour.label == "1.2M tokens · 5h")
    }

    @Test("empty log directory → unsupported, and the credential is never read")
    func emptyDirectoryIsUnsupported() async throws {
        let logs = try emptyDirectory()
        defer { remove(logs) }
        let http = ScriptedHTTPClient([])
        // `nil` credentials would throw `.needsLogin` if this store were ever consulted.
        let snapshot = await provider(
            logs: logs,
            http: http,
            credentials: StubCredentialStore(credential: nil),
            readEnabled: false
        ).fetch(now: try date(windowEnd))

        #expect(snapshot.status == .unsupported)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.source == .localLogs)

        let calls = await http.callCount
        #expect(calls == 0)
    }

    @Test("token read on: a 200 response wins and no estimate is mixed in")
    func apiWinsWhenReadIsEnabled() async throws {
        let logs = try copyOfFixtures()
        defer { remove(logs) }
        let http = ScriptedHTTPClient([
            .init(statusCode: 200, body: try TestFixtures.data("claude_usage"))
        ])

        let snapshot = await provider(logs: logs, http: http, readEnabled: true)
            .fetch(now: try date(windowEnd))

        #expect(snapshot.status == .ok)
        #expect(snapshot.source == .api)
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.window(kind: .rolling) == nil)
    }

    @Test("token read on but rejected → estimate plus the failure status")
    func apiFailureFallsBackToEstimate() async throws {
        let logs = try copyOfFixtures()
        defer { remove(logs) }
        let http = ScriptedHTTPClient([.init(statusCode: 401)])

        let snapshot = await provider(logs: logs, http: http, readEnabled: true)
            .fetch(now: try date(windowEnd))

        #expect(snapshot.status == .needsLogin)
        #expect(snapshot.source == .localLogs)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.window(kind: .rolling)?.label == "5.3K tokens · 5h")
    }

    @Test("missing credential with the read on → estimate plus .needsLogin")
    func missingCredentialFallsBackToEstimate() async throws {
        let logs = try copyOfFixtures()
        defer { remove(logs) }

        let snapshot = await provider(
            logs: logs,
            credentials: StubCredentialStore(credential: nil),
            readEnabled: true
        ).fetch(now: try date(windowEnd))

        #expect(snapshot.status == .needsLogin)
        #expect(snapshot.source == .localLogs)
        #expect(snapshot.windows.count == 2)
    }

    @Test("a failed refresh keeps the last good API value instead of the estimate")
    func schedulerKeepsLastGoodAPIValue() async throws {
        let logs = try copyOfFixtures()
        defer { remove(logs) }
        let http = ScriptedHTTPClient([
            .init(statusCode: 200, body: try TestFixtures.data("claude_usage")),
            .init(statusCode: 429),
        ])
        let clock = TestClock(try date(windowEnd))
        let scheduler = PollScheduler(
            providers: [provider(logs: logs, http: http, readEnabled: true)],
            clock: { clock.now }
        )

        let first = await scheduler.poll(.claudeCode)
        let firstSnapshot = try #require(first)
        #expect(firstSnapshot.source == .api)
        #expect(firstSnapshot.status == .ok)

        // 429: the local estimate exists, but the scheduler must keep the fresher API windows.
        clock.advance(300)
        let second = await scheduler.poll(.claudeCode)
        let secondSnapshot = try #require(second)
        #expect(secondSnapshot.source == .api)
        #expect(secondSnapshot.windows == firstSnapshot.windows)
        #expect(secondSnapshot.status != .ok)
    }
}
