import Foundation
import UsageCore

/// Turns a `NotificationDecision` into plain, user-facing copy.
///
/// Copy rules (AGENTS §4, issue #4): provider name, window label, remaining percent and
/// reset countdown — nothing else. No tokens, emails, org ids, plan names, or raw values.
enum NotificationCopy {
    static func payload(
        for decision: NotificationDecision,
        in snapshots: [UsageSnapshot],
        now: Date
    ) -> NotificationPayload? {
        guard
            let window =
                snapshots
                .first(where: { $0.provider == decision.provider })?
                .windows
                .first(where: { $0.kind == decision.windowKind })
        else {
            return nil
        }

        let remaining = UsageFormat.remainingText(window.remainingFraction)
        let resetSentence = resetText(resetsAt: window.resetsAt, now: now)

        let body: String
        switch decision.kind {
        case .warning80:
            body = "\(remaining) remaining. \(resetSentence)"
        case .critical95:
            body = "Only \(remaining) remaining. \(resetSentence)"
        case .resetSoon:
            body = "Resets soon. \(remaining) remaining."
        }

        return NotificationPayload(
            identifier: "\(decision.provider.rawValue).\(window.kind.rawValue).\(decision.kind.rawValue)",
            title: "\(decision.provider.displayName) · \(window.label)",
            body: body
        )
    }

    /// One sentence, always terminated, so the bodies read consistently.
    private static func resetText(resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else { return "No reset time reported." }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return "Resetting now." }
        return "Resets in \(UsageFormat.duration(interval))."
    }
}
