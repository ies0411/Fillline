import Foundation
import UsageCore

/// Persists delivered alert keys so a threshold is announced once per reset cycle, even
/// across relaunches (issue #4). Stored as a JSON array of strings in `UserDefaults`.
///
/// Entries are pruned after 48 hours: the longest provider window is 7 days, but a
/// 48-hour memory is enough to cover the app being quit and reopened, and it keeps the
/// stored array from growing without bound.
struct NotificationKeyStore {
    static let defaultStorageKey = "notifiedNotificationKeys"
    static let defaultRetention: TimeInterval = 48 * 60 * 60

    private struct Entry {
        let key: NotificationKey
        let firedAt: Date
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let retention: TimeInterval

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = NotificationKeyStore.defaultStorageKey,
        retention: TimeInterval = NotificationKeyStore.defaultRetention
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.retention = retention
    }

    /// Every key still inside the retention window.
    func keys() -> Set<NotificationKey> {
        Set(entries().map(\.key))
    }

    func contains(_ key: NotificationKey) -> Bool {
        entries().contains { $0.key == key }
    }

    /// Records a delivered key and drops expired ones in the same write.
    func insert(_ key: NotificationKey, at date: Date = Date()) {
        var kept = entries(now: date).filter { $0.key != key }
        kept.append(Entry(key: key, firedAt: date))
        save(kept)
    }

    /// Drops entries older than the retention window.
    func prune(now: Date = Date()) {
        save(entries(now: now))
    }

    // MARK: Storage

    /// `"<provider>|<window>|<kind>|<resetEpoch>@<firedAtEpoch>"`.
    private func entries(now: Date = Date()) -> [Entry] {
        guard let stored = defaults.array(forKey: storageKey) as? [String] else { return [] }

        return stored.compactMap { raw -> Entry? in
            let halves = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2,
                  let key = NotificationKey(storageString: String(halves[0])),
                  let firedEpoch = TimeInterval(halves[1])
            else {
                return nil
            }

            let firedAt = Date(timeIntervalSince1970: firedEpoch)
            guard now.timeIntervalSince(firedAt) <= retention else { return nil }
            return Entry(key: key, firedAt: firedAt)
        }
    }

    private func save(_ entries: [Entry]) {
        let encoded = entries.map { entry in
            "\(entry.key.storageString)@\(Int(entry.firedAt.timeIntervalSince1970))"
        }
        defaults.set(encoded, forKey: storageKey)
    }
}
