import Foundation

/// Backoff schedule for provider polling: 60s → 2m → 5m → 15m → 30m, honoring `Retry-After`.
///
/// `Retry-After` is deliberately *not* capped by `maximumInterval`: if the server asks us to
/// wait longer than 30 minutes, waiting less would just produce another 429.
public struct RetryPolicy: Sendable, Hashable {
    public static let minimumInterval: TimeInterval = 60
    public static let maximumInterval: TimeInterval = 1_800
    public static let defaultBackoffSchedule: [TimeInterval] = [60, 120, 300, 900, 1_800]

    public let backoffSchedule: [TimeInterval]
    public let maximumInterval: TimeInterval

    public init(
        backoffSchedule: [TimeInterval] = RetryPolicy.defaultBackoffSchedule,
        maximumInterval: TimeInterval = RetryPolicy.maximumInterval
    ) {
        self.backoffSchedule = backoffSchedule.isEmpty ? RetryPolicy.defaultBackoffSchedule : backoffSchedule
        self.maximumInterval = max(maximumInterval, RetryPolicy.minimumInterval)
    }

    /// Backoff for the n-th consecutive failure (1-based).
    public func backoffDelay(failureCount: Int) -> TimeInterval {
        let index = min(max(failureCount - 1, 0), backoffSchedule.count - 1)
        return min(max(backoffSchedule[index], RetryPolicy.minimumInterval), maximumInterval)
    }

    /// Delay to apply before the next attempt. Never shorter than the exponential backoff.
    public func delay(failureCount: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let backoff = backoffDelay(failureCount: failureCount)
        if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            return max(backoff, retryAfter)
        }
        return backoff
    }

    /// Delay after a successful poll.
    public func successInterval(minimum: TimeInterval = RetryPolicy.minimumInterval) -> TimeInterval {
        max(minimum, RetryPolicy.minimumInterval)
    }
}
