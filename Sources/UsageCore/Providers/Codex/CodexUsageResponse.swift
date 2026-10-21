import Foundation

/// Shape of `GET https://chatgpt.com/backend-api/wham/usage` (contract, 2026-10-21).
///
/// Contract-only on this machine: the Codex CLI is not installed, so this file is exercised
/// by fixtures. Every field is optional and unknown keys are ignored.
struct CodexUsageResponse: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        /// 0–100 USED.
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        /// Epoch **seconds** (not milliseconds).
        let resetAt: Double?
        let resetAfterSeconds: Double?

        private enum CodingKeys: String, CodingKey {
            case usedPercent
            case limitWindowSeconds
            case resetAt
            case resetAfterSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = Self.number(container, .usedPercent)
            limitWindowSeconds = Self.number(container, .limitWindowSeconds).map(Int.init)
            resetAt = Self.number(container, .resetAt)
            resetAfterSeconds = Self.number(container, .resetAfterSeconds)
        }

        /// Accepts numbers and numeric strings so a serializer change does not blank the card.
        private static func number(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let string = try? container.decodeIfPresent(String.self, forKey: key) {
                return Double(string)
            }
            return nil
        }
    }

    struct RateLimit: Decodable, Sendable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?

        private enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached
            case primaryWindow
            case secondaryWindow
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            allowed = try? container.decodeIfPresent(Bool.self, forKey: .allowed)
            limitReached = try? container.decodeIfPresent(Bool.self, forKey: .limitReached)
            primaryWindow = try? container.decodeIfPresent(Window.self, forKey: .primaryWindow)
            secondaryWindow = try? container.decodeIfPresent(Window.self, forKey: .secondaryWindow)
        }
    }

    let planType: String?
    let rateLimit: RateLimit?
    let rateLimitReachedType: String?

    private enum CodingKeys: String, CodingKey {
        case planType
        case rateLimit
        case rateLimitReachedType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        rateLimitReachedType = try? container.decodeIfPresent(String.self, forKey: .rateLimitReachedType)
    }
}
