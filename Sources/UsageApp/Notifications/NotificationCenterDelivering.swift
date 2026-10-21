import Foundation
import UserNotifications

/// What a single alert says. Built from snapshot values only — never a token, an email,
/// an account id, or a raw provider response (AGENTS §4).
struct NotificationPayload: Sendable, Equatable {
    /// Deterministic so a repeated alert replaces the previous banner instead of stacking.
    let identifier: String
    let title: String
    let body: String
}

/// Seam over `UNUserNotificationCenter` so the app can be exercised without the system
/// permission prompt.
protocol NotificationDelivering: Sendable {
    /// Shows the macOS permission prompt once. Returns `false` when the user or the system
    /// has denied notifications. Never call this at launch: only when the master toggle
    /// is switched on (issue #4).
    func requestAuthorization() async -> Bool

    func deliver(_ payload: NotificationPayload) async
}

/// Production implementation. Requesting authorization is always user-initiated.
struct UserNotificationDelivering: NotificationDelivering {
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func deliver(_ payload: NotificationPayload) async {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        // No `userInfo`: notifications are written to disk by the system, so they must not
        // carry anything beyond the two strings above.

        let request = UNNotificationRequest(
            identifier: payload.identifier,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        // Deliberately ignore the error: a rejected alert is not worth interrupting the
        // poll loop, and the reason is never surfaced to the user as a token leak risk.
        try? await center.add(request)
    }
}
