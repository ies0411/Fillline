import Foundation

/// A single provider. `fetch` never throws: every failure is mapped onto a per-card
/// `ProviderStatus`, so one broken endpoint cannot take down the other cards.
public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch(now: Date) async -> UsageSnapshot
}

/// Shared provider plumbing (date parsing, tolerant decoding, status mapping).
///
/// Endpoint URLs, headers and response keys stay in each provider's `Endpoints.swift` /
/// response file (AGENTS §2).
enum ProviderSupport {
    /// Errors are internal: providers translate everything into `ProviderStatus` codes.
    enum Failure {
        static let network = "network-error"
        static let invalidResponse = "invalid-response"
        static let decoding = "decoding-failed"
        static let emptyUsage = "empty-usage"
    }

    /// JSON decoder tuned for provider payloads:
    /// - snake_case keys (unknown keys are ignored by `Decodable`);
    /// - ISO-8601 dates, including the 6-digit fractional seconds Claude returns.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = iso8601Date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported ISO-8601 date format"
                )
            }
            return date
        }
        return decoder
    }

    /// Parses `2026-10-21T08:39:59.776536+00:00`, `...:23.000Z`, and plain `...:00Z`.
    ///
    /// `ISO8601DateFormatter` with `.withFractionalSeconds` truncates to milliseconds; the
    /// format style keeps the full precision and also accepts a missing fraction.
    static func iso8601Date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(trimmed)
    }

    static func failureSnapshot(
        provider: ProviderID,
        status: ProviderStatus,
        plan: String? = nil,
        now: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            plan: plan,
            windows: [],
            source: .api,
            status: status,
            capturedAt: now
        )
    }

    /// Common HTTP status mapping. Providers must handle 403 themselves when it has a
    /// provider-specific meaning (OpenCode Go: valid key without a subscription).
    static func status(
        forHTTPStatusCode code: Int,
        response: HTTPURLResponse,
        now: Date
    ) -> ProviderStatus {
        switch code {
        case 200...299:
            return .ok
        case 401:
            return .needsLogin
        case 429:
            return .rateLimited(retryAfter: response.retryAfterSeconds(now: now))
        default:
            return .error("http-\(code)")
        }
    }
}
