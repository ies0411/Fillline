import Foundation

/// Injected HTTP boundary. Every provider takes one of these so parsing and status
/// transitions are testable without touching the network (AGENTS §6).
public protocol HTTPClient: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Transport-level failures. Cases carry no response bodies and no credentials.
public enum HTTPClientError: Error, Sendable, Hashable {
    case notHTTP
    /// Request host is outside the compiled allowlist (AGENTS §4).
    case hostNotAllowed
    /// URLSession failed (offline, timeout, TLS, ...).
    case transport
}

extension HTTPURLResponse {
    /// Parses `Retry-After` (delta-seconds or an HTTP-date, per RFC 9110).
    ///
    /// `now` is a parameter so callers can use their injected clock in tests.
    public func retryAfterSeconds(now: Date = Date()) -> TimeInterval? {
        guard let raw = value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }

        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }

        // HTTP-date form: "Wed, 21 Oct 2026 07:28:00 GMT"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSince(now))
        }

        return nil
    }
}
