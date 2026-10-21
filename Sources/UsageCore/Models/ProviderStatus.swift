import Foundation

/// Health of a single provider. One provider failing never fails the whole app, so the
/// UI renders this per card (AGENTS §3).
///
/// `error` messages are stable, machine-readable codes (e.g. `"http-500"`), never raw
/// response bodies, tokens, emails, or org ids (AGENTS §4).
public enum ProviderStatus: Sendable, Hashable {
    case ok
    /// Last known good values are still shown but are older than the staleness threshold.
    case stale(age: TimeInterval)
    /// Missing or rejected credentials. No refresh is attempted; the user must run the CLI.
    case needsLogin
    /// Credentials are valid, but the account has no subscription for this provider (HTTP 403).
    case notSubscribed
    /// The CLI or credential file was not found on this machine.
    case notInstalled
    /// HTTP 429. `retryAfter` is the server-provided hint when present.
    case rateLimited(retryAfter: TimeInterval?)
    case unsupported
    /// Stable failure code, safe to log and show.
    case error(String)
}

extension ProviderStatus {
    public var isSuccess: Bool {
        if case .ok = self { return true }
        return false
    }

    public var isFailure: Bool { !isSuccess }

    /// Whether the snapshot still carries trustworthy (if possibly old) values.
    public var hasUsableValues: Bool {
        switch self {
        case .ok, .stale: true
        default: false
        }
    }

    public var retryAfter: TimeInterval? {
        if case .rateLimited(let retryAfter) = self { return retryAfter }
        return nil
    }

    /// Short English label for the card footer. Localized strings belong in the app layer.
    public var displayLabel: String {
        switch self {
        case .ok: "ok"
        case .stale: "stale"
        case .needsLogin: "sign-in required"
        case .notSubscribed: "no subscription"
        case .notInstalled: "not installed"
        case .rateLimited: "rate limited"
        case .unsupported: "unsupported"
        case .error: "error"
        }
    }
}

// MARK: - Codable

/// Explicit encoding keeps the on-disk cache format stable and independent of compiler
/// synthesis details.
extension ProviderStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case age
        case retryAfter
        case message
    }

    private enum Kind: String, Codable {
        case ok
        case stale
        case needsLogin
        case notSubscribed
        case notInstalled
        case rateLimited
        case unsupported
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .ok:
            self = .ok
        case .stale:
            self = .stale(age: try container.decode(TimeInterval.self, forKey: .age))
        case .needsLogin:
            self = .needsLogin
        case .notSubscribed:
            self = .notSubscribed
        case .notInstalled:
            self = .notInstalled
        case .rateLimited:
            self = .rateLimited(
                retryAfter: try container.decodeIfPresent(TimeInterval.self, forKey: .retryAfter))
        case .unsupported:
            self = .unsupported
        case .error:
            self = .error(try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode(Kind.ok, forKey: .type)
        case .stale(let age):
            try container.encode(Kind.stale, forKey: .type)
            try container.encode(age, forKey: .age)
        case .needsLogin:
            try container.encode(Kind.needsLogin, forKey: .type)
        case .notSubscribed:
            try container.encode(Kind.notSubscribed, forKey: .type)
        case .notInstalled:
            try container.encode(Kind.notInstalled, forKey: .type)
        case .rateLimited(let retryAfter):
            try container.encode(Kind.rateLimited, forKey: .type)
            try container.encodeIfPresent(retryAfter, forKey: .retryAfter)
        case .unsupported:
            try container.encode(Kind.unsupported, forKey: .type)
        case .error(let message):
            try container.encode(Kind.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
