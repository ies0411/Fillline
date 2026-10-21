import Foundation

/// One quota window for a provider (5-hour session, weekly, monthly, ...).
///
/// `usedFraction` is always normalized to `0...1` regardless of the unit the
/// provider reports (all three observed providers report 0–100 *used* percent).
/// The product is remaining-first, so `remainingFraction` is the primary accessor.
public struct LimitWindow: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case session5h = "session-5h"
        case weekly7d = "weekly-7d"
        /// Model-scoped weekly bucket (Claude `weekly_scoped`, labelled with the model name).
        case weeklyScoped = "weekly-scoped"
        case monthly
        /// Short rolling window that does not map cleanly onto 5h/7d (e.g. OpenCode Go `rolling`,
        /// or a Codex window with an unknown `limit_window_seconds`).
        case rolling
        case credits
    }

    public let id: String
    public let kind: Kind
    public let label: String
    /// Used fraction, clamped to `0...1`.
    public let usedFraction: Double
    public let resetsAt: Date?
    /// `true` when the value was derived rather than reported verbatim (e.g. reset computed from
    /// `reset_after_seconds`). UI must show an "estimated" marker.
    public let isEstimated: Bool
    /// `true` when the upstream reset time is a synthetic placeholder (OpenCode Go reports
    /// `now + window` when nothing has been used yet).
    public let isPlaceholder: Bool
    public let capturedAt: Date

    public init(
        id: String,
        kind: Kind,
        label: String,
        usedFraction: Double,
        resetsAt: Date?,
        isEstimated: Bool = false,
        isPlaceholder: Bool = false,
        capturedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedFraction = usedFraction.clampedToUnitInterval
        self.resetsAt = resetsAt
        self.isEstimated = isEstimated
        self.isPlaceholder = isPlaceholder
        self.capturedAt = capturedAt
    }

    /// Remaining fraction (0...1), clamped so a bogus 120% used value never yields a negative value.
    public var remainingFraction: Double {
        (1 - usedFraction).clampedToUnitInterval
    }

    public var usedPercent: Double { usedFraction * 100 }

    public var remainingPercent: Double { remainingFraction * 100 }
}

// MARK: - Codable

extension LimitWindow {
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case usedFraction
        case resetsAt
        case isEstimated
        case isPlaceholder
        case capturedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        usedFraction = try container.decode(Double.self, forKey: .usedFraction).clampedToUnitInterval
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        isEstimated = try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
        isPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    }
}

// MARK: - Internal helpers

extension Double {
    /// Clamps to `0...1`; `NaN` becomes `0` and infinities saturate.
    var clampedToUnitInterval: Double {
        if isNaN { return 0 }
        return Swift.min(Swift.max(self, 0), 1)
    }
}
