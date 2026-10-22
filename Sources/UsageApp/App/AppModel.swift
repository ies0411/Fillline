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

    /// The trail behind each card's numbers, refreshed after every poll pass. Kept in step
    /// with `snapshots`: a provider with no displayable window has no entry here, so a card
    /// can never show a line for a window it is not showing.
    private(set) var sparklines: [ProviderID: SparklineData] = [:]

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
    /// The trail behind `snapshots`. Writes are best-effort and never throw (AGENTS §3).
    @ObservationIgnored private let history: SnapshotHistory
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

    /// Per-provider floor, applied to scheduled polls *and* manual refreshes.
    ///
    /// - Claude Code: its endpoint rate-limits aggressively (AGENTS §2, 180s).
    /// - Antigravity: `agy` is a cold-start subprocess, so it polls far less often.
    /// - GitHub Copilot: the documented floor is 60s, i.e. the base interval.
    /// - OpenRouter: 120s (issue #13) — a credit balance does not move that fast.
    private static let minimumIntervals: [ProviderID: TimeInterval] = [
        .claudeCode: 180,
        .antigravity: 300,
        .githubCopilot: 60,
        .openRouter: 120,
    ]

    /// Providers that read a credential or spawn a process and therefore start **off**
    /// (AGENTS §2). Everything else is on by default.
    static let optInProviders: Set<ProviderID> = [.antigravity, .githubCopilot, .openRouter]

    init(
        defaults: UserDefaults = .standard,
        notifier: any NotificationDelivering = UserNotificationDelivering()
    ) {
        self.defaults = defaults
        self.cache = SnapshotCache()
        self.history = SnapshotHistory()
        self.notifier = notifier
        self.notificationKeys = NotificationKeyStore(defaults: defaults)
        self.scheduler = PollScheduler(providers: [], configuration: .init())

        self.claudeOAuthReadEnabled = defaults.bool(forKey: Keys.claudeOAuthReadEnabled)
        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        self.pollInterval = PollInterval(rawValue: defaults.integer(forKey: Keys.pollInterval)) ?? .balanced
        self.menuBarStyle =
            MenuBarLabelStyle(rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? "") ?? .all
        self.menuBarNumber =
            MenuBarNumber(rawValue: defaults.string(forKey: Keys.menuBarNumber) ?? "") ?? .primary
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.onboardingComplete)

        if let stored = defaults.array(forKey: Keys.enabledProviders) as? [String] {
            self.enabledProviders = Set(stored.compactMap(ProviderID.init(rawValue:)))
        } else {
            // Opt-in providers read a credential or spawn a CLI; they start off (AGENTS §2).
            self.enabledProviders = Set(
                ProviderID.allCases.filter { !Self.optInProviders.contains($0) }
            )
        }

        rebuildScheduler()
    }

    /// Documentation-render seam (issue #6), used only by `ScreenshotRenderer`.
    ///
    /// The screenshots must be of the real views, so the renderer needs a model that already
    /// holds believable data. Every value here is assigned during initialization, which means
    /// no `didSet` observer runs: nothing is written to `UserDefaults` (the onboarding flag and
    /// the settings stay untouched), no scheduler is built, and the polling loop never starts —
    /// so no Keychain read, no network request and no `agy` subprocess.
    init(documentation panel: ScreenshotFixtures.Panel) {
        self.defaults = .standard
        self.cache = SnapshotCache()
        self.history = SnapshotHistory()
        self.notifier = SilentNotificationDelivering()
        self.notificationKeys = NotificationKeyStore(defaults: .standard)
        self.scheduler = PollScheduler(providers: [], configuration: .init())

        // All four documented cards, with Claude's OAuth read on: the dashboard only draws a
        // Claude window when that consent flag is set, and Antigravity is off by default.
        self.claudeOAuthReadEnabled = true
        self.notificationsEnabled = false
        self.pollInterval = .balanced
        self.menuBarStyle = .all
        self.menuBarNumber = .primary
        self.hasCompletedOnboarding = true
        // Exactly the providers the fixture panel has data for, so a screenshot never shows a
        // card stuck on "Checking…" for a provider it cannot fill in.
        self.enabledProviders = Set(panel.snapshots.keys)

        self.snapshots = panel.snapshots
        self.sparklines = panel.sparklines
        self.lastAttemptAt = panel.lastAttemptAt

        // `start()` is idempotent on `loopTask`; this finished task is the guard that keeps a
        // render from ever reaching the network, the Keychain or the snapshot cache.
        self.loopTask = Task {}
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

    /// History trail for one card, or `nil` when that card has nothing to plot. The view
    /// still applies the "fewer than two samples draws nothing" rule, so a short series is
    /// returned as-is rather than padded to look meaningful.
    func sparkline(for provider: ProviderID) -> SparklineData? {
        guard provider != .claudeCode || claudeOAuthReadEnabled else { return nil }
        return sparklines[provider]
    }

    /// Value shown in the menu bar, after the user's window preference. `nil` means the
    /// provider is omitted (no data), never rendered as 0%.
    ///
    /// A `.credits` row carrying USD (`isAmountRow`) has no fraction; it returns `text` instead,
    /// so the menu bar shows `R $8.50` rather than a made-up percentage.
    private func menuBarValue(for snapshot: UsageSnapshot) -> (fraction: Double?, text: String?)? {
        switch menuBarNumber {
        case .primary:
            return menuBarValue(for: snapshot.primaryWindow)
        case .session:
            return menuBarValue(
                for: snapshot.window(kind: .session5h)
                    ?? snapshot.window(kind: .rolling)
                    ?? snapshot.primaryWindow
            )
        case .weekly:
            return menuBarValue(
                for: snapshot.window(kind: .weekly7d) ?? snapshot.primaryWindow
            )
        case .lowest:
            // Amount rows are excluded: they have no fraction to compare.
            let fractions = snapshot.windows
                .filter { !UsageFormat.isAmountRow($0) }
                .map(\.remainingFraction)
            if let lowest = fractions.min() {
                return (lowest, nil)
            }
            return menuBarValue(for: snapshot.primaryWindow)
        }
    }

    private func menuBarValue(for window: LimitWindow?) -> (fraction: Double?, text: String?)? {
        guard let window else { return nil }
        if UsageFormat.isAmountRow(window) {
            return (nil, UsageFormat.menuBarAmount(window.label))
        }
        return (window.remainingFraction, nil)
    }

    var menuBarContent: UsageFormat.MenuBarContent {
        guard hasCompletedOnboarding else {
            return UsageFormat.menuBarContent(entries: [], style: menuBarStyle)
        }

        let entries = orderedProviders.compactMap { provider -> UsageFormat.MenuBarEntry? in
            guard provider != .claudeCode || claudeOAuthReadEnabled else { return nil }
            guard let snapshot = snapshots[provider],
                snapshot.hasValues,
                let value = menuBarValue(for: snapshot)
            else {
                return nil
            }

            switch snapshot.status {
            case .ok:
                return UsageFormat.MenuBarEntry(
                    provider: provider,
                    remainingFraction: value.fraction,
                    text: value.text,
                    isApproximate: false
                )
            case .stale(let age):
                // A very old number is left out of the most prominent surface entirely.
                guard age <= UsageFormat.menuBarStaleLimit else { return nil }
                return UsageFormat.MenuBarEntry(
                    provider: provider,
                    remainingFraction: value.fraction,
                    text: value.text,
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
        // Show the trail from disk before the first request goes out, so a relaunch does not
        // blank the sparklines for one polling round.
        await refreshSparklines(for: Array(snapshots.keys))
        await tick()
    }

    /// One pass over the providers that are due. User-initiated refreshes are `force`.
    private func tick(force: Bool = false) async {
        guard hasCompletedOnboarding else { return }
        let now = Date()

        var didChange = false
        var polled: [UsageSnapshot] = []

        for provider in pollableProviders {
            if force {
                // Even a manual refresh must not hammer a provider below its floor. Providers
                // whose floor is the base interval keep the old "force means now" behaviour.
                let floor = Self.minimumIntervals[provider] ?? Self.schedulerBaseInterval
                if floor > Self.schedulerBaseInterval,
                    let last = lastAttemptAt[provider],
                    now.timeIntervalSince(last) < floor
                {
                    continue
                }
            } else {
                if let last = lastAttemptAt[provider],
                    now.timeIntervalSince(last) < effectiveInterval(for: provider)
                {
                    continue
                }
                guard await scheduler.isDue(provider, at: now) else { continue }
            }

            let before = await scheduler.state(for: provider)?.lastAttemptAt
            if let snapshot = await scheduler.poll(provider, force: force) {
                apply(snapshot)
                polled.append(snapshot)
                didChange = true
            }
            if let after = await scheduler.state(for: provider)?.lastAttemptAt, after != before {
                lastAttemptAt[provider] = after
            }
        }

        ageSnapshots()
        if !polled.isEmpty {
            await recordHistory(polled)
        }
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
        max(pollInterval.seconds, Self.minimumIntervals[provider] ?? Self.schedulerBaseInterval)
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
        // Opt-in too: Copilot reads the token `gh` already holds (via `gh auth token`), and
        // OpenRouter needs a key the user has to provide. Both stay off until asked for.
        if enabledProviders.contains(.githubCopilot) {
            providers.append(GitHubCopilotProvider())
        }
        if enabledProviders.contains(.openRouter) {
            providers.append(OpenRouterProvider())
        }
        return providers
    }

    private func rebuildScheduler() {
        scheduler = PollScheduler(
            providers: makeProviders(),
            configuration: .init(
                baseInterval: Self.schedulerBaseInterval,
                staleAfter: staleAfter,
                minimumIntervalOverrides: Self.minimumIntervals
            )
        )
    }

    /// Applies a poll result without ever throwing away usable numbers.
    private func apply(_ snapshot: UsageSnapshot) {
        let provider = snapshot.provider

        if !snapshot.hasValues,
            let existing = snapshots[provider],
            existing.hasValues,
            snapshot.status.isFailure
        {
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
        sparklines[.claudeCode] = nil
        // The on-disk trail is shared by every provider and has no per-provider clear (the
        // core API is frozen for #7), so Claude samples age out with the seven-day retention.
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

    // MARK: History trail

    /// Appends every snapshot from one poll pass, then republishes the sparklines.
    ///
    /// Batching after the pass rather than recording per provider keeps one disk write and
    /// one view refresh per poll. `SnapshotHistory` itself drops failures, estimates and
    /// duplicate timestamps, so the model does not pre-filter.
    private func recordHistory(_ polled: [UsageSnapshot]) async {
        for snapshot in polled {
            await history.record(snapshot)
        }
        await refreshSparklines(for: polled.map(\.provider))
    }

    /// Re-reads one series per provider. `since` is the same seven days the line draws, so
    /// the view never filters or pads the samples it is given.
    private func refreshSparklines(for providers: [ProviderID]) async {
        let since = Date().addingTimeInterval(-SparklineData.span)
        var updated = sparklines

        for provider in providers {
            guard let snapshot = snapshots[provider],
                let window = Self.sparklineWindow(in: snapshot)
            else {
                updated[provider] = nil
                continue
            }

            let samples = await history.series(for: provider, window: window.kind, since: since)
            updated[provider] = SparklineData(
                windowLabel: window.label,
                samples: samples
            )
        }

        sparklines = updated
    }

    /// The window a card's trail is drawn from: the longest horizon it has, weekly first.
    ///
    /// The axis is seven days, so a five-hour window would draw roughly thirty sawtooth
    /// cycles across it and become the loudest thing in the card. Weekly (or monthly) shares
    /// the axis's timescale and yields one readable slope.
    private static let sparklineWindowPreference: [LimitWindow.Kind] = [
        .weekly7d, .weeklyScoped, .monthly, .rolling, .session5h, .credits,
    ]

    private static func sparklineWindow(in snapshot: UsageSnapshot) -> LimitWindow? {
        for kind in sparklineWindowPreference {
            // Amount rows (USD credits) have no fraction, so a line would be flat fiction.
            if let window = snapshot.window(kind: kind), !UsageFormat.isAmountRow(window) {
                return window
            }
        }
        guard let first = snapshot.primaryWindow, !UsageFormat.isAmountRow(first) else { return nil }
        return first
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
    static let readmePolicy = URL(
        string: "https://github.com/ies0411/Fillline#unofficial-and-what-that-means")!
}
