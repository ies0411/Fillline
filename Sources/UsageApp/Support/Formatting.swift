import Foundation
import UsageCore

// MARK: - Severity

/// How much visual emphasis a remaining value earns.
///
/// Only *low* values are emphasised: normal values stay monochrome so the warning
/// colour keeps its meaning. Thresholds are strict (`< 15%`, `< 5%`), so 15.0% is
/// normal and 5.0% is a warning, not a critical value.
enum RemainingSeverity: Sendable, Hashable {
    case normal
    case warning
    case critical
}

// MARK: - Formatting

/// Pure, locale-stable formatting used by the menu bar, the popover and tests.
///
/// Rules that matter for trust:
/// - remaining percent is **floored**, so the UI never claims more headroom than the
///   provider reports; a positive value below 1% reads `<1%` instead of `0%`;
/// - used percent is rounded and only ever a caption;
/// - countdowns are minute-granular and never negative.
enum UsageFormat {
    static let warningThreshold: Double = 0.15
    static let criticalThreshold: Double = 0.05
    /// A value older than this is no longer shown in the menu bar, even with a `~`.
    static let menuBarStaleLimit: TimeInterval = 30 * 60

    // MARK: Numbers

    static func severity(remainingFraction: Double) -> RemainingSeverity {
        let fraction = clamped(remainingFraction)
        if fraction < criticalThreshold { return .critical }
        if fraction < warningThreshold { return .warning }
        return .normal
    }

    /// Integer percent, floored.
    static func remainingPercent(_ fraction: Double) -> Int {
        Int((clamped(fraction) * 100).rounded(.down))
    }

    /// `"62%"`, `"<1%"` or `"100%"`.
    static func remainingText(_ fraction: Double) -> String {
        let fraction = clamped(fraction)
        if fraction >= 1 { return "100%" }
        if fraction <= 0 { return "0%" }
        let percent = remainingPercent(fraction)
        return percent == 0 ? "<1%" : "\(percent)%"
    }

    /// `"2% used"` — secondary detail only.
    static func usedText(_ fraction: Double) -> String {
        let percent = Int((clamped(fraction) * 100).rounded())
        return "\(percent)% used"
    }

    // MARK: Reset countdown

    struct ResetLabel: Equatable, Sendable {
        let text: String
        /// Placeholder reset times are greyed out (AGENTS: `~` prefix).
        let isMuted: Bool
        let isResetting: Bool
    }

    /// `"resets in 3h 12m"`, `"<1m"` near the end, `"resetting…"` once past.
    ///
    /// `isEstimated` and `isPlaceholder` both earn a `~` prefix; only placeholders are
    /// visually muted, because an estimated time is still a real countdown.
    static func resetLabel(
        resetsAt: Date?,
        now: Date,
        isPlaceholder: Bool,
        isEstimated: Bool
    ) -> ResetLabel {
        guard let resetsAt else {
            return ResetLabel(text: "no reset time", isMuted: true, isResetting: false)
        }
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 0 {
            return ResetLabel(text: "resetting…", isMuted: false, isResetting: true)
        }
        let approximate = isPlaceholder || isEstimated ? "~ " : ""
        return ResetLabel(
            text: "\(approximate)resets in \(duration(interval))",
            isMuted: isPlaceholder,
            isResetting: false
        )
    }

    /// Compact duration: `3d 2h`, `3h 12m`, `12m`, `<1m`.
    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "—" }
        if interval < 60 { return "<1m" }
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// Spoken form for VoiceOver: "2 hours 48 minutes".
    static func spokenDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "unknown" }
        if interval < 60 { return "less than a minute" }
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days) \(days == 1 ? "day" : "days")") }
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 && days == 0 {
            parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Age

    /// `"just now"`, `"4m ago"`, `"2h ago"`, `"3d ago"`.
    static func relativeAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    // MARK: Accessibility

    static func accessibilityLabel(for window: LimitWindow, now: Date) -> String {
        let reset = resetLabel(
            resetsAt: window.resetsAt,
            now: now,
            isPlaceholder: window.isPlaceholder,
            isEstimated: window.isEstimated
        )

        let resetPhrase: String
        if reset.isResetting {
            resetPhrase = "resetting now"
        } else if let resetsAt = window.resetsAt {
            let interval = resetsAt.timeIntervalSince(now)
            let prefix = window.isPlaceholder || window.isEstimated ? "approximately " : ""
            resetPhrase = "resets in \(prefix)\(spokenDuration(interval))"
        } else {
            resetPhrase = "reset time unknown"
        }

        return
            isAmountRow(window)
            ? "\(window.label), \(resetPhrase)"
            : "\(window.label), \(remainingText(window.remainingFraction)) remaining, \(resetPhrase), \(usedText(window.usedFraction))"
    }

    // MARK: Amount rows

    /// A row that carries an absolute amount instead of a fraction.
    ///
    /// Two shapes exist today:
    /// - `.credits` whose label starts with `$` (OpenRouter's USD balance, issue #13);
    /// - an `isEstimated` row whose label carries a token quantity (Claude's local-log estimate,
    ///   issue #16 — local logs have no plan limit, so no fraction can exist).
    ///
    /// Such a row is rendered as text only — no meter, no percentage, no "x% used" caption — and
    /// is kept out of every percent-driven surface (menu bar number, sparkline, alerts). The
    /// model itself is unchanged: there is no optional fraction to add.
    static func isAmountRow(_ window: LimitWindow) -> Bool {
        if window.kind == .credits && window.label.hasPrefix("$") { return true }
        return window.isEstimated && window.label.contains(" tokens")
    }

    /// `"$8.50 left · no cap"` → `"$8.50"` for the menu bar.
    ///
    /// A token estimate keeps its unit (`"1.2M tok"`): a bare `1.2M` would read as a quota, and
    /// the unit is what says "this is a count, not a percentage".
    static func menuBarAmount(_ label: String) -> String {
        let parts = label.split(separator: " ")
        guard let first = parts.first else { return label }
        if parts.count > 1, parts[1] == "tokens" { return "\(first) tok" }
        return String(first)
    }

    // MARK: Menu bar

    struct MenuBarEntry: Sendable, Hashable {
        let provider: ProviderID
        /// `nil` for an amount row (USD credits), which has no fraction to show.
        let remainingFraction: Double?
        /// Verbatim value for entries that are not percentages (e.g. `"$8.50"`).
        let text: String?
        /// Value is last-known, not fresh; rendered with a `~` prefix.
        let isApproximate: Bool

        init(
            provider: ProviderID,
            remainingFraction: Double?,
            text: String? = nil,
            isApproximate: Bool
        ) {
            self.provider = provider
            self.remainingFraction = remainingFraction
            self.text = text
            self.isApproximate = isApproximate
        }
    }

    struct MenuBarSegment: Identifiable, Equatable, Sendable {
        let id: String
        let symbolName: String?
        let text: String
        let isCritical: Bool
    }

    struct MenuBarContent: Equatable, Sendable {
        let segments: [MenuBarSegment]
        let showsWarning: Bool
        let accessibilityLabel: String

        var isEmpty: Bool { segments.isEmpty }
    }

    /// Builds the menu bar label. Providers with no usable value are omitted entirely —
    /// a missing provider is never rendered as `0%`.
    static func menuBarContent(entries: [MenuBarEntry], style: MenuBarLabelStyle) -> MenuBarContent {
        guard !entries.isEmpty else {
            return MenuBarContent(
                segments: [],
                showsWarning: false,
                accessibilityLabel: "Usage. No data yet."
            )
        }

        let shown: [MenuBarEntry]
        switch style {
        case .all, .glyphs:
            shown = entries
        case .compact, .worst:
            shown =
                entries.min { lhs, rhs in
                    (lhs.remainingFraction ?? 1) < (rhs.remainingFraction ?? 1)
                }.map { [$0] } ?? []
        }

        let segments = shown.map { entry -> MenuBarSegment in
            let fraction = entry.remainingFraction
            let value: String
            if let text = entry.text {
                value = entry.isApproximate ? "~\(text)" : text
            } else {
                let percent = remainingText(fraction ?? 0)
                value = "\(entry.isApproximate ? "~" : "")\(percent)"
            }
            let isCritical = (fraction ?? 1) < criticalThreshold
            switch style {
            case .all:
                return MenuBarSegment(
                    id: entry.provider.rawValue,
                    symbolName: nil,
                    text: "\(entry.provider.shortLabel) \(value)",
                    isCritical: isCritical
                )
            case .glyphs, .compact:
                return MenuBarSegment(
                    id: entry.provider.rawValue,
                    symbolName: entry.provider.symbolName,
                    text: value,
                    isCritical: isCritical
                )
            case .worst:
                return MenuBarSegment(
                    id: entry.provider.rawValue,
                    symbolName: nil,
                    text: "\(entry.provider.shortLabel) \(value)",
                    isCritical: isCritical
                )
            }
        }

        let spoken = shown.map { entry -> String in
            if let text = entry.text {
                return "\(entry.provider.displayName) \(entry.isApproximate ? "approximately " : "")\(text)"
            }
            let fraction = entry.remainingFraction ?? 0
            let percent = remainingText(fraction)
            let approximate = entry.isApproximate ? "approximately " : ""
            let low = fraction < criticalThreshold ? ", low" : ""
            return "\(entry.provider.displayName) \(approximate)\(percent) remaining\(low)"
        }

        return MenuBarContent(
            segments: segments,
            showsWarning: shown.contains { ($0.remainingFraction ?? 1) < criticalThreshold },
            accessibilityLabel: "Usage. " + spoken.joined(separator: ". ") + "."
        )
    }
}

// MARK: - Provider presentation

extension ProviderID {
    /// Functional SF Symbol, not a brand mark. Kept monochrome in the UI.
    var symbolName: String {
        switch self {
        case .claudeCode: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .openCodeGo: "bolt.fill"
        case .antigravity: "hexagon"
        case .githubCopilot: "checkmark.seal"
        case .openRouter: "arrow.triangle.branch"
        }
    }

    /// Short name used in error copy ("Sign in to Codex").
    var shortName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCodeGo: "OpenCode Go"
        case .antigravity: "Antigravity"
        case .githubCopilot: "Copilot"
        case .openRouter: "OpenRouter"
        }
    }

    /// Command that refreshes the CLI-owned credential, when one exists.
    var signInCommand: String? {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .openCodeGo: nil
        case .antigravity: "agy"
        case .githubCopilot: "gh auth login"
        case .openRouter: nil
        }
    }
}

// MARK: - Clamping

private func clamped(_ fraction: Double) -> Double {
    guard fraction.isFinite else { return 0 }
    return min(max(fraction, 0), 1)
}
