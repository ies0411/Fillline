import Foundation
import Testing
import UsageCore

/// Scripted provider: replays a fixed list of statuses so scheduler bookkeeping can be
/// tested without HTTP, fixtures, or a spawned CLI (AGENTS §6).
private actor ScriptedStatusProvider: UsageProvider {
    nonisolated let id: ProviderID
    private var statuses: [ProviderStatus]

    init(id: ProviderID = .codex, statuses: [ProviderStatus]) {
        self.id = id
        self.statuses = statuses
    }

    /// Windows only come back on a success, like a real provider answering a failure.
    func fetch(now: Date) async -> UsageSnapshot {
        let status = statuses.isEmpty ? ProviderStatus.error("script-exhausted") : statuses.removeFirst()
        return UsageSnapshot(
            provider: id,
            plan: "plus",
            windows: status.isSuccess ? [Self.window(capturedAt: now)] : [],
            source: .api,
            status: status,
            capturedAt: now
        )
    }

    private static func window(capturedAt: Date) -> LimitWindow {
        LimitWindow(
            id: "codex.primary",
            kind: .session5h,
            label: "Session (5h)",
            usedFraction: 0.4,
            resetsAt: capturedAt.addingTimeInterval(3_600),
            capturedAt: capturedAt
        )
    }
}

/// `UsageSnapshot.consecutiveFailures` reaching the UI (issue #9).
@Suite("Consecutive failures")
struct ConsecutiveFailuresTests {
    private let start = Date(timeIntervalSince1970: 1_792_572_000)

    private func snapshot(
        status: ProviderStatus = .ok,
        failures: Int = 0,
        capturedAt: Date,
        hasWindows: Bool = true
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: .codex,
            plan: "plus",
            windows: hasWindows
                ? [
                    LimitWindow(
                        id: "codex.primary",
                        kind: .session5h,
                        label: "Session (5h)",
                        usedFraction: 0.4,
                        resetsAt: nil,
                        capturedAt: capturedAt
                    )
                ]
                : [],
            source: .api,
            status: status,
            consecutiveFailures: failures,
            capturedAt: capturedAt
        )
    }

    // MARK: - Scheduler

    @Test("a successful poll resets the count to 0")
    func successResetsCount() async {
        let clock = TestClock(start)
        let provider = ScriptedStatusProvider(statuses: [.error("http-500"), .ok])
        let scheduler = PollScheduler(providers: [provider], clock: { clock.now })

        let failedResult = await scheduler.poll(.codex)
        let failed = failedResult
        #expect(failed?.consecutiveFailures == 1)

        clock.advance(60)
        let recoveredResult = await scheduler.poll(.codex)
        let recovered = recoveredResult
        #expect(recovered?.status == .ok)
        #expect(recovered?.consecutiveFailures == 0)

        let state = await scheduler.state(for: .codex)
        #expect(state?.consecutiveFailures == 0)
        #expect(state?.lastSuccessfulSnapshot?.consecutiveFailures == 0)
    }

    @Test("each failed refresh increments the count, and last-good values keep it")
    func failureIncrements() async {
        let clock = TestClock(start)
        let provider = ScriptedStatusProvider(
            statuses: [.ok, .error("http-500"), .error("http-502")]
        )
        let scheduler = PollScheduler(providers: [provider], clock: { clock.now })

        let firstResult = await scheduler.poll(.codex)
        let first = firstResult
        #expect(first?.consecutiveFailures == 0)

        clock.advance(60)
        let secondResult = await scheduler.poll(.codex)
        let second = secondResult
        #expect(second?.status == .error("http-500"))
        #expect(second?.consecutiveFailures == 1)
        // The retained windows are still the last good ones.
        #expect(second?.windows == first?.windows)
        #expect(second?.capturedAt == first?.capturedAt)

        clock.advance(120)
        let thirdResult = await scheduler.poll(.codex)
        let third = thirdResult
        #expect(third?.status == .error("http-502"))
        #expect(third?.consecutiveFailures == 2)
        #expect(third?.windows == first?.windows)

        let state = await scheduler.state(for: .codex)
        #expect(state?.consecutiveFailures == 2)
        #expect(state?.lastSuccessfulSnapshot?.consecutiveFailures == 0)
    }

    @Test("a failure with no last-good values still reports the count")
    func failureWithoutLastGood() async {
        let clock = TestClock(start)
        let provider = ScriptedStatusProvider(statuses: [.needsLogin, .needsLogin])
        let scheduler = PollScheduler(providers: [provider], clock: { clock.now })

        let firstResult = await scheduler.poll(.codex)
        let first = firstResult
        #expect(first?.status == .needsLogin)
        #expect(first?.consecutiveFailures == 1)

        clock.advance(1_800)
        let secondResult = await scheduler.poll(.codex)
        let second = secondResult
        #expect(second?.consecutiveFailures == 2)
    }

    @Test("stale snapshots keep the count, both when aged and when published")
    func staleKeepsCount() async {
        let clock = TestClock(start)
        let provider = ScriptedStatusProvider(statuses: [.ok, .error("http-500")])
        let scheduler = PollScheduler(providers: [provider], clock: { clock.now })

        _ = await scheduler.poll(.codex)
        clock.advance(60)
        _ = await scheduler.poll(.codex)

        // Failure snapshot: `.error`, count survives the last-good swap.
        let published = await scheduler.agedSnapshots()
        #expect(published[.codex]?.consecutiveFailures == 1)

        // Model-level: a `.stale` promotion must not drop or reset the count.
        let aged = snapshot(failures: 3, capturedAt: start.addingTimeInterval(-600))
            .aged(now: start, staleAfter: 180)
        #expect(aged.status == .stale(age: 600))
        #expect(aged.consecutiveFailures == 3)
    }

    // MARK: - Model

    @Test("replacing(status:) keeps the count, and success still means 0")
    func replacingKeepsCount() {
        let base = snapshot(failures: 2, capturedAt: start)

        let stale = base.replacing(status: .stale(age: 600))
        #expect(stale.consecutiveFailures == 2)

        let error = base.replacing(status: .error("http-500"))
        #expect(error.consecutiveFailures == 2)

        let ok = base.replacing(status: .ok)
        #expect(ok.consecutiveFailures == 0)

        let explicit = base.replacing(status: .error("http-500"), consecutiveFailures: 4)
        #expect(explicit.consecutiveFailures == 4)
    }

    @Test("the count round-trips through Codable")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decoded = try decoder.decode(
            UsageSnapshot.self,
            from: try encoder.encode(snapshot(failures: 5, capturedAt: start))
        )
        #expect(decoded.consecutiveFailures == 5)
    }

    @Test("a cache entry written before the field existed decodes as 0 failures")
    func legacyJSONDecodes() throws {
        let legacy = """
            {"provider":"codex","windows":[],"source":"api","status":{"type":"ok"},"capturedAt":792572000}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded = try decoder.decode(UsageSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.consecutiveFailures == 0)
        #expect(decoded.status == .ok)
    }
}
