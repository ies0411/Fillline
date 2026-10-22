import Foundation

/// Shape of `GET https://openrouter.ai/api/v1/key`.
///
/// ```json
/// { "data": { "label": "sk-or-…", "limit": 20.0, "usage": 11.5,
///             "limit_remaining": 8.5, "limit_reset": "monthly",
///             "is_free_tier": false,
///             "effective_budget": { "remaining_usd": 8.5 },
///             "budgets": [ { "limit_usd": 20.0, "remaining_usd": 8.5,
///                            "resets_at": "2026-11-01T00:00:00.000Z",
///                            "limit_reset": "monthly" } ] } }
/// ```
///
/// Traps this decoder handles:
/// - **USD, not percent**: `limit_remaining` is `null` when the key has no cap, and it is a
///   *key* limit, not the account balance (that needs a management key);
/// - `effective_budget.remaining_usd` wins when present (issue #13);
/// - `limit`, `usage` and every amount may be a number, a numeric string, or `null`;
/// - `budgets[].resets_at` is ISO-8601 **with milliseconds** and `limit_reset` is
///   `daily|weekly|monthly|null`;
/// - `rate_limit` is deprecated and deliberately not decoded at all.
///
/// Every field is optional, and a malformed budget does not discard the rest.
struct OpenRouterUsageResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let label: String?
        let limit: Double?
        let usage: Double?
        let limitRemaining: Double?
        let limitReset: String?
        let isFreeTier: Bool?
        let effectiveBudget: Budget?
        let budgets: [Budget]?

        private enum CodingKeys: String, CodingKey {
            case label
            case limit
            case usage
            case limitRemaining
            case limitReset
            case isFreeTier
            case effectiveBudget
            case budgets
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                label = nil
                limit = nil
                usage = nil
                limitRemaining = nil
                limitReset = nil
                isFreeTier = nil
                effectiveBudget = nil
                budgets = nil
                return
            }
            label = try? container.decodeIfPresent(String.self, forKey: .label)
            limit = OpenRouterValue.number(in: container, forKey: .limit)
            usage = OpenRouterValue.number(in: container, forKey: .usage)
            limitRemaining = OpenRouterValue.number(in: container, forKey: .limitRemaining)
            limitReset = try? container.decodeIfPresent(String.self, forKey: .limitReset)
            isFreeTier = OpenRouterValue.bool(in: container, forKey: .isFreeTier)
            effectiveBudget = (try? container.decodeIfPresent(Budget.self, forKey: .effectiveBudget))
            budgets = (try? container.decodeIfPresent([Budget].self, forKey: .budgets))
        }
    }

    struct Budget: Decodable, Sendable {
        let limitUsd: Double?
        let remainingUsd: Double?
        let resetsAt: Date?
        let limitReset: String?

        private enum CodingKeys: String, CodingKey {
            case limitUsd
            case remainingUsd
            case resetsAt
            case limitReset
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                limitUsd = nil
                remainingUsd = nil
                resetsAt = nil
                limitReset = nil
                return
            }
            limitUsd = OpenRouterValue.number(in: container, forKey: .limitUsd)
            remainingUsd = OpenRouterValue.number(in: container, forKey: .remainingUsd)
            resetsAt = OpenRouterValue.timestamp(in: container, forKey: .resetsAt)
            limitReset = try? container.decodeIfPresent(String.self, forKey: .limitReset)
        }
    }

    let data: Payload?

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try? container.decodeIfPresent(Payload.self, forKey: .data)
    }
}

// MARK: - Tolerant primitives

/// Number/string/null tolerance for the OpenRouter payload. Provider-local on purpose: parsers
/// are never shared between providers (AGENTS §2).
private enum OpenRouterValue {
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

    /// ISO-8601 with milliseconds (OpenRouter's format), with epoch seconds accepted defensively.
    static func timestamp<K: CodingKey>(
        in container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Date? {
        if let epoch = number(in: container, forKey: key) {
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
