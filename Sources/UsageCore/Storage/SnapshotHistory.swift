import Darwin
import Foundation

/// One point in a provider/window time series. This is the sparkline datum (issue #7):
/// `remainingFraction` is the plotted value, `capturedAt` the x axis.
///
/// Storage is deliberately flat (no `LimitWindow`): a sparkline only needs the used fraction,
/// and keeping windows out of the history keeps the file small and the format stable even if
/// unrelated window metadata changes.
public struct HistorySample: Codable, Sendable, Equatable {
    /// When the provider reported this value. Identical to `LimitWindow.capturedAt`, so a
    /// snapshot replayed with the same timestamp cannot add a second point.
    public let capturedAt: Date
    /// Used fraction, clamped to `0...1` (same unit as `LimitWindow.usedFraction`).
    public let usedFraction: Double
    public let windowKind: LimitWindow.Kind
    public let provider: ProviderID

    public init(
        capturedAt: Date,
        usedFraction: Double,
        windowKind: LimitWindow.Kind,
        provider: ProviderID
    ) {
        self.capturedAt = capturedAt
        self.usedFraction = usedFraction.clampedToUnitInterval
        self.windowKind = windowKind
        self.provider = provider
    }

    /// Remaining fraction, the value the product actually plots (AGENTS §3).
    public var remainingFraction: Double {
        (1 - usedFraction).clampedToUnitInterval
    }

    public var remainingPercent: Double { remainingFraction * 100 }
}

// MARK: - Codable

/// Explicit coding keeps the on-disk representation stable and order-independent of compiler
/// synthesis. `capturedAt` is stored as seconds since 1970 because the ISO-8601 strategies are
/// second-granular and would make two samples from the same second compare equal.
/// The shape is the one `SeriesStorage` writes, so a `HistorySample` can be encoded/decoded
/// on its own in tests and fixtures.
extension HistorySample {
    private enum CodingKeys: String, CodingKey {
        case capturedAt
        case usedFraction
        case windowKind
        case provider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let seconds = try container.decode(Double.self, forKey: .capturedAt)
        self.init(
            capturedAt: Date(timeIntervalSince1970: seconds),
            usedFraction: try container.decode(Double.self, forKey: .usedFraction),
            windowKind: try container.decode(LimitWindow.Kind.self, forKey: .windowKind),
            provider: try container.decode(ProviderID.self, forKey: .provider)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capturedAt.timeIntervalSince1970, forKey: .capturedAt)
        try container.encode(usedFraction, forKey: .usedFraction)
        try container.encode(windowKind, forKey: .windowKind)
        try container.encode(provider, forKey: .provider)
    }
}

/// Bounded on-disk time series per provider/window, for sparklines and rate-of-change UX.
///
/// Relationship to `SnapshotCache`: the cache holds *one* snapshot per provider (what to show
/// right now); this actor holds the *trail* behind it. Both write atomically
/// (encode → sibling temp file → `rename(2)`) and both tolerate a missing or corrupt file.
///
/// Guarantees (issue #7):
/// - Only trustworthy values are recorded: no empty window list, no failure status, no
///   `isEstimated` / `isPlaceholder` windows (an estimate must never look like a measurement).
/// - No duplicate points: one sample per provider/window/`capturedAt`.
/// - Bounded: `retention` seconds of history and at most `maxSamplesPerSeries` points per
///   series, newest kept — in memory and on disk.
public actor SnapshotHistory {
    public nonisolated let directory: URL
    /// How far back samples are kept, in seconds. `<= 0` disables pruning.
    public nonisolated let retention: TimeInterval
    /// Hard cap per provider/window series. `<= 0` records nothing.
    public nonisolated let maxSamplesPerSeries: Int

    private let fileURL: URL
    private let fileName = "history.json"

    /// Sorted ascending by `capturedAt`, at most `maxSamplesPerSeries` entries.
    private var storage: [SeriesKey: [HistorySample]] = [:]
    private var isLoaded = false

    public init(
        directory: URL = SnapshotHistory.defaultDirectory,
        retention: TimeInterval = 7 * 24 * 3600,
        maxSamplesPerSeries: Int = 720
    ) {
        self.directory = directory
        self.retention = retention
        self.maxSamplesPerSeries = maxSamplesPerSeries
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// `~/Library/Application Support/Fillline`, the same directory `SnapshotCache` uses (AGENTS §3).
    public static var defaultDirectory: URL { SnapshotCache.defaultDirectory }

    // MARK: - Reading

    /// Forgets the in-memory copy and re-reads the file. Non-throwing by design: a corrupt or
    /// absent history must never block startup (same contract as `SnapshotCache.load`).
    public func load() {
        isLoaded = false
        ensureLoaded()
    }

    /// Samples for one series, ascending by `capturedAt`, limited to `capturedAt >= since`.
    public func series(for provider: ProviderID, window: LimitWindow.Kind, since: Date) -> [HistorySample] {
        ensureLoaded()
        guard let samples = storage[SeriesKey(provider: provider, windowKind: window)] else {
            return []
        }
        return samples.filter { $0.capturedAt >= since }
    }

    /// Total samples held in memory across all series. Used by tests to pin the cap.
    public var sampleCount: Int {
        ensureLoaded()
        return storage.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Writing

    /// Appends one sample per qualifying window of `snapshot` and persists best-effort.
    ///
    /// Called on every poll, so it never throws: a full disk or unreadable directory must not
    /// turn a successful provider fetch into a failed one. Returns the number of samples added.
    @discardableResult
    public func record(_ snapshot: UsageSnapshot) -> Int {
        ensureLoaded()

        let now = Date()
        // A failure status means the numbers are either absent or untrustworthy (AGENTS §1 #5).
        guard snapshot.status.hasUsableValues, snapshot.hasValues else {
            prune(now: now)
            return 0
        }

        var added = 0
        for window in snapshot.windows where !window.isEstimated && !window.isPlaceholder {
            let sample = HistorySample(
                capturedAt: snapshot.capturedAt,
                usedFraction: window.usedFraction,
                windowKind: window.kind,
                provider: snapshot.provider
            )
            if append(sample) { added += 1 }
        }

        prune(now: now)
        if added > 0 { persist() }
        return added
    }

    /// Drops every sample and the backing file. Tests only.
    public func clear() throws {
        storage = [:]
        isLoaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - In-memory mutation

    private func append(_ sample: HistorySample) -> Bool {
        guard maxSamplesPerSeries > 0 else { return false }

        let key = SeriesKey(provider: sample.provider, windowKind: sample.windowKind)
        var samples = storage[key] ?? []

        // Same poll observed twice (scheduler retry, relaunch with a cached snapshot) must not
        // widen the series. Exact `Date` equality is intentional: two real polls are seconds apart.
        if samples.contains(where: { $0.capturedAt == sample.capturedAt }) { return false }

        samples.append(sample)
        samples.sort { $0.capturedAt < $1.capturedAt }
        if samples.count > maxSamplesPerSeries {
            samples.removeFirst(samples.count - maxSamplesPerSeries)
        }
        storage[key] = samples
        return true
    }

    private func prune(now: Date) {
        guard retention > 0 else { return }
        let cutoff = now.addingTimeInterval(-retention)

        var pruned: [SeriesKey: [HistorySample]] = [:]
        pruned.reserveCapacity(storage.count)
        for (key, samples) in storage {
            let kept = samples.filter { $0.capturedAt >= cutoff }
            if !kept.isEmpty {
                pruned[key] = kept
            }
        }
        storage = pruned
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        storage = readFromDisk()
        prune(now: Date())
    }

    private func readFromDisk() -> [SeriesKey: [HistorySample]] {
        guard let data = try? Data(contentsOf: fileURL),
            let payload = try? JSONDecoder().decode(StoredHistory.self, from: data)
        else { return [:] }

        var restored: [SeriesKey: [HistorySample]] = [:]
        for entry in payload.series {
            let key = SeriesKey(provider: entry.provider, windowKind: entry.windowKind)
            var samples = entry.samples
                .map {
                    HistorySample(
                        capturedAt: Date(timeIntervalSince1970: $0.capturedAt),
                        usedFraction: $0.usedFraction,
                        windowKind: entry.windowKind,
                        provider: entry.provider
                    )
                }
                .sorted { $0.capturedAt < $1.capturedAt }

            // Re-enforce the invariants even for a hand-edited or legacy file.
            samples = Self.deduplicating(samples)
            if maxSamplesPerSeries <= 0 {
                continue
            }
            if samples.count > maxSamplesPerSeries {
                samples.removeFirst(samples.count - maxSamplesPerSeries)
            }
            guard !samples.isEmpty else { continue }
            restored[key] = samples
        }
        return restored
    }

    private static func deduplicating(_ samples: [HistorySample]) -> [HistorySample] {
        var unique: [HistorySample] = []
        unique.reserveCapacity(samples.count)
        for sample in samples where unique.last?.capturedAt != sample.capturedAt {
            unique.append(sample)
        }
        return unique
    }

    /// Compact JSON (no pretty-printing): this runs on every poll, so bytes and encode time
    /// both matter more than human readability of a derived file.
    private func persist() {
        let series = storage.keys
            .sorted { lhs, rhs in
                if lhs.provider.rawValue != rhs.provider.rawValue {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                return lhs.windowKind.rawValue < rhs.windowKind.rawValue
            }
            .compactMap { key -> StoredSeries? in
                guard let samples = storage[key], !samples.isEmpty else { return nil }
                return StoredSeries(
                    provider: key.provider,
                    windowKind: key.windowKind,
                    samples: samples.map {
                        StoredSample(
                            capturedAt: $0.capturedAt.timeIntervalSince1970,
                            usedFraction: $0.usedFraction
                        )
                    }
                )
            }

        let payload = StoredHistory(version: StoredHistory.currentVersion, series: series)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? writeAtomically(data)
    }

    private func writeAtomically(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let temporaryURL = directory.appendingPathComponent(
            ".\(fileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                let code = errno
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    // MARK: - Storage types

    private struct SeriesKey: Hashable, Sendable {
        let provider: ProviderID
        let windowKind: LimitWindow.Kind
    }

    private struct StoredHistory: Codable {
        static let currentVersion = 1

        /// Informational; the shape is decoded tolerantly so an older or newer numbered file
        /// still yields whatever samples are readable instead of an empty history.
        var version: Int
        var series: [StoredSeries]
    }

    private struct StoredSeries: Codable {
        var provider: ProviderID
        var windowKind: LimitWindow.Kind
        var samples: [StoredSample]
    }

    private struct StoredSample: Codable {
        var capturedAt: Double
        var usedFraction: Double
    }
}
