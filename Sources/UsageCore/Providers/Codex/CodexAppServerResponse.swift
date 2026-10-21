import Foundation

/// Shape of the `account/rateLimits/read` result from `codex app-server`
/// (docs/providers/codex.md §"app-server protocol notes").
///
/// This interface has churned between CLI releases, so decoding is deliberately tolerant:
/// every field is optional, both camelCase and snake_case keys are accepted, `resetsAt` may be
/// epoch seconds or an ISO-8601 string, and unknown keys are ignored. Missing data is reported
/// as "no data" by the provider — never as 0% used (AGENTS §1 success criterion 5).
struct CodexAppServerResponse: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        /// 0–100 USED, like every other provider this app reads.
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case usedPercent
            case usedPercentSnake = "used_percent"
            case windowMinutes
            case windowMinutesSnake = "window_minutes"
            case windowSeconds
            case windowSecondsSnake = "window_seconds"
            case limitWindowSeconds
            case limitWindowSecondsSnake = "limit_window_seconds"
            case resetsAt
            case resetsAtSnake = "resets_at"
            case resetAt
            case resetAtSnake = "reset_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = container.codexDouble([.usedPercent, .usedPercentSnake])

            // The documented field is minutes; accept seconds as a defensive fallback so a
            // serializer change degrades to a wrong label instead of a missing window.
            var minutes = container.codexInt([.windowMinutes, .windowMinutesSnake])
            if minutes == nil {
                minutes = container
                    .codexInt([.windowSeconds, .windowSecondsSnake, .limitWindowSeconds, .limitWindowSecondsSnake])
                    .map { $0 / 60 }
            }
            windowMinutes = minutes
            resetsAt = container.codexDate([.resetsAt, .resetsAtSnake, .resetAt, .resetAtSnake])
        }
    }

    struct Credits: Decodable, Sendable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: String?

        private enum CodingKeys: String, CodingKey {
            case hasCredits
            case hasCreditsSnake = "has_credits"
            case unlimited
            case balance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = container.codexBool([.hasCredits, .hasCreditsSnake])
            unlimited = container.codexBool([.unlimited])
            balance = container.codexString([.balance])
        }
    }

    /// One limit bucket (`codex`, `codex_other`, `codex-spark`, ...).
    struct Bucket: Decodable, Sendable {
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
        let planType: String?
        let limitReached: Bool?

        private enum CodingKeys: String, CodingKey {
            case primary
            case secondary
            case credits
            case planType
            case planTypeSnake = "plan_type"
            case limitReached
            case limitReachedSnake = "limit_reached"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primary = try? container.decodeIfPresent(Window.self, forKey: .primary)
            secondary = try? container.decodeIfPresent(Window.self, forKey: .secondary)
            credits = try? container.decodeIfPresent(Credits.self, forKey: .credits)
            planType = container.codexString([.planType, .planTypeSnake])
            limitReached = container.codexBool([.limitReached, .limitReachedSnake])
        }
    }

    struct ResetCredits: Decodable, Sendable {
        let availableCount: Int?

        private enum CodingKeys: String, CodingKey {
            case availableCount
            case availableCountSnake = "available_count"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = container.codexInt([.availableCount, .availableCountSnake])
        }
    }

    let rateLimitsByLimitID: [String: Bucket]?
    let rateLimits: Bucket?
    let rateLimitResetCredits: ResetCredits?

    private enum CodingKeys: String, CodingKey {
        case rateLimitsByLimitID = "rateLimitsByLimitId"
        case rateLimitsByLimitIDSnake = "rate_limits_by_limit_id"
        case rateLimits
        case rateLimitsSnake = "rate_limits"
        case rateLimitResetCredits
        case rateLimitResetCreditsSnake = "rate_limit_reset_credits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimitsByLimitID =
            (try? container.decodeIfPresent([String: Bucket].self, forKey: .rateLimitsByLimitID))
            ?? (try? container.decodeIfPresent([String: Bucket].self, forKey: .rateLimitsByLimitIDSnake))
        rateLimits =
            (try? container.decodeIfPresent(Bucket.self, forKey: .rateLimits))
            ?? (try? container.decodeIfPresent(Bucket.self, forKey: .rateLimitsSnake))
        rateLimitResetCredits =
            (try? container.decodeIfPresent(ResetCredits.self, forKey: .rateLimitResetCredits))
            ?? (try? container.decodeIfPresent(ResetCredits.self, forKey: .rateLimitResetCreditsSnake))
    }
}

// MARK: - Envelope

extension CodexAppServerResponse {
    /// Extracts the reply to `responseID` from the newline-delimited message stream.
    ///
    /// Non-JSON lines (some CLIs print warnings to stdout) and unrelated messages are ignored.
    /// A JSON-RPC error surfaces only its numeric code; message text is never propagated
    /// (it can echo request state and would end up in logs/UI, AGENTS §4).
    static func decode(lines: [String], responseID: Int) throws -> CodexAppServerResponse {
        for line in lines {
            guard let object = jsonObject(line), Self.integer(object["id"]) == responseID else { continue }

            if let error = object["error"] as? [String: Any] {
                throw CodexAppServerError.rpcError(code: Self.integer(error["code"]) ?? 0)
            }
            guard let result = object["result"], JSONSerialization.isValidJSONObject(result),
                  let data = try? JSONSerialization.data(withJSONObject: result),
                  let decoded = try? JSONDecoder().decode(CodexAppServerResponse.self, from: data)
            else {
                throw CodexAppServerError.malformedResponse
            }
            return decoded
        }
        throw CodexAppServerError.incompleteResponse
    }

    static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let string as String: Int(string)
        default: nil
        }
    }
}

// MARK: - Mapping to windows

extension CodexAppServerResponse {
    /// Plan reported by the default (`codex`) bucket, falling back to any bucket.
    var reportedPlanType: String? {
        rateLimitsByLimitID?["codex"]?.planType
            ?? rateLimits?.planType
            ?? rateLimitsByLimitID?.values.compactMap(\.planType).first
    }

    /// Only positive counts are worth surfacing.
    var resetCreditCount: Int? {
        guard let count = rateLimitResetCredits?.availableCount, count > 0 else { return nil }
        return count
    }

    /// `UsageSnapshot` has no field for reset credits, so they ride along in the plan string
    /// (`"plus · 2 reset credits"`). Keep the wording stable — the UI renders it verbatim.
    var planDescription: String? {
        switch (reportedPlanType, resetCreditCount) {
        case let (plan?, count?): "\(plan) · \(count) reset credits"
        case let (plan?, nil): plan
        case let (nil, count?): "\(count) reset credits"
        case (nil, nil): nil
        }
    }

    /// Maps every bucket onto `LimitWindow`s. Returns an empty array when the server reports
    /// nothing usable, which the provider turns into `empty-usage` rather than 0% remaining.
    func windows(now: Date) -> [LimitWindow] {
        var windows: [LimitWindow] = []

        for (key, bucket) in orderedBuckets() {
            let suffix = Self.labelSuffix(forBucket: key)
            let candidates: [(id: String, window: Window?)] = [
                ("primary", bucket.primary),
                ("secondary", bucket.secondary)
            ]
            for candidate in candidates {
                guard let window = candidate.window, let usedPercent = window.usedPercent else { continue }
                let descriptor = Self.descriptor(forMinutes: window.windowMinutes)
                windows.append(
                    LimitWindow(
                        id: "\(ProviderID.codex.rawValue).app-server.\(key).\(candidate.id)",
                        kind: descriptor.kind,
                        label: descriptor.label + suffix,
                        usedFraction: usedPercent / 100,
                        resetsAt: window.resetsAt,
                        isEstimated: false,
                        isPlaceholder: false,
                        capturedAt: now
                    )
                )
            }
        }

        if let credits = Self.creditsWindow(buckets: orderedBuckets(), now: now) {
            windows.append(credits)
        }
        return windows
    }

    /// `codex` bucket first, remaining buckets alphabetically for deterministic card order.
    private func orderedBuckets() -> [(String, Bucket)] {
        if let map = rateLimitsByLimitID, !map.isEmpty {
            let keys = map.keys.sorted { lhs, rhs in
                if lhs == "codex" { return true }
                if rhs == "codex" { return false }
                return lhs < rhs
            }
            var buckets = keys.compactMap { key in map[key].map { (key, $0) } }
            if !buckets.contains(where: { $0.0 == "codex" }), let rateLimits {
                buckets.insert(("codex", rateLimits), at: 0)
            }
            return buckets
        }
        if let rateLimits { return [("codex", rateLimits)] }
        return []
    }

    /// Non-default buckets are labelled with their suffix, e.g. `codex_other` → " (other)".
    static func labelSuffix(forBucket key: String) -> String {
        if key == "codex" { return "" }
        for prefix in ["codex_", "codex-"] where key.hasPrefix(prefix) {
            return " (\(key.dropFirst(prefix.count)))"
        }
        return " (\(key))"
    }

    static func descriptor(forMinutes minutes: Int?) -> (kind: LimitWindow.Kind, label: String) {
        switch minutes {
        case 300:
            (.session5h, "Session (5h)")
        case 10_080:
            (.weekly7d, "Weekly")
        case let minutes?:
            if minutes <= 0 {
                (.rolling, "Window")
            } else if minutes % 1_440 == 0 {
                (.rolling, "\(minutes / 1_440)d")
            } else if minutes < 60 {
                (.rolling, "\(minutes)m")
            } else {
                (.rolling, "\(minutes / 60)h")
            }
        case nil:
            (.rolling, "Window")
        }
    }

    /// Credits carry no used fraction; the balance is the only meaningful datum, so it goes in
    /// the label. A fraction is never invented (AGENTS §9).
    private static func creditsWindow(buckets: [(String, Bucket)], now: Date) -> LimitWindow? {
        for (_, bucket) in buckets {
            guard let credits = bucket.credits,
                  credits.hasCredits == true,
                  credits.unlimited != true
            else { continue }

            let balance = credits.balance?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = "Credits" + (balance.map { " · \($0)" } ?? "")
            return LimitWindow(
                id: "\(ProviderID.codex.rawValue).app-server.credits",
                kind: .credits,
                label: label,
                usedFraction: 0,
                resetsAt: nil,
                isEstimated: false,
                isPlaceholder: false,
                capturedAt: now
            )
        }
        return nil
    }
}

// MARK: - Tolerant key lookups

extension KeyedDecodingContainer {
    func codexDouble(_ keys: [Key]) -> Double? {
        for key in keys {
            if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
            if let string = try? decodeIfPresent(String.self, forKey: key), let value = Double(string) {
                return value
            }
        }
        return nil
    }

    func codexInt(_ keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
            if let string = try? decodeIfPresent(String.self, forKey: key), let value = Int(string) {
                return value
            }
        }
        return nil
    }

    func codexBool(_ keys: [Key]) -> Bool? {
        for key in keys {
            if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        }
        return nil
    }

    func codexString(_ keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        }
        return nil
    }

    func codexDate(_ keys: [Key]) -> Date? {
        for key in keys {
            if let seconds = try? decodeIfPresent(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: seconds)
            }
            if let string = try? decodeIfPresent(String.self, forKey: key) {
                if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
                if let date = ProviderSupport.iso8601Date(from: string) { return date }
            }
        }
        return nil
    }
}
