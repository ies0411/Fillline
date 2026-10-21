import Foundation

/// One alert the app should show, decided purely from snapshots.
///
/// Decisions carry only the facts an alert needs (provider, window, used fraction); the
/// copy and the delivery live in the app layer so this type stays UI-free and testable
/// (AGENTS §3).
public struct NotificationDecision: Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// Used fraction reached the warning threshold (80% by default).
        case warning80
        /// Used fraction reached the critical threshold (95% by default).
        case critical95
        /// The window resets within the lead time and quota is still unspent.
        case resetSoon
    }

    public let kind: Kind
    public let provider: ProviderID
    public let windowKind: LimitWindow.Kind
    /// Used fraction of the window at the moment of the decision, `0...1`.
    public let usedFraction: Double

    public init(
        kind: Kind,
        provider: ProviderID,
        windowKind: LimitWindow.Kind,
        usedFraction: Double
    ) {
        self.kind = kind
        self.provider = provider
        self.windowKind = windowKind
        self.usedFraction = usedFraction.clampedToUnitInterval
    }
}

/// Identity of an alert that has already been delivered.
///
/// The reset time is part of the identity on purpose: when a window rolls over, the new
/// cycle gets a new `resetsAt` and therefore re-arms the same threshold (issue #4).
public struct NotificationKey: Hashable, Sendable, CustomStringConvertible {
    public let provider: ProviderID
    public let windowKind: LimitWindow.Kind
    public let kind: NotificationDecision.Kind
    /// Reset time of the cycle the alert belongs to, in whole seconds. `nil` when the
    /// provider reports no reset time; such a key never re-arms on its own.
    public let resetEpoch: Int?

    public init(
        provider: ProviderID,
        windowKind: LimitWindow.Kind,
        kind: NotificationDecision.Kind,
        resetEpoch: Int?
    ) {
        self.provider = provider
        self.windowKind = windowKind
        self.kind = kind
        self.resetEpoch = resetEpoch
    }

    public init(
        provider: ProviderID,
        windowKind: LimitWindow.Kind,
        kind: NotificationDecision.Kind,
        resetsAt: Date?
    ) {
        self.init(
            provider: provider,
            windowKind: windowKind,
            kind: kind,
            resetEpoch: resetsAt.map { Int($0.timeIntervalSince1970) }
        )
    }

    public var description: String { storageString }

    // MARK: Persistence form

    /// Stable, human-readable form persisted by the app layer.
    ///
    /// Composed only of raw values that cannot contain `|`, so it round-trips exactly.
    public var storageString: String {
        let epoch = resetEpoch.map(String.init) ?? ""
        return "\(provider.rawValue)|\(windowKind.rawValue)|\(kind.rawValue)|\(epoch)"
    }

    public init?(storageString: String) {
        let parts = storageString.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4,
            let provider = ProviderID(rawValue: String(parts[0])),
            let windowKind = LimitWindow.Kind(rawValue: String(parts[1])),
            let kind = NotificationDecision.Kind(rawValue: String(parts[2]))
        else {
            return nil
        }

        let epochText = String(parts[3])
        let resetEpoch: Int?
        if epochText.isEmpty {
            resetEpoch = nil
        } else if let epoch = Int(epochText) {
            resetEpoch = epoch
        } else {
            return nil
        }

        self.init(provider: provider, windowKind: windowKind, kind: kind, resetEpoch: resetEpoch)
    }
}

/// Decides which alerts a snapshot set earns. Pure and deterministic: no clock, no
/// UserDefaults, no UserNotifications (AGENTS §6 — every state transition is fixture-testable).
///
/// Rules:
/// - only `.ok` and `.stale` snapshots with values may alert; a failed provider never
///   invents an alert from data the user cannot trust;
/// - windows flagged `isEstimated` or `isPlaceholder` are skipped, because their reset
///   time is a guess (AGENTS §9: estimates are never presented as facts);
/// - `critical95` replaces `warning80` for the same window in a single evaluation, so a
///   window at 96% does not produce two alerts;
/// - `resetSoon` is independent of the thresholds but still requires unspent quota.
public struct NotificationPlanner: Sendable {
    public static let defaultWarningThreshold: Double = 0.80
    public static let defaultCriticalThreshold: Double = 0.95
    public static let defaultResetSoonWindow: TimeInterval = 900

    public let warningThreshold: Double
    public let criticalThreshold: Double
    public let resetSoonWindow: TimeInterval

    public init(
        warningThreshold: Double = NotificationPlanner.defaultWarningThreshold,
        criticalThreshold: Double = NotificationPlanner.defaultCriticalThreshold,
        resetSoonWindow: TimeInterval = NotificationPlanner.defaultResetSoonWindow
    ) {
        let warning = warningThreshold.clampedToUnitInterval
        self.warningThreshold = warning
        // A critical threshold below the warning threshold would make warning80 dead code.
        self.criticalThreshold = max(criticalThreshold.clampedToUnitInterval, warning)
        self.resetSoonWindow = max(0, resetSoonWindow)
    }

    // MARK: Evaluation

    /// Alerts earned by `snapshots` at `now`, in a stable order: provider, then window
    /// kind, then alert kind.
    ///
    /// `alreadyNotified` holds keys that were delivered before, so the same threshold is
    /// never announced twice for the same reset cycle.
    public func decisions(
        for snapshots: [UsageSnapshot],
        now: Date,
        alreadyNotified: Set<NotificationKey> = []
    ) -> [NotificationDecision] {
        var decisions: [NotificationDecision] = []

        for snapshot in orderedSnapshots(snapshots) {
            // A provider that cannot be trusted must not alert, even if it still carries
            // the last good windows for display.
            guard snapshot.status.hasUsableValues, snapshot.hasValues else { continue }

            for window in orderedWindows(snapshot.windows) {
                guard !window.isEstimated, !window.isPlaceholder else { continue }

                if let kind = thresholdKind(for: window.usedFraction) {
                    let key = NotificationKey(
                        provider: snapshot.provider,
                        windowKind: window.kind,
                        kind: kind,
                        resetsAt: window.resetsAt
                    )
                    if !alreadyNotified.contains(key) {
                        decisions.append(
                            NotificationDecision(
                                kind: kind,
                                provider: snapshot.provider,
                                windowKind: window.kind,
                                usedFraction: window.usedFraction
                            )
                        )
                    }
                }

                if isResetSoon(window, now: now) {
                    let key = NotificationKey(
                        provider: snapshot.provider,
                        windowKind: window.kind,
                        kind: .resetSoon,
                        resetsAt: window.resetsAt
                    )
                    if !alreadyNotified.contains(key) {
                        decisions.append(
                            NotificationDecision(
                                kind: .resetSoon,
                                provider: snapshot.provider,
                                windowKind: window.kind,
                                usedFraction: window.usedFraction
                            )
                        )
                    }
                }
            }
        }

        return decisions
    }

    /// Persistence key for a decision, resolved against the snapshot that produced it.
    ///
    /// Passing the same `snapshots` used for `decisions(for:now:alreadyNotified:)` keeps
    /// the key and the decision in sync.
    public func key(
        for decision: NotificationDecision,
        in snapshots: [UsageSnapshot]
    ) -> NotificationKey {
        let window =
            snapshots
            .first { $0.provider == decision.provider }?
            .windows
            .first { $0.kind == decision.windowKind }

        return NotificationKey(
            provider: decision.provider,
            windowKind: decision.windowKind,
            kind: decision.kind,
            resetsAt: window?.resetsAt
        )
    }

    // MARK: Rules

    private func thresholdKind(for usedFraction: Double) -> NotificationDecision.Kind? {
        let used = usedFraction.clampedToUnitInterval
        if used >= criticalThreshold { return .critical95 }
        if used >= warningThreshold { return .warning80 }
        return nil
    }

    private func isResetSoon(_ window: LimitWindow, now: Date) -> Bool {
        // Nothing to warn about when the window is already spent: the reset is not news.
        guard window.remainingFraction > 0, let resetsAt = window.resetsAt else { return false }
        let interval = resetsAt.timeIntervalSince(now)
        return interval > 0 && interval <= resetSoonWindow
    }

    // MARK: Determinism

    private func orderedSnapshots(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        snapshots.enumerated()
            .sorted { lhs, rhs in
                let left = Self.providerRank(lhs.element.provider)
                let right = Self.providerRank(rhs.element.provider)
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func orderedWindows(_ windows: [LimitWindow]) -> [LimitWindow] {
        windows.enumerated()
            .sorted { lhs, rhs in
                let left = Self.windowRank(lhs.element.kind)
                let right = Self.windowRank(rhs.element.kind)
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func providerRank(_ provider: ProviderID) -> Int {
        providerOrder[provider] ?? Int.max
    }

    private static func windowRank(_ kind: LimitWindow.Kind) -> Int {
        windowOrder[kind] ?? Int.max
    }

    /// Declaration order, not alphabetical: it matches the card stack in the popover.
    private static let providerOrder: [ProviderID: Int] = Dictionary(
        uniqueKeysWithValues: ProviderID.allCases.enumerated().map { ($1, $0) }
    )

    private static let windowOrder: [LimitWindow.Kind: Int] = Dictionary(
        uniqueKeysWithValues: LimitWindow.Kind.allCases.enumerated().map { ($1, $0) }
    )
}
