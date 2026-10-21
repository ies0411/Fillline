import Foundation

/// Per-provider polling state machine. The only place where polling state transitions
/// happen (AGENTS §3), which keeps SwiftUI views dumb and testable.
///
/// Guarantees:
/// - independent schedule per provider; one provider failing never delays another;
/// - minimum interval of 60 seconds (configurable higher, e.g. 180s for Claude);
/// - exponential backoff 60s → 2m → 5m → 15m → 30m, honoring `Retry-After`;
/// - last-good values are retained when a refresh fails, with the original `capturedAt`
///   so the UI can show an honest age instead of inventing 0%.
public actor PollScheduler {
    public struct Configuration: Sendable, Hashable {
        public var baseInterval: TimeInterval
        public var retryPolicy: RetryPolicy
        /// Age at which an `ok` snapshot is presented as `.stale(age:)`.
        public var staleAfter: TimeInterval
        /// Per-provider floor. Claude's endpoint is rate-limit sensitive (AGENTS §2: 180s).
        public var minimumIntervalOverrides: [ProviderID: TimeInterval]

        public init(
            baseInterval: TimeInterval = RetryPolicy.minimumInterval,
            retryPolicy: RetryPolicy = RetryPolicy(),
            staleAfter: TimeInterval = 180,
            minimumIntervalOverrides: [ProviderID: TimeInterval] = [:]
        ) {
            self.baseInterval = max(baseInterval, RetryPolicy.minimumInterval)
            self.retryPolicy = retryPolicy
            self.staleAfter = max(staleAfter, 0)
            self.minimumIntervalOverrides = minimumIntervalOverrides
        }

        /// Effective success interval for a provider, never below 60s.
        public func interval(for provider: ProviderID) -> TimeInterval {
            max(minimumIntervalOverrides[provider] ?? baseInterval, RetryPolicy.minimumInterval)
        }
    }

    public struct ProviderState: Sendable {
        public let provider: ProviderID
        /// Snapshot currently shown to the UI (failure status + last-good windows).
        public var snapshot: UsageSnapshot
        /// Most recent snapshot whose status was `.ok`.
        public var lastSuccessfulSnapshot: UsageSnapshot?
        public var consecutiveFailures: Int
        public var nextPollAt: Date
        public var lastAttemptAt: Date
    }

    private let providers: [any UsageProvider]
    private let configuration: Configuration
    private let clock: @Sendable () -> Date

    private var states: [ProviderID: ProviderState] = [:]
    private var inFlight: Set<ProviderID> = []

    public init(
        providers: [any UsageProvider],
        configuration: Configuration = Configuration(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = providers
        self.configuration = configuration
        self.clock = clock
    }

    public var providerIDs: [ProviderID] {
        providers.map(\.id)
    }

    public func state(for provider: ProviderID) -> ProviderState? {
        states[provider]
    }

    public func snapshot(for provider: ProviderID) -> UsageSnapshot? {
        states[provider]?.snapshot
    }

    public func snapshots() -> [ProviderID: UsageSnapshot] {
        states.mapValues(\.snapshot)
    }

    /// Snapshots as the popover should render them right now: `ok` values older than
    /// `staleAfter` become `.stale(age:)`.
    public func agedSnapshots(now: Date? = nil) -> [ProviderID: UsageSnapshot] {
        let date = now ?? clock()
        return states.mapValues { $0.snapshot.aged(now: date, staleAfter: configuration.staleAfter) }
    }

    public func nextPollDate(for provider: ProviderID) -> Date? {
        states[provider]?.nextPollAt
    }

    public func isDue(_ provider: ProviderID, at date: Date? = nil) -> Bool {
        let now = date ?? clock()
        guard let nextPollAt = states[provider]?.nextPollAt else { return true }
        return now >= nextPollAt
    }

    /// Polls one provider. Returns the effective snapshot (last-good windows + current
    /// status) or `nil` for an unknown provider.
    ///
    /// When the provider is still cooling down this returns the current snapshot without
    /// touching the network. Pass `force: true` for the user-initiated refresh button.
    @discardableResult
    public func poll(_ providerID: ProviderID, force: Bool = false) async -> UsageSnapshot? {
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            return nil
        }

        let now = clock()

        if !force, let state = states[providerID], now < state.nextPollAt {
            return state.snapshot
        }
        if inFlight.contains(providerID) {
            return states[providerID]?.snapshot
        }

        inFlight.insert(providerID)
        defer { inFlight.remove(providerID) }

        let result = await provider.fetch(now: now)
        return apply(result, at: now)
    }

    /// Polls every provider that is due, sequentially. Provider failures are contained in
    /// their own snapshots.
    @discardableResult
    public func pollAll(force: Bool = false) async -> [UsageSnapshot] {
        var results: [UsageSnapshot] = []
        results.reserveCapacity(providers.count)
        for provider in providers {
            if let snapshot = await poll(provider.id, force: force) {
                results.append(snapshot)
            }
        }
        return results
    }

    // MARK: - State transitions

    private func apply(_ result: UsageSnapshot, at now: Date) -> UsageSnapshot {
        let previous = states[result.provider]
        var failures = previous?.consecutiveFailures ?? 0
        var lastGood = previous?.lastSuccessfulSnapshot
        var effective = result

        if result.status.isSuccess {
            failures = 0
            lastGood = result
        } else {
            failures += 1
            if let lastGood {
                // Keep the numbers, swap only the status. `capturedAt` stays old on purpose.
                effective = lastGood.replacing(status: result.status)
            }
        }

        let delay = nextDelay(for: result.status, failures: failures, provider: result.provider)
        states[result.provider] = ProviderState(
            provider: result.provider,
            snapshot: effective,
            lastSuccessfulSnapshot: lastGood,
            consecutiveFailures: failures,
            nextPollAt: now.addingTimeInterval(delay),
            lastAttemptAt: now
        )
        return effective
    }

    private func nextDelay(for status: ProviderStatus, failures: Int, provider: ProviderID) -> TimeInterval {
        switch status {
        case .ok:
            return configuration.interval(for: provider)
        case .rateLimited(let retryAfter):
            return configuration.retryPolicy.delay(failureCount: failures, retryAfter: retryAfter)
        case .error, .stale:
            return configuration.retryPolicy.delay(failureCount: failures)
        case .needsLogin, .notSubscribed, .notInstalled, .unsupported:
            // Retrying cannot fix credentials; back off fully instead of hammering.
            return configuration.retryPolicy.maximumInterval
        }
    }
}
