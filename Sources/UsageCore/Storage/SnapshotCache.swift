import Darwin
import Foundation

/// On-disk snapshot cache. Actor-isolated so concurrent saves cannot interleave.
///
/// Writes are atomic: encode → write a sibling temp file → `rename(2)`. A crash therefore
/// leaves either the old complete file or the new complete file, never a partial JSON
/// document (AGENTS §11 reference: Maciek-roboblog monitor used the same pattern).
public actor SnapshotCache {
    public nonisolated let directory: URL

    private let fileURL: URL
    private let fileName = "snapshots.json"

    public init(directory: URL = SnapshotCache.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// `~/Library/Application Support/UsageApp` (AGENTS §3).
    public static var defaultDirectory: URL {
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent("UsageApp", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageApp", isDirectory: true)
    }

    /// Non-throwing by design: a corrupt or missing cache must never block startup.
    public func load() -> [ProviderID: UsageSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode([String: UsageSnapshot].self, from: data) else {
            return [:]
        }

        var snapshots: [ProviderID: UsageSnapshot] = [:]
        for (key, snapshot) in raw {
            if let provider = ProviderID(rawValue: key) {
                snapshots[provider] = snapshot
            }
        }
        return snapshots
    }

    public func snapshot(for provider: ProviderID) -> UsageSnapshot? {
        load()[provider]
    }

    public func save(_ snapshot: UsageSnapshot) throws {
        var snapshots = load()
        snapshots[snapshot.provider] = snapshot
        try save(snapshots)
    }

    public func save(_ snapshots: [ProviderID: UsageSnapshot]) throws {
        let payload = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)

        try writeAtomically(data)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Atomic write

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
}
