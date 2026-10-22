import Foundation

/// Shape of `GET https://api.github.com/copilot_internal/user` (undocumented Copilot endpoint).
///
/// The payload is a *snapshot of quota buckets*, not a list of windows:
///
/// ```json
/// { "copilot_plan": "individual",
///   "quota_reset_date": "2026-11-01",
///   "quota_snapshots": {
///     "premium_interactions": { "entitlement": 300, "remaining": 180,
///                               "percent_remaining": 60, "unlimited": false,
///                               "quota_reset_at": 1793520000 },
///     "chat": { "entitlement": "500", "percent_remaining": "75" } } }
/// ```
///
/// Traps this decoder handles (all observed kinds of drift):
/// - `entitlement` / `percent_remaining` arrive as **number or string**;
/// - `quota_reset_at` arrives as **epoch seconds** in newer payloads and is absent in older
///   ones (then `quota_reset_date`, a `yyyy-MM-dd` date, is the only hint);
/// - `unlimited: true` buckets have no meaningful percentage at all;
/// - buckets come and go, and unknown buckets must be ignored rather than failing the parse.
///
/// Every field is optional; nothing here throws for a missing key.
struct GitHubCopilotUsageResponse: Decodable, Sendable {
    let copilotPlan: String?
    let accessTypeSku: String?
    /// `yyyy-MM-dd`; the coarse monthly reset used when a bucket has no `quota_reset_at`.
    let quotaResetDate: String?
    /// Same reset as an ISO-8601 timestamp with milliseconds (live payloads carry both).
    let quotaResetDateUtc: Date?
    let quotaSnapshots: [String: Snapshot]?

    /// One quota bucket. `percentRemaining` is 0–100 **remaining**, not used.
    struct Snapshot: Decodable, Sendable {
        let entitlement: Double?
        let percentRemaining: Double?
        let remaining: Double?
        let unlimited: Bool?
        let quotaResetAt: Date?
        let quotaID: String?

        private enum CodingKeys: String, CodingKey {
            case entitlement
            case percentRemaining
            case remaining
            case unlimited
            case quotaResetAt
            case quotaID = "quotaId"
        }

        /// Never throws: one malformed bucket must not discard the buckets around it. A value
        /// that is not an object at all simply decodes to "no data".
        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                entitlement = nil
                percentRemaining = nil
                remaining = nil
                unlimited = nil
                quotaResetAt = nil
                quotaID = nil
                return
            }
            entitlement = CopilotValue.number(in: container, forKey: .entitlement)
            percentRemaining = CopilotValue.number(in: container, forKey: .percentRemaining)
            remaining = CopilotValue.number(in: container, forKey: .remaining)
            unlimited = CopilotValue.bool(in: container, forKey: .unlimited)
            quotaResetAt = CopilotValue.timestamp(in: container, forKey: .quotaResetAt)
            quotaID = try? container.decodeIfPresent(String.self, forKey: .quotaID)
        }

        /// Remaining fraction (0...1) built from whichever field the payload carried.
        ///
        /// `nil` means "the payload does not express a fraction" (unlimited, missing numbers),
        /// which the provider must render as "nothing to chart", never as 0%.
        var remainingFraction: Double? {
            if let percentRemaining {
                return min(max(percentRemaining / 100, 0), 1)
            }
            guard let remaining, let entitlement, entitlement > 0 else { return nil }
            return min(max(remaining / entitlement, 0), 1)
        }

        /// `true` when the fraction had to be derived from `remaining / entitlement`.
        var fractionIsDerived: Bool {
            percentRemaining == nil && remainingFraction != nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case copilotPlan
        case accessTypeSku
        case quotaResetDate
        case quotaResetDateUtc
        case quotaSnapshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        copilotPlan = try? container.decodeIfPresent(String.self, forKey: .copilotPlan)
        accessTypeSku = try? container.decodeIfPresent(String.self, forKey: .accessTypeSku)
        quotaResetDate = try? container.decodeIfPresent(String.self, forKey: .quotaResetDate)
        quotaResetDateUtc = Self.isoDate(
            try? container.decodeIfPresent(String.self, forKey: .quotaResetDateUtc)
        )
        // A single malformed bucket must not discard the rest of the payload, so the
        // dictionary is decoded leniently per value.
        quotaSnapshots = (try? container.decodeIfPresent([String: Snapshot].self, forKey: .quotaSnapshots))
    }

    /// Coarse monthly reset: the precise UTC timestamp when present, else `"2026-11-01"`
    /// parsed as 00:00 UTC that day.
    var coarseResetsAt: Date? {
        if let quotaResetDateUtc { return quotaResetDateUtc }
        guard let quotaResetDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = quotaResetDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func isoDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return ProviderSupport.iso8601Date(from: raw)
    }
}

// MARK: - Tolerant primitives

/// Decoding helpers for the Copilot payload: values that may be a number, a string, absent, or
/// `null`. Kept private to this provider on purpose — parsers are not shared between providers
/// (AGENTS §2).
private enum CopilotValue {
    static func number<K: CodingKey>(
        in container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func bool<K: CodingKey>(
        in container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    /// Epoch **seconds** (GitHub's unit), epoch milliseconds defensively, or an ISO-8601 string.
    static func timestamp<K: CodingKey>(
        in container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Date? {
        if let epoch = number(in: container, forKey: key) {
            // Anything past ~year 5138 is milliseconds, not seconds.
            let seconds = epoch > 100_000_000_000 ? epoch / 1_000 : epoch
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return ProviderSupport.iso8601Date(from: raw)
    }
}
