import Foundation
import UsageCore

/// Deterministic, I/O-free snapshots for the documentation renders (issue #6).
///
/// The screenshot pipeline draws the *shipping* popover, so this file contributes values only:
/// every pixel still comes from `PopoverView` and its children. Timestamps are offsets from a
/// single `Date()` per panel, so countdowns read forward ("resets in 2h 12m") and two runs are
/// comparable instead of pointing at a hard-coded past date.
enum ScreenshotFixtures {
    struct Panel {
        let snapshots: [ProviderID: UsageSnapshot]
        let sparklines: [ProviderID: SparklineData]
        let lastAttemptAt: [ProviderID: Date]
    }

    // MARK: - States

    /// Everything reachable, nothing failing: the state the marketing page should show.
    static func healthy() -> Panel {
        let now = Date()
        let capturedAt = now.addingTimeInterval(-40)

        let claude = snapshot(
            .claudeCode,
            plan: "Max",
            windows: [
                window(
                    .claudeCode, kind: .session5h, label: "5-hour", used: 0.38,
                    resetsIn: hours(2) + minutes(12), now: now, capturedAt: capturedAt
                ),
                window(
                    .claudeCode, kind: .weekly7d, label: "Weekly", used: 0.64,
                    resetsIn: days(3) + hours(4), now: now, capturedAt: capturedAt
                ),
            ],
            source: .api,
            status: .ok,
            capturedAt: capturedAt
        )

        // `.appServer` is the documented Codex path, so the card shows its `APP SERVER` badge;
        // the reset credits exercise the `2 resets` meta.
        let codex = snapshot(
            .codex,
            plan: "Plus",
            resetCredits: 2,
            windows: [
                window(
                    .codex, kind: .session5h, label: "Session (5h)", used: 0.55,
                    resetsIn: hours(1) + minutes(5), now: now, capturedAt: capturedAt
                ),
                window(
                    .codex, kind: .weekly7d, label: "Weekly", used: 0.31,
                    resetsIn: days(4) + hours(2), now: now, capturedAt: capturedAt
                ),
            ],
            source: .appServer,
            status: .ok,
            capturedAt: capturedAt
        )

        let go = snapshot(
            .openCodeGo,
            plan: "Go",
            windows: [
                window(
                    .openCodeGo, kind: .rolling, label: "Rolling", used: 0.08,
                    resetsIn: hours(3) + minutes(30), now: now, capturedAt: capturedAt
                ),
                window(
                    .openCodeGo, kind: .weekly7d, label: "Weekly", used: 0.59,
                    resetsIn: days(5), now: now, capturedAt: capturedAt
                ),
                window(
                    .openCodeGo, kind: .monthly, label: "Monthly", used: 0.74,
                    resetsIn: days(21), now: now, capturedAt: capturedAt
                ),
            ],
            source: .api,
            status: .ok,
            capturedAt: capturedAt
        )

        let antigravity = snapshot(
            .antigravity,
            plan: "AI Pro",
            windows: [
                window(
                    .antigravity, kind: .session5h, label: "Gemini · 5h", used: 0.22,
                    resetsIn: hours(4) + minutes(20), now: now, capturedAt: capturedAt
                ),
                window(
                    .antigravity, kind: .weekly7d, label: "Gemini · Weekly", used: 0.35,
                    resetsIn: days(6) + hours(3), now: now, capturedAt: capturedAt
                ),
            ],
            source: .api,
            status: .ok,
            capturedAt: capturedAt
        )

        return Panel(
            snapshots: [
                .claudeCode: claude,
                .codex: codex,
                .openCodeGo: go,
                .antigravity: antigravity,
            ],
            sparklines: [
                .claudeCode: trail(
                    .claudeCode, windowLabel: "Weekly", kind: .weekly7d, endingUsed: 0.64,
                    now: now, drop: 0.24
                ),
                .codex: trail(
                    .codex, windowLabel: "Weekly", kind: .weekly7d, endingUsed: 0.31,
                    now: now, drop: 0.19
                ),
                .openCodeGo: trail(
                    .openCodeGo, windowLabel: "Weekly", kind: .weekly7d, endingUsed: 0.59,
                    now: now, drop: 0.23
                ),
                .antigravity: trail(
                    .antigravity, windowLabel: "Gemini · Weekly", kind: .weekly7d,
                    endingUsed: 0.35, now: now, drop: 0.15
                ),
            ],
            lastAttemptAt: [
                .claudeCode: capturedAt,
                .codex: capturedAt,
                .openCodeGo: capturedAt,
                .antigravity: capturedAt,
            ]
        )
    }

    /// The honesty shot: stale with a failure count, a missing login, one healthy provider, and
    /// a CLI that is not installed here. Every card tells a different truth, and none of them
    /// invents a zero.
    static func degraded() -> Panel {
        let now = Date()
        let staleCapturedAt = now.addingTimeInterval(-240)
        let freshCapturedAt = now.addingTimeInterval(-25)

        let claude = snapshot(
            .claudeCode,
            plan: "Max",
            windows: [
                window(
                    .claudeCode, kind: .session5h, label: "5-hour", used: 0.41,
                    resetsIn: hours(1) + minutes(38), now: now, capturedAt: staleCapturedAt
                ),
                window(
                    .claudeCode, kind: .weekly7d, label: "Weekly", used: 0.66,
                    resetsIn: days(3), now: now, capturedAt: staleCapturedAt
                ),
            ],
            source: .api,
            status: .stale(age: 240),
            consecutiveFailures: 3,
            capturedAt: staleCapturedAt
        )

        // No windows on purpose: a missing login has no values to retain, so the card must use
        // its sign-in body rather than a meter.
        let codex = snapshot(
            .codex,
            plan: "Plus",
            windows: [],
            source: .appServer,
            status: .needsLogin,
            capturedAt: freshCapturedAt
        )

        let go = snapshot(
            .openCodeGo,
            plan: "Go",
            windows: [
                window(
                    .openCodeGo, kind: .rolling, label: "Rolling", used: 0.05,
                    resetsIn: hours(4) + minutes(12), now: now, capturedAt: freshCapturedAt
                ),
                window(
                    .openCodeGo, kind: .weekly7d, label: "Weekly", used: 0.59,
                    resetsIn: days(5) + hours(1), now: now, capturedAt: freshCapturedAt
                ),
                window(
                    .openCodeGo, kind: .monthly, label: "Monthly", used: 0.74,
                    resetsIn: days(21), now: now, capturedAt: freshCapturedAt
                ),
            ],
            source: .api,
            status: .ok,
            capturedAt: freshCapturedAt
        )

        let antigravity = snapshot(
            .antigravity,
            plan: nil,
            windows: [],
            source: .api,
            status: .notInstalled,
            capturedAt: freshCapturedAt
        )

        return Panel(
            snapshots: [
                .claudeCode: claude,
                .codex: codex,
                .openCodeGo: go,
                .antigravity: antigravity,
            ],
            sparklines: [
                .claudeCode: trail(
                    .claudeCode, windowLabel: "Weekly", kind: .weekly7d, endingUsed: 0.66,
                    now: now, drop: 0.21
                ),
                .openCodeGo: trail(
                    .openCodeGo, windowLabel: "Weekly", kind: .weekly7d, endingUsed: 0.59,
                    now: now, drop: 0.23
                ),
            ],
            lastAttemptAt: [
                .claudeCode: staleCapturedAt,
                .codex: freshCapturedAt,
                .openCodeGo: freshCapturedAt,
                .antigravity: freshCapturedAt,
            ]
        )
    }

    // MARK: - Builders

    private static func snapshot(
        _ provider: ProviderID,
        plan: String?,
        resetCredits: Int? = nil,
        windows: [LimitWindow],
        source: Source,
        status: ProviderStatus,
        consecutiveFailures: Int = 0,
        capturedAt: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            plan: plan,
            resetCredits: resetCredits,
            windows: windows,
            source: source,
            status: status,
            consecutiveFailures: consecutiveFailures,
            capturedAt: capturedAt
        )
    }

    private static func window(
        _ provider: ProviderID,
        kind: LimitWindow.Kind,
        label: String,
        used: Double,
        resetsIn: TimeInterval,
        now: Date,
        capturedAt: Date
    ) -> LimitWindow {
        LimitWindow(
            id: "\(provider.rawValue).\(kind.rawValue)",
            kind: kind,
            label: label,
            usedFraction: used,
            resetsAt: now.addingTimeInterval(resetsIn),
            isEstimated: false,
            isPlaceholder: false,
            capturedAt: capturedAt
        )
    }

    /// A nine-point series over the last 6.4 days whose *remaining* fraction falls, so the
    /// sparkline band is visibly populated and points the way a spent quota should.
    private static func trail(
        _ provider: ProviderID,
        windowLabel: String,
        kind: LimitWindow.Kind,
        endingUsed: Double,
        now: Date,
        drop: Double,
        count: Int = 9
    ) -> SparklineData {
        let covered = 6.4 * 24 * 3600
        let step = covered / Double(count - 1)
        let samples = (0..<count).map { index -> HistorySample in
            let progress = Double(index) / Double(count - 1)
            return HistorySample(
                capturedAt: now.addingTimeInterval(-covered + step * Double(index) - 40),
                usedFraction: endingUsed - drop + drop * progress,
                windowKind: kind,
                provider: provider
            )
        }
        return SparklineData(windowLabel: windowLabel, samples: samples)
    }

    private static func minutes(_ value: Double) -> TimeInterval { value * 60 }
    private static func hours(_ value: Double) -> TimeInterval { value * 3600 }
    private static func days(_ value: Double) -> TimeInterval { value * 24 * 3600 }
}

// MARK: - Delivering

/// Notifications are switched off in a documentation render, so the model is given a sink that
/// never touches `UNUserNotificationCenter` (which would register the bundle with the system).
struct SilentNotificationDelivering: NotificationDelivering {
    func requestAuthorization() async -> Bool { false }
    func deliver(_ payload: NotificationPayload) async {}
}
