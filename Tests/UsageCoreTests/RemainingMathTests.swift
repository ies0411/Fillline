import Foundation
import Testing
import UsageCore

@Suite("Remaining math")
struct RemainingMathTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)
    private let epoch = Date(timeIntervalSince1970: 0)

    private func window(usedFraction: Double, kind: LimitWindow.Kind = .session5h) -> LimitWindow {
        LimitWindow(
            id: "test-window",
            kind: kind,
            label: "Test",
            usedFraction: usedFraction,
            resetsAt: nil,
            capturedAt: epoch
        )
    }

    @Test("used fraction is clamped and remaining never goes negative")
    func clamping() {
        let over = window(usedFraction: 1.2)
        #expect(over.usedFraction == 1)
        #expect(over.remainingFraction == 0)
        #expect(over.remainingPercent == 0)

        let negative = window(usedFraction: -0.5)
        #expect(negative.usedFraction == 0)
        #expect(negative.remainingFraction == 1)
        #expect(negative.remainingPercent == 100)

        let nan = window(usedFraction: .nan)
        #expect(nan.usedFraction == 0)
        #expect(nan.remainingFraction == 1)

        let normal = window(usedFraction: 0.25)
        #expect(normal.usedFraction == 0.25)
        #expect(normal.remainingFraction == 0.75)
        #expect(normal.usedPercent == 25)
        #expect(normal.remainingPercent == 75)
    }

    @Test("primary window prefers session, then weekly, then the rest")
    func primaryWindow() {
        let weekly = window(usedFraction: 0.5, kind: .weekly7d)
        let session = window(usedFraction: 0.25, kind: .session5h)
        let snapshot = UsageSnapshot(
            provider: .claudeCode,
            plan: nil,
            windows: [weekly, session],
            source: .api,
            status: .ok,
            capturedAt: now
        )

        #expect(snapshot.primaryWindow?.kind == .session5h)
        #expect(snapshot.lowestRemainingFraction == 0.5)
        #expect(snapshot.hasValues)
    }

    @Test("aged promotes ok to stale after the threshold")
    func aged() {
        let snapshot = UsageSnapshot(
            provider: .codex,
            plan: "plus",
            windows: [window(usedFraction: 0.4)],
            source: .api,
            status: .ok,
            capturedAt: now
        )

        let fresh = snapshot.aged(now: now.addingTimeInterval(10), staleAfter: 180)
        #expect(fresh.status == .ok)

        let stale = snapshot.aged(now: now.addingTimeInterval(240), staleAfter: 180)
        guard case .stale(let age) = stale.status else {
            Issue.record("expected .stale, got \(stale.status)")
            return
        }
        #expect(abs(age - 240) < 0.001)
        #expect(stale.windows == snapshot.windows)
    }

    @Test("empty failure snapshots never gain fake windows")
    func emptyFailure() {
        let snapshot = UsageSnapshot(
            provider: .openCodeGo,
            plan: nil,
            windows: [],
            source: .api,
            status: .error("network-error"),
            capturedAt: now
        )

        #expect(snapshot.primaryWindow == nil)
        #expect(snapshot.lowestRemainingFraction == nil)
        #expect(snapshot.aged(now: now.addingTimeInterval(10_000)).status == .error("network-error"))
    }
}

@Suite("Credential redaction")
struct CredentialRedactionTests {
    @Test("description and debugDescription never contain the secret")
    func redaction() {
        let token = "fake-token-for-redaction-test"
        let credential = Credential(token)

        #expect(credential.description == "<redacted>")
        #expect(credential.debugDescription == "<redacted>")
        #expect(!credential.description.contains(token))
        #expect(!credential.debugDescription.contains(token))
        #expect(!"\(credential)".contains(token))
        #expect(!String(reflecting: credential).contains(token))
        #expect(!String(describing: [credential]).contains(token))
    }

    @Test("reveal() is the only way to obtain the raw value")
    func reveal() {
        let credential = Credential("secret-value")
        #expect(credential.reveal() == "secret-value")
        #expect(credential.isEmpty == false)
        #expect(Credential("").isEmpty)
    }
}

@Suite("Retry policy")
struct RetryPolicyTests {
    @Test("exponential backoff schedule: 60s → 2m → 5m → 15m → 30m")
    func backoffSchedule() {
        let policy = RetryPolicy()
        #expect(policy.delay(failureCount: 1) == 60)
        #expect(policy.delay(failureCount: 2) == 120)
        #expect(policy.delay(failureCount: 3) == 300)
        #expect(policy.delay(failureCount: 4) == 900)
        #expect(policy.delay(failureCount: 5) == 1_800)
        #expect(policy.delay(failureCount: 99) == 1_800)
    }

    @Test("Retry-After is honored when longer than the backoff")
    func retryAfter() {
        let policy = RetryPolicy()
        #expect(policy.delay(failureCount: 1, retryAfter: 200) == 200)
        #expect(policy.delay(failureCount: 1, retryAfter: 5) == 60)
        #expect(policy.delay(failureCount: 2, retryAfter: 3_600) == 3_600)
    }

    @Test("success interval respects the 60s floor")
    func successInterval() {
        let policy = RetryPolicy()
        #expect(policy.successInterval() == 60)
        #expect(policy.successInterval(minimum: 180) == 180)
        #expect(policy.successInterval(minimum: 1) == 60)
    }
}

@Suite("Snapshot cache")
struct SnapshotCacheTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-core-cache-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("save/load round-trip is atomic and leaves no temp files")
    func roundTrip() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let window = LimitWindow(
            id: "claude.session5h",
            kind: .session5h,
            label: "5-hour",
            usedFraction: 0.42,
            resetsAt: now.addingTimeInterval(3_600),
            capturedAt: now
        )
        let snapshot = UsageSnapshot(
            provider: .claudeCode,
            plan: "max",
            windows: [window],
            source: .api,
            status: .rateLimited(retryAfter: 120),
            capturedAt: now
        )

        try await SnapshotCache(directory: directory).save(snapshot)

        let loaded = await SnapshotCache(directory: directory).load()
        let reloaded = try #require(loaded[.claudeCode])
        #expect(reloaded == snapshot)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == ["snapshots.json"])
    }

    @Test("all status variants round-trip")
    func statusRoundTrip() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = SnapshotCache(directory: directory)
        let statuses: [ProviderStatus] = [
            .ok,
            .stale(age: 42),
            .needsLogin,
            .notSubscribed,
            .notInstalled,
            .rateLimited(retryAfter: nil),
            .rateLimited(retryAfter: 90),
            .unsupported,
            .error("http-500")
        ]

        for status in statuses {
            let snapshot = UsageSnapshot(
                provider: .codex,
                plan: "plus",
                windows: [],
                source: .api,
                status: status,
                capturedAt: now
            )
            try await cache.save(snapshot)
            let stored = await cache.snapshot(for: .codex)
            #expect(stored == snapshot)
        }
    }

    @Test("a corrupt cache file is ignored instead of crashing")
    func corruptCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("snapshots.json"))

        let loaded = await SnapshotCache(directory: directory).load()
        #expect(loaded.isEmpty)
    }
}
