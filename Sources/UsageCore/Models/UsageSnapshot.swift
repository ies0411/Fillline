import Foundation

/// Point-in-time view of one provider's quota state.
///
/// A snapshot with a non-`ok` status may still carry windows: the scheduler keeps the
/// last successful values and only swaps the status, so the UI can display
/// "stale · 4 min ago" instead of inventing a 0% (AGENTS §1 success criterion 5).
public struct UsageSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: ProviderID { provider }

    public let provider: ProviderID
    public let plan: String?
    /// Provider-granted limit resets still available (Codex `rateLimitResetCredits`).
    /// `nil` means "not reported", never zero (AGENTS §10 #9).
    public let resetCredits: Int?
    public let windows: [LimitWindow]
    public let source: Source
    public let status: ProviderStatus
    /// Refresh attempts that failed in a row before this snapshot was published. `0` means
    /// the last attempt succeeded, so retained values are not being carried by failures.
    /// Purely a trust signal for the UI: it never changes a percentage (issue #9).
    public let consecutiveFailures: Int
    public let capturedAt: Date

    public init(
        provider: ProviderID,
        plan: String?,
        resetCredits: Int? = nil,
        windows: [LimitWindow],
        source: Source,
        status: ProviderStatus,
        consecutiveFailures: Int = 0,
        capturedAt: Date
    ) {
        self.provider = provider
        self.plan = plan
        self.resetCredits = resetCredits
        self.windows = windows
        self.source = source
        self.status = status
        self.consecutiveFailures = max(0, consecutiveFailures)
        self.capturedAt = capturedAt
    }

    public func window(kind: LimitWindow.Kind) -> LimitWindow? {
        windows.first { $0.kind == kind }
    }

    /// Window the menu bar should show by default: session first, then weekly, then anything.
    public var primaryWindow: LimitWindow? {
        let preference: [LimitWindow.Kind] = [
            .session5h, .weekly7d, .weeklyScoped, .monthly, .rolling, .credits,
        ]
        for kind in preference {
            if let window = window(kind: kind) { return window }
        }
        return windows.first
    }

    /// Tightest remaining fraction across windows — used when the menu bar only has room
    /// for one number per provider.
    public var lowestRemainingFraction: Double? {
        windows.map(\.remainingFraction).min()
    }

    public var hasValues: Bool { !windows.isEmpty }

    /// Same values with a new status, preserving `capturedAt` so the age stays honest.
    ///
    /// `consecutiveFailures` carries over unchanged so a stale snapshot keeps counting the
    /// failures behind it; a success always reports `0` (issue #9). Pass `failures`
    /// explicitly when the caller has just incremented the count.
    public func replacing(
        status newStatus: ProviderStatus,
        consecutiveFailures failures: Int? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            plan: plan,
            resetCredits: resetCredits,
            windows: windows,
            source: source,
            status: newStatus,
            consecutiveFailures: failures ?? (newStatus.isSuccess ? 0 : consecutiveFailures),
            capturedAt: capturedAt
        )
    }

    /// Promotes an `ok` snapshot to `.stale(age:)` once it is older than `staleAfter`.
    public func aged(now: Date, staleAfter: TimeInterval = 180) -> UsageSnapshot {
        guard hasValues else { return self }
        let age = max(0, now.timeIntervalSince(capturedAt))
        switch status {
        case .ok where age >= staleAfter:
            return replacing(status: .stale(age: age))
        case .stale:
            return replacing(status: .stale(age: age))
        default:
            return self
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case provider
        case plan
        case resetCredits
        case windows
        case source
        case status
        case consecutiveFailures
        case capturedAt
    }

    /// Explicit decoding so a cache written before `consecutiveFailures` existed still loads,
    /// reading the field as `0` instead of failing the whole entry.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(ProviderID.self, forKey: .provider)
        self.plan = try container.decodeIfPresent(String.self, forKey: .plan)
        self.resetCredits = try container.decodeIfPresent(Int.self, forKey: .resetCredits)
        self.windows = try container.decode([LimitWindow].self, forKey: .windows)
        self.source = try container.decode(Source.self, forKey: .source)
        self.status = try container.decode(ProviderStatus.self, forKey: .status)
        self.consecutiveFailures = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        )
        self.capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    }
}
