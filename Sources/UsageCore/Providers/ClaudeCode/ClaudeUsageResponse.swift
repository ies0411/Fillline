import Foundation

/// Shape of `GET https://api.anthropic.com/api/oauth/usage` (verified 2026-10-21).
///
/// Every bucket is optional; `null` codename keys (`tangelo`, `amber_ladder`, …) are
/// deliberately not modeled. Decoding is field-tolerant so one changed bucket cannot
/// discard the rest of the response.
struct ClaudeUsageResponse: Decodable, Sendable {
    struct Bucket: Decodable, Sendable {
        /// 0–100 USED, not remaining.
        let utilization: Double?
        let resetsAt: Date?
        let lockedReason: String?

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt
            case lockedReason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try? container.decodeIfPresent(Double.self, forKey: .utilization)
            resetsAt = try? container.decodeIfPresent(Date.self, forKey: .resetsAt)
            lockedReason = try? container.decodeIfPresent(String.self, forKey: .lockedReason)
        }
    }

    struct Limit: Decodable, Sendable {
        struct Scope: Decodable, Sendable {
            struct Model: Decodable, Sendable {
                let id: String?
                let displayName: String?
            }

            let model: Model?
        }

        /// Observed: `session`, `weekly_all`, `weekly_scoped`.
        let kind: String?
        let group: String?
        /// 0–100 USED.
        let percent: Double?
        let severity: String?
        let resetsAt: Date?
        let scope: Scope?

        private enum CodingKeys: String, CodingKey {
            case kind
            case group
            case percent
            case severity
            case resetsAt
            case scope
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? container.decodeIfPresent(String.self, forKey: .kind)
            group = try? container.decodeIfPresent(String.self, forKey: .group)
            percent = try? container.decodeIfPresent(Double.self, forKey: .percent)
            severity = try? container.decodeIfPresent(String.self, forKey: .severity)
            resetsAt = try? container.decodeIfPresent(Date.self, forKey: .resetsAt)
            scope = try? container.decodeIfPresent(Scope.self, forKey: .scope)
        }
    }

    let fiveHour: Bucket?
    let sevenDay: Bucket?
    /// Preferred source when present; falls back to `five_hour` / `seven_day`.
    let limits: [Limit]?

    private enum CodingKeys: String, CodingKey {
        case fiveHour
        case sevenDay
        case limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? container.decodeIfPresent(Bucket.self, forKey: .fiveHour)
        sevenDay = try? container.decodeIfPresent(Bucket.self, forKey: .sevenDay)
        limits = try? container.decodeIfPresent([Limit].self, forKey: .limits)
    }
}
