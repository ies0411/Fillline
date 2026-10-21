import Foundation
import Observation
import UsageCore

// MARK: - Settings types

enum PollInterval: Int, CaseIterable, Identifiable, Sendable, Hashable {
    case fast = 60
    case balanced = 180
    case relaxed = 300

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .fast: "1 min"
        case .balanced: "3 min"
        case .relaxed: "5 min"
        }
    }
}

/// How much of the menu bar the label is allowed to occupy.
enum MenuBarLabelStyle: String, CaseIterable, Identifiable, Sendable, Hashable {
    /// `C 62% · O 51% · G 41%`
    case all
    /// `✦ 62% · ‹/› 51% · ⚡ 41%`
    case glyphs
    /// `◔ 41%` — icon plus the lowest remaining value.
    case compact
    /// `G 41%` — worst provider only, letter kept for identification.
    case worst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Letters + numbers"
        case .glyphs: "Icons + numbers"
        case .compact: "Compact"
        case .worst: "Lowest provider only"
        }
    }

    var example: String {
        switch self {
        case .all: "C 62% · O 51% · G 41%"
        case .glyphs: "icons + 62% · 51% · 41%"
        case .compact: "icon + 41% (lowest)"
        case .worst: "G 41%"
        }
    }
}

/// Which window's remaining value drives the menu bar number.
enum MenuBarNumber: String, CaseIterable, Identifiable, Sendable, Hashable {
    case primary
    case session
    case weekly
    case lowest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: "Session first"
        case .session: "5-hour / rolling"
        case .weekly: "Weekly"
        case .lowest: "Lowest of any window"
        }
    }

    var explanation: String {
        switch self {
        case .primary:
            "The 5-hour window when present, otherwise the tightest window."
        case .session:
            "Claude and Codex use their 5-hour session; OpenCode Go uses its rolling window."
        case .weekly:
            "The 7-day window. Falls back to the main window when a provider has none."
        case .lowest:
            "The tightest window on each provider, so the menu bar shows the real wall."
        }
    }
}

// MARK: - App model

/// Owns the polling actors and turns their snapshots into display state.
///
/// Concurrency: this class is main-actor isolated and never performs disk, Keychain or
/// network work itself — every such call goes through `PollScheduler` or `SnapshotCache`.
@MainActor
@Observable
final class AppModel {
    // MARK: Display state

    /// Last known snapshot per provider. Values survive failures by design.
    private(set) var snapshots: [ProviderID: UsageSnapshot] = [:]
    private(set) var isRefreshing = false
    private(set) var lastAttemptAt: [ProviderID: Date] = [:]

    // MARK: Settings (persisted)

    var claudeOAuthReadEnabled: Bool {
        didSet {
            guard oldValue != claudeOAuthReadEnabled else { return }
            defaults.set(claudeOAuthReadEnabled, forKey: Keys.claudeOAuthReadEnabled)
            if !claudeOAuthReadEnabled {
                clearClaudeData()
            }
            rebuildScheduler()
        }
    }

    var pollInterval: PollInterval {
        didSet {
            guard oldValue != pollInterval else { return }
            defaults.set(pollInterval.rawValue, forKey: Keys.pollInterval)
            ageSnapshots()
        }
    }

    var menuBarStyle: MenuBarLabelStyle {
        didSet {
            guard oldValue != menuBarStyle else { return }
            defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle)
        }
    }

    var menuBarNumber: MenuBarNumber {
        didSet {
            guard oldValue != menuBarNumber else { return }
            defaults.set(menuBarNumber.rawValue, forKey: Keys.menuBarNumber)
        }
    }

    var enabledProviders: Set<ProviderID> {
        didSet {
            guard oldValue != enabledProviders else { return }
            let raw = enabledProviders.map(\.rawValue).sorted()
            defaults.set(raw, forKey: Keys.enabledProviders)
            rebuildScheduler()
        }
    }

    /// Master switch for alerts. Off by default (AGENTS §10 #2); switching it on is the
    /// only thing in the app that ever shows the macOS permission prompt.
    var notificationsEnabled: Bool {
        didSet {
            guard oldValue != notificationsEnabled else { return }
            defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            guard notificationsEnabled else { return }
            Task { [weak self] in
                await self?.requestNotificationAuthorization()
            }
        }
    }

    /// `true` once the system (or the user) has refused notifications, so Settings can
    /// explain why the toggle produces nothing.
    private(set) var notificationsPermissionDenied = false

    private(set) var hasCompletedOnboarding: Bool {
        didSet {
            guard oldValue != hasCompletedOnboarding else { return }
            defaults.set(hasCompletedOnboarding, forKey: Keys.onboardingComplete)
        }
    }

    // MARK: Private plumbing

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private let notifier: any NotificationDelivering
    @ObservationIgnored private let notificationKeys: NotificationKeyStore
    /// Stateless and `Sendable`; the deciding rules live in `UsageCore` so they are tested
    /// without UserDefaults or UserNotifications.
    @ObservationIgnored private let notificationPlanner = NotificationPlanner()
    @ObservationIgnored private var scheduler: PollScheduler
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var manualRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var hasBootstrapped = false

    /// The scheduler's own floor is 60s; Claude is 180s (AGENTS §2). The user's chosen
    /// interval is enforced one level up, in `tick()`, so changing it never rebuilds the
    /// scheduler or loses its rate-limit state.
    private static let schedulerBaseInterval: TimeInterval = 60
    private static let claudeMinimumInterval: TimeInterval = 180
    /// `agy` is a cold-start subprocess (~seconds), so poll it far less often.
    private static let antigravityMinimumInterval: TimeInterval = 300

    init(
        defaults: UserDefaults = .standard,
        notifier: any NotificationDelivering = UserNotificationDelivering()
    ) {
        self.defaults = defaults
        self.cache = SnapshotCache()
        self.notifier = notifier
        self.notificationKeys = NotificationKeyStore(defaults: defaults)
        self.scheduler = PollScheduler(providers: [], configuration: .init())

        self.claudeOAuthReadEnabled = defaults.bool(forKey: Keys.claudeOAuthReadEnabled)
        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        self.pollInterval = PollInterval(rawValue: defaults.integer(forKey: Keys.pollInterval)) ?? .balanced
        self.menuBarStyle = MenuBarLabelStyle(rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? "") ?? .all
        self.menuBarNumber = MenuBarNumber(rawValue: defaults.string(forKey: Keys.menuBarNumber) ?? "") ?? .primary
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.onboardingComplete)

        if let stored = defaults.array(forKey: Keys.enabledProviders) as? [String] {
            self.enabledProviders = Set(stored.compactMap(ProviderID.init(rawValue:)))
        } else {
            // Antigravity spawns a CLI subprocess, so it starts off (AGENTS §2).
            self.enabledProviders = Set(ProviderID.allCases.filter { $0 != .antigravity })
        }

        rebuildScheduler()
    }

    // MARK: Derived state

    var orderedProviders: [ProviderID] {
        ProviderID.allCases.filter { enabledProviders.contains($0) }
    }

    /// Providers that may actually make a request. Claude is excluded until the user
    /// opts in, which is what keeps its Keychain item untouched by default.
    var pollableProviders: [ProviderID] {
        orderedProviders.filter { $0 != .claudeCode || claudeOAuthReadEnabled }
    }

    var isClaudeCardActive: Bool {
        enabledProviders.contains(.claudeCode)
    }

    var lastCheckedAt: Date? {
        lastAttemptAt.values.max()
    }

    func snapshot(for provider: ProviderID) -> UsageSnapshot? {
        guard provider != .claudeCode || claudeOAuthReadEnabled else { return nil }
        return snapshots[provider]
    }

    /// Value shown in the menu bar, after the user's window preference. `nil` means the
    /// provider is omitted (no data), never rendered as 0%.
    private func menuBarFraction(for snapshot: UsageSnapshot) -> Double? {
        switch menuBarNumber {
        case .primary:
            snapshot.primaryWindow?.remainingFraction
        case .session:
            (snapshot.window(kind: .session5h)
                ?? snapshot.window(kind: .rolling)
                ?? snapshot.primaryWindow)?.remainingFraction
        case .weekly:
            (snapshot.window(kind: .weekly7d) ?? snapshot.primaryWindow)?.remainingFraction
        case .lowest:
            snapshot.lowestRemainingFraction
        }
    }

    var menuBarContent: UsageFormat.MenuBarContent {
        guard hasCompletedOnboarding else {
            return UsageFormat.menuBarContent(entries: [], style: menuBarStyle)
        }

        let entries = orderedProviders.compactMap { provider -> UsageFormat.MenuBarEntry? in
            guard provider != .claudeCode || claudeOAuthReadEnabled else { return nil }
            guard let snapshot = snapshots[provider],
                  snapshot.hasValues,
                  let fraction = menuBarFraction(for: snapshot)
            else {
                return nil
            }

            switch snapshot.status {
            case .ok:
                return UsageFormat.MenuBarEntry(
                    provider: provider,
                    remainingFraction: fraction,
                    isApproximate: false
                )
            case .stale(let age):
                // A very old number is left out of the most prominent surface entirely.
                guard age <= UsageFormat.menuBarStaleLimit else { return nil }
                return UsageFormat.MenuBarEntry(
                    provider: provider,
                    remainingFraction: fraction,
                    isApproximate: true
                )
            default:
                return nil
            }
        }

        return UsageFormat.menuBarContent(entries: entries, style: menuBarStyle)
    }

    var staleAfter: TimeInterval {
        max(180, pollInterval.seconds + 120)
    }

    // MARK: Lifecycle

    /// Idempotent. Called from the menu bar label and the popover.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrap()
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        guard hasCompletedOnboarding else { return }

        let cached = await cache.load()
        let now = Date()
        for (provider, snapshot) in cached where pollableProviders.contains(provider) {
            snapshots[provider] = snapshot.aged(now: now, staleAfter: staleAfter)
        }

        rebuildScheduler()
        await tick()
    }

    /// One pass over the providers that are due. User-initiated refreshes are `force`.
    private func tick(force: Bool = false) async {
        guard hasCompletedOnboarding else { return }
        let now = Date()

        var didChange = false

        for provider in pollableProviders {
            if force {
                // Even a manual refresh must not hammer Claude's endpoint.
                if provider == .claudeCode,
                   let last = lastAttemptAt[provider],
                   now.timeIntervalSince(last) < Self.claudeMinimumInterval {
                    continue
                }
            } else {
                if let last = lastAttemptAt[provider],
                   now.timeIntervalSince(last) < effectiveInterval(for: provider) {
                    continue
                }
                guard await scheduler.isDue(provider, at: now) else { continue }
            }

            let before = await scheduler.state(for: provider)?.lastAttemptAt
            if let snapshot = await scheduler.poll(provider, force: force) {
                apply(snapshot)
                didChange = true
            }
            if let after = await scheduler.state(for: provider)?.lastAttemptAt, after != before {
                lastAttemptAt[provider] = after
            }
        }

        ageSnapshots()
        if didChange {
            await persist()
        }
        notifyIfNeeded()
    }

    /// Manual refresh: sets a spinner, never blocks the popover, never clears numbers.
    func refreshNow() {
        guard hasCompletedOnboarding, manualRefreshTask == nil else { return }
        isRefreshing = true
        manualRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.tick(force: true)
            self.isRefreshing = false
            self.manualRefreshTask = nil
        }
    }

    func completeOnboarding() {
        guard !hasCompletedOnboarding else { return }
        hasCompletedOnboarding = true
        rebuildScheduler()
        Task { await tick() }
    }

    /// Shows the welcome screen again the next time the popover opens.
    func resetOnboarding() {
        hasCompletedOnboarding = false
    }

    // MARK: Provider toggles

    func isProviderEnabled(_ provider: ProviderID) -> Bool {
        enabledProviders.contains(provider)
    }

    func setProvider(_ provider: ProviderID, enabled: Bool) {
        if enabled {
            enabledProviders.insert(provider)
        } else {
            enabledProviders.remove(provider)
        }
    }

    // MARK: Pipeline

    private func effectiveInterval(for provider: ProviderID) -> TimeInterval {
        if provider == .claudeCode {
            return max(pollInterval.seconds, Self.claudeMinimumInterval)
        }
        return max(pollInterval.seconds, Self.schedulerBaseInterval)
    }

    private func makeProviders() -> [any UsageProvider] {
        var providers: [any UsageProvider] = []
        if enabledProviders.contains(.claudeCode), claudeOAuthReadEnabled {
            providers.append(ClaudeCodeProvider())
        }
        if enabledProviders.contains(.codex) {
            providers.append(CodexProvider())
        }
        if enabledProviders.contains(.openCodeGo) {
            providers.append(OpenCodeGoProvider())
        }
        // Opt-in only: Antigravity runs `agy` as a subprocess, which is a heavier
        // and more surprising behaviour than reading a file or calling an API.
        if enabledProviders.contains(.antigravity) {
            providers.append(AntigravityProvider())
        }
        return providers
    }

    private func rebuildScheduler() {
        scheduler = PollScheduler(
            providers: makeProviders(),
            configuration: .init(
                baseInterval: Self.schedulerBaseInterval,
                staleAfter: staleAfter,
                minimumIntervalOverrides: [
                    .claudeCode: Self.claudeMinimumInterval,
                    .antigravity: Self.antigravityMinimumInterval
                ]
            )
        )
    }

    /// Applies a poll result without ever throwing away usable numbers.
    private func apply(_ snapshot: UsageSnapshot) {
        let provider = snapshot.provider

        if !snapshot.hasValues,
           let existing = snapshots[provider],
           existing.hasValues,
           snapshot.status.isFailure {
            snapshots[provider] = UsageSnapshot(
                provider: provider,
                plan: snapshot.plan ?? existing.plan,
                resetCredits: snapshot.resetCredits ?? existing.resetCredits,
                windows: existing.windows,
                source: existing.source,
                status: snapshot.status,
                capturedAt: existing.capturedAt
            )
            return
        }

        snapshots[provider] = snapshot
    }

    /// Recomputes staleness with the current interval. Countdowns themselves are
    /// refreshed by `TimelineView` in the views, not by this loop.
    private func ageSnapshots() {
        let now = Date()
        let threshold = staleAfter
        for (provider, snapshot) in snapshots {
            snapshots[provider] = snapshot.aged(now: now, staleAfter: threshold)
        }
    }

    private func clearClaudeData() {
        snapshots[.claudeCode] = nil
        lastAttemptAt[.claudeCode] = nil
        Task { await persist() }
    }

    private func persist() async {
        guard hasCompletedOnboarding else { return }
        let payload = snapshots.filter { pollableProviders.contains($0.key) }
        if payload.isEmpty {
            try? await cache.clear()
        } else {
            try? await cache.save(payload)
        }
    }

    // MARK: Notifications

    private func requestNotificationAuthorization() async {
        let granted = await notifier.requestAuthorization()
        notificationsPermissionDenied = !granted
    }

    /// Evaluates alerts after every pass. Runs on the main actor because the planner and
    /// the key store are cheap; only the delivery itself is async.
    ///
    /// Keys are recorded *before* delivery so two overlapping passes can never send the
    /// same threshold twice.
    private func notifyIfNeeded() {
        guard notificationsEnabled, !notificationsPermissionDenied else { return }

        // Same visibility rules as the cards: a disabled provider, or Claude without the
        // read opt-in, must not alert.
        let visible = orderedProviders.compactMap { snapshot(for: $0) }
        guard !visible.isEmpty else { return }

        let now = Date()
        let decisions = notificationPlanner.decisions(
            for: visible,
            now: now,
            alreadyNotified: notificationKeys.keys()
        )
        guard !decisions.isEmpty else { return }

        var payloads: [NotificationPayload] = []
        for decision in decisions {
            notificationKeys.insert(notificationPlanner.key(for: decision, in: visible), at: now)
            if let payload = NotificationCopy.payload(for: decision, in: visible, now: now) {
                payloads.append(payload)
            }
        }
        guard !payloads.isEmpty else { return }

        let notifier = self.notifier
        Task {
            for payload in payloads {
                await notifier.deliver(payload)
            }
        }
    }

    // MARK: Defaults keys

    private enum Keys {
        static let claudeOAuthReadEnabled = "claudeOAuthReadEnabled"
        static let pollInterval = "pollIntervalSeconds"
        static let menuBarStyle = "menuBarStyle"
        static let menuBarNumber = "menuBarNumber"
        static let enabledProviders = "enabledProviders"
        static let onboardingComplete = "hasCompletedOnboarding"
        static let notificationsEnabled = "notificationsEnabled"
    }
}

// MARK: - Links

enum AppLinks {
    /// Matches `.github/ISSUE_TEMPLATE/config.yml`. Opened in the browser from onboarding
    /// and Settings only — never fetched by the app, so `github.com` stays out of the
    /// network allowlist.
    static let readme = URL(string: "https://github.com/ies0411/Fillline#privacy")!
    static let readmePolicy = URL(string: "https://github.com/ies0411/Fillline#unofficial-and-what-that-means")!
}
