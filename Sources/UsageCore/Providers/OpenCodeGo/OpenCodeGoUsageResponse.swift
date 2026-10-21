import Foundation

/// Shape of `GET https://opencode.ai/zen/go/v1/usage` (captured live 2026-10-21).
///
/// `percent` is 0–100 USED, not a fraction. `resetsAt` is ISO-8601 with milliseconds.
/// When nothing has been used the upstream reports a synthetic `now + window` reset time;
/// the parser keeps the value but marks the window as a placeholder.
struct OpenCodeGoUsageResponse: Decodable, Sendable {
    struct Usage: Decodable, Sendable {
        let rolling: Window?
        let weekly: Window?
        let monthly: Window?

        private enum CodingKeys: String, CodingKey {
            case rolling
            case weekly
            case monthly
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rolling = try? container.decodeIfPresent(Window.self, forKey: .rolling)
            weekly = try? container.decodeIfPresent(Window.self, forKey: .weekly)
            monthly = try? container.decodeIfPresent(Window.self, forKey: .monthly)
        }
    }

    struct Window: Decodable, Sendable {
        let status: String?
        /// 0–100 USED.
        let percent: Double?
        let resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case status
            case percent
            case resetsAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            percent = try? container.decodeIfPresent(Double.self, forKey: .percent)
            resetsAt = try? container.decodeIfPresent(Date.self, forKey: .resetsAt)
        }
    }

    let usage: Usage?

    private enum CodingKeys: String, CodingKey {
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
    }
}
