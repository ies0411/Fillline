import Foundation
import Testing
import UsageCore

/// Threshold, gating and dedupe rules for alerts (issue #4).
@Suite("Notification planning")
struct NotificationPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)
    private let planner = NotificationPlanner()

    // MARK: - Factories

    private func window(
        usedFraction: Double,
        kind: LimitWindow.Kind = .session5h,
        resetsIn: TimeInterval? = nil,
        isEstimated: Bool = false,
        isPlaceholder: Bool = false
    ) -> LimitWindow {
        LimitWindow(
            id: "test.\(kind.rawValue)",
            kind: kind,
            label: "Test window",
            usedFraction: usedFraction,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            isEstimated: isEstimated,
            isPlaceholder: isPlaceholder,
            capturedAt: now
        )
    }

    private func snapshot(
        provider: ProviderID = .claudeCode,
        status: ProviderStatus = .ok,
        windows: [LimitWindow]
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            plan: nil,
            windows: windows,
            source: .api,
            status: status,
            capturedAt: now
        )
    }

    private func kinds(_ decisions: [NotificationDecision]) -> [NotificationDecision.Kind] {
        decisions.map(\.kind)
    }

    private func labels(_ decisions: [NotificationDecision]) -> [String] {
        decisions.map { "\($0.provider.rawValue)/\($0.windowKind.rawValue)/\($0.kind.rawValue)" }
    }

    // MARK: - Threshold boundaries

    @Test("exactly 80% fires; 79.9% does not")
    func warningBoundary() {
        let atThreshold = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.80)])],
            now: now
        )
        #expect(kinds(atThreshold) == [.warning80])
        #expect(atThreshold.first?.usedFraction == 0.80)

        let below = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.799)])],
            now: now
        )
        #expect(below.isEmpty)

        let quiet = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.10)])],
            now: now
        )
        #expect(quiet.isEmpty)
    }

    @Test("exactly 95% is critical, and critical replaces warning for the same window")
    func criticalSuppressesWarning() {
        let atCritical = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.95)])],
            now: now
        )
        #expect(kinds(atCritical) == [.critical95])

        let justUnder = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.949)])],
            now: now
        )
        #expect(kinds(justUnder) == [.warning80])

        let exhausted = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 1.0)])],
            now: now
        )
        #expect(kinds(exhausted) == [.critical95])
    }

    @Test("each window is judged on its own")
    func perWindowEvaluation() {
        let snapshot = snapshot(windows: [
            window(usedFraction: 0.96, kind: .session5h),
            window(usedFraction: 0.82, kind: .weekly7d),
            window(usedFraction: 0.20, kind: .monthly)
        ])

        let decisions = planner.decisions(for: [snapshot], now: now)

        #expect(labels(decisions) == [
            "claude-code/session-5h/critical95",
            "claude-code/weekly-7d/warning80"
        ])
    }

    // MARK: - Placeholders and estimates

    @Test("estimated and placeholder windows are skipped")
    func placeholdersSkipped() {
        let estimated = snapshot(windows: [
            window(usedFraction: 0.99, resetsIn: 60, isEstimated: true)
        ])
        #expect(planner.decisions(for: [estimated], now: now).isEmpty)

        let placeholder = snapshot(windows: [
            window(usedFraction: 0.99, resetsIn: 60, isPlaceholder: true)
        ])
        #expect(planner.decisions(for: [placeholder], now: now).isEmpty)

        // A placeholder on one window must not hide a real one on another.
        let mixed = snapshot(windows: [
            window(usedFraction: 0.99, kind: .session5h, isPlaceholder: true),
            window(usedFraction: 0.90, kind: .weekly7d)
        ])
        #expect(labels(planner.decisions(for: [mixed], now: now)) == [
            "claude-code/weekly-7d/warning80"
        ])
    }

    // MARK: - Status gating

    @Test("failure statuses never alert, even with alarming values")
    func failureStatusesSkipped() {
        let statuses: [ProviderStatus] = [
            .needsLogin,
            .notInstalled,
            .notSubscribed,
            .unsupported,
            .rateLimited(retryAfter: 120),
            .error("http-500")
        ]

        for status in statuses {
            let snapshot = snapshot(
                status: status,
                windows: [window(usedFraction: 0.99, resetsIn: 60)]
            )
            #expect(
                planner.decisions(for: [snapshot], now: now).isEmpty,
                "status \(status) produced an alert"
            )
        }
    }

    @Test("stale values still alert, because they are real measurements")
    func staleStillAlerts() {
        let snapshot = snapshot(
            status: .stale(age: 600),
            windows: [window(usedFraction: 0.85)]
        )
        #expect(kinds(planner.decisions(for: [snapshot], now: now)) == [.warning80])
    }

    @Test("a snapshot with no windows yields nothing")
    func emptySnapshot() {
        #expect(planner.decisions(for: [snapshot(windows: [])], now: now).isEmpty)
        #expect(planner.decisions(for: [], now: now).isEmpty)
    }

    // MARK: - Reset soon

    @Test("resetSoon fires only inside the lead time")
    func resetSoonWindow() {
        let inside = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.10, resetsIn: 600)])],
            now: now
        )
        #expect(kinds(inside) == [.resetSoon])

        // The boundary is inclusive.
        let boundary = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.10, resetsIn: 900)])],
            now: now
        )
        #expect(kinds(boundary) == [.resetSoon])

        let outside = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.10, resetsIn: 901)])],
            now: now
        )
        #expect(outside.isEmpty)

        // Already reset: nothing to announce.
        let justPassed = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.10, resetsIn: -1)])],
            now: now
        )
        #expect(justPassed.isEmpty)

        let noResetTime = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 0.10)])],
            now: now
        )
        #expect(noResetTime.isEmpty)
    }

    @Test("resetSoon never fires when nothing is left to spend")
    func resetSoonRequiresRemaining() {
        let decisions = planner.decisions(
            for: [snapshot(windows: [window(usedFraction: 1.0, resetsIn: 300)])],
            now: now
        )
        #expect(kinds(decisions) == [.critical95])
    }

    @Test("resetSoon and a threshold alert can arrive for different windows")
    func resetSoonIsIndependent() {
        let snapshot = snapshot(windows: [
            window(usedFraction: 0.50, kind: .session5h, resetsIn: 60),
            window(usedFraction: 0.85, kind: .weekly7d, resetsIn: 3_600)
        ])

        #expect(labels(planner.decisions(for: [snapshot], now: now)) == [
            "claude-code/session-5h/resetSoon",
            "claude-code/weekly-7d/warning80"
        ])
    }

    // MARK: - Dedupe and re-arming

    @Test("already-notified keys stop a repeat, but only for that window")
    func dedupe() {
        let snapshots = [
            snapshot(windows: [window(usedFraction: 0.90, kind: .session5h)]),
            snapshot(provider: .codex, windows: [window(usedFraction: 0.90, kind: .session5h)])
        ]

        let first = planner.decisions(for: snapshots, now: now)
        #expect(first.count == 2)

        let notified = Set(first.map { planner.key(for: $0, in: snapshots) })
        #expect(planner.decisions(for: snapshots, now: now, alreadyNotified: notified).isEmpty)

        // A key from Claude must not silence Codex.
        let claudeOnly = Set(first.prefix(1).map { planner.key(for: $0, in: snapshots) })
        let remaining = planner.decisions(for: snapshots, now: now, alreadyNotified: claudeOnly)
        #expect(labels(remaining) == ["codex/session-5h/warning80"])
    }

    @Test("79 → 81 alerts once; 81 → 80 → 81 does not re-alert")
    func thresholdCrossing() {
        var notified = Set<NotificationKey>()
        var alerts: [NotificationDecision] = []

        for used in [0.79, 0.81, 0.80, 0.81] {
            let snapshots = [snapshot(windows: [window(usedFraction: used)])]
            let decisions = planner.decisions(for: snapshots, now: now, alreadyNotified: notified)
            alerts.append(contentsOf: decisions)
            for decision in decisions {
                notified.insert(planner.key(for: decision, in: snapshots))
            }
        }

        #expect(kinds(alerts) == [.warning80])
        #expect(alerts.count == 1)
    }

    @Test("a new reset cycle re-arms the same threshold")
    func newCycleRearms() {
        let firstCycle = [snapshot(windows: [window(usedFraction: 0.90, resetsIn: 3_600)])]
        let first = planner.decisions(for: firstCycle, now: now)
        #expect(kinds(first) == [.warning80])

        let firstKey = planner.key(for: first[0], in: firstCycle)
        #expect(planner.decisions(for: firstCycle, now: now, alreadyNotified: [firstKey]).isEmpty)

        // Same window, new cycle: the reset time moved, so the key re-arms.
        let nextCycle = [snapshot(windows: [window(usedFraction: 0.90, resetsIn: 7_200)])]
        let nextKey = planner.key(for: first[0], in: nextCycle)

        #expect(nextKey != firstKey)
        #expect(nextKey.resetEpoch == Int(now.addingTimeInterval(7_200).timeIntervalSince1970))
        #expect(
            labels(planner.decisions(for: nextCycle, now: now, alreadyNotified: [firstKey]))
                == ["claude-code/session-5h/warning80"]
        )
    }

    @Test("a window without a reset time keeps a stable key")
    func keyWithoutResetTime() {
        let snapshots = [snapshot(windows: [window(usedFraction: 0.90)])]
        let decisions = planner.decisions(for: snapshots, now: now)
        let key = planner.key(for: decisions[0], in: snapshots)

        #expect(key.resetEpoch == nil)
        #expect(key.storageString == "claude-code|session-5h|warning80|")
        #expect(planner.decisions(for: snapshots, now: now, alreadyNotified: [key]).isEmpty)
    }

    // MARK: - Determinism

    @Test("decisions are ordered by provider, then window kind")
    func deterministicOrder() {
        let unsorted = [
            snapshot(provider: .openCodeGo, windows: [
                window(usedFraction: 0.90, kind: .monthly),
                window(usedFraction: 0.90, kind: .rolling)
            ]),
            snapshot(provider: .claudeCode, windows: [
                window(usedFraction: 0.90, kind: .weekly7d),
                window(usedFraction: 0.90, kind: .session5h)
            ]),
            snapshot(provider: .codex, windows: [
                window(usedFraction: 0.90, kind: .weekly7d)
            ])
        ]

        #expect(labels(planner.decisions(for: unsorted, now: now)) == [
            "claude-code/session-5h/warning80",
            "claude-code/weekly-7d/warning80",
            "codex/weekly-7d/warning80",
            "opencode-go/monthly/warning80",
            "opencode-go/rolling/warning80"
        ])

        // Reversing the input must not change the output.
        #expect(labels(planner.decisions(for: unsorted.reversed(), now: now))
            == labels(planner.decisions(for: unsorted, now: now)))
    }

    // MARK: - Configuration

    @Test("custom thresholds and lead time are honored")
    func customConfiguration() {
        let quiet = NotificationPlanner(
            warningThreshold: 0.50,
            criticalThreshold: 0.60,
            resetSoonWindow: 60
        )

        let snapshots = [snapshot(windows: [window(usedFraction: 0.55, resetsIn: 30)])]
        #expect(kinds(quiet.decisions(for: snapshots, now: now)) == [.warning80, .resetSoon])

        let critical = [snapshot(windows: [window(usedFraction: 0.60)])]
        #expect(kinds(quiet.decisions(for: critical, now: now)) == [.critical95])

        // 30s is inside the 60s lead time, but 120s is not.
        let late = [snapshot(windows: [window(usedFraction: 0.10, resetsIn: 120)])]
        #expect(quiet.decisions(for: late, now: now).isEmpty)

        #expect(quiet.warningThreshold == 0.50)
        #expect(quiet.criticalThreshold == 0.60)
        #expect(quiet.resetSoonWindow == 60)
    }

    @Test("defaults match the product promise")
    func defaults() {
        #expect(planner.warningThreshold == 0.80)
        #expect(planner.criticalThreshold == 0.95)
        #expect(planner.resetSoonWindow == 900)
    }

    // MARK: - Key persistence form

    @Test("keys round-trip through their storage string")
    func keyStorageString() throws {
        let key = NotificationKey(
            provider: .openCodeGo,
            windowKind: .weekly7d,
            kind: .resetSoon,
            resetEpoch: 1_792_576_800
        )

        #expect(key.storageString == "opencode-go|weekly-7d|resetSoon|1792576800")

        let decoded = try #require(NotificationKey(storageString: key.storageString))
        #expect(decoded == key)

        let withoutReset = NotificationKey(
            provider: .codex,
            windowKind: .session5h,
            kind: .critical95,
            resetsAt: nil
        )
        #expect(withoutReset.storageString == "codex|session-5h|critical95|")
        #expect(NotificationKey(storageString: withoutReset.storageString) == withoutReset)

        #expect(NotificationKey(storageString: "garbage") == nil)
        #expect(NotificationKey(storageString: "nope|session-5h|warning80|1") == nil)
        #expect(NotificationKey(storageString: "codex|session-5h|warning80|not-a-number") == nil)
    }

    @Test("a key ignores the used fraction, so rounding does not re-alert")
    func keyIgnoresFraction() {
        let busy = [snapshot(windows: [window(usedFraction: 0.90)])]
        let busier = [snapshot(windows: [window(usedFraction: 0.93)])]

        let first = planner.decisions(for: busy, now: now)[0]
        let second = planner.decisions(for: busier, now: now)[0]

        #expect(first.usedFraction != second.usedFraction)
        #expect(planner.key(for: first, in: busy) == planner.key(for: second, in: busier))
    }
}
