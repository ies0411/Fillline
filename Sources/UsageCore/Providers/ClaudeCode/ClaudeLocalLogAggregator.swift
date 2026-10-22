import Foundation

/// Token totals recovered from the JSONL transcripts Claude Code already writes.
///
/// Why this exists (issue #16, AGENTS §2): the Claude card should say something without reading
/// the user's OAuth token. Local logs contain **no plan limit**, so this strategy can only report
/// how many tokens were used — never a remaining percentage. Every window it produces is an
/// amount row (a token quantity in the label, `usedFraction` left at the model's "no fraction"
/// value) and is flagged `isEstimated` so no percent surface, sparkline or alert picks it up.
///
/// Read-only by construction: the directory is enumerated and files are opened with
/// `FileHandle(forReadingFrom:)`. Nothing under `~/.claude` is created, written or moved, no
/// Keychain item is read and no network request is made.
///
/// Incremental: each file remembers `(offset, size, mtime)`, so a poll parses only the appended
/// bytes. A truncated or rewritten file resets that file's offset and records.
public actor ClaudeLocalLogAggregator {
    /// Rolling window used for the short total, matching Claude's 5-hour session.
    public static let fiveHourWindow: TimeInterval = 5 * 60 * 60
    /// Horizon used for the weekly total.
    public static let sevenDayWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Aggregated token counts. No fraction, no percentage, no plan limit — by design.
    public struct Totals: Sendable, Equatable {
        public let fiveHourTokens: Int
        public let sevenDayTokens: Int
        /// Unique assistant turns inside the seven-day window that fed the totals.
        public let requestsConsidered: Int
        /// Lines that looked like assistant records but could not be parsed (crash-truncated
        /// writes, schema drift). Deliberately absent from every piece of UI copy.
        public let skippedLines: Int
        /// Newest sample that contributed, or `nil` when nothing did.
        public let newestSampleAt: Date?

        /// `false` when there was nothing to count: missing directory, no logs, or no assistant
        /// records. The provider maps this onto `.unsupported`, never onto `0`.
        public var hasUsableData: Bool { requestsConsidered > 0 }
    }

    /// `~/.claude/projects`, where Claude Code stores `<project-slug>/<session-uuid>.jsonl`.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Cheap pre-filter: only `assistant` records carry `message.usage`, and a real projects/
    /// tree is mostly `user` / `attachment` / `api-request-blob` lines.
    private static let assistantMarker = Data("\"assistant\"".utf8)

    private struct Record: Sendable {
        let timestamp: Date
        let requestID: String?
        let tokens: Int64
    }

    private struct FileState {
        /// Bytes consumed, always at a line boundary.
        var offset: Int
        /// File size observed at the last read, for truncation/rewrite detection.
        var size: Int
        var modificationDate: Date?
        /// Retained records, pruned to the seven-day horizon.
        var records: [Record]
    }

    private struct ParsedChunk {
        var consumed = 0
        var records: [Record] = []
        var skipped = 0
    }

    private let directory: URL
    private let clock: @Sendable () -> Date
    private let decoder = JSONDecoder()

    private var files: [String: FileState] = [:]
    /// Cumulative malformed-line count; exposed only through `Totals` and a debug accessor.
    private var skippedLines = 0

    /// Clock injection follows `PollScheduler(clock:)`: a plain `@Sendable () -> Date`.
    public init(
        directory: URL = ClaudeLocalLogAggregator.defaultDirectory,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.clock = clock
    }

    /// Convenience for callers that do not need to pin the window edge.
    public func totals() async -> Totals {
        await totals(now: clock())
    }

    /// Totals for the two windows ending at `now`.
    ///
    /// - Parameters:
    ///   - now: right edge of both windows. Records newer than `now` are ignored (clock skew),
    ///     and a record exactly on a boundary counts.
    public func totals(now: Date) async -> Totals {
        var seenPaths = Set<String>()
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]

        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                // Symlinks are skipped rather than followed: the aggregator must never be
                // redirected somewhere else on the filesystem by a planted link.
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                    values.isRegularFile == true,
                    values.isSymbolicLink != true,
                    let size = values.fileSize
                else { continue }

                seenPaths.insert(url.path)
                ingest(url: url, size: size, modified: values.contentModificationDate, now: now)
            }
        }

        // A session file that disappeared must stop contributing.
        files = files.filter { seenPaths.contains($0.key) }
        return aggregate(now: now)
    }

    // MARK: - Reading

    private func ingest(url: URL, size: Int, modified: Date?, now: Date) {
        let path = url.path
        var state = files[path] ?? FileState(offset: 0, size: 0, modificationDate: nil, records: [])

        // Truncated or rewritten in place: the remembered offsets describe bytes that no longer
        // exist. An append always grows the file, so an mtime change without a size change can
        // only be an in-place rewrite.
        let rewritten =
            size < state.size
            || (size == state.size && state.size > 0 && modified != state.modificationDate)
        if rewritten {
            state = FileState(offset: 0, size: 0, modificationDate: nil, records: [])
        }

        guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else {
            files[path] = state
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(state.offset))
            guard let chunk = try handle.read(upToCount: size - state.offset), !chunk.isEmpty else {
                files[path] = state
                return
            }
            let parsed = parse(chunk)
            state.offset += parsed.consumed
            state.size = size
            state.modificationDate = modified
            state.records.append(contentsOf: parsed.records)
            skippedLines += parsed.skipped
        } catch {
            // An unreadable file contributes nothing. Never invent a number to cover for it.
        }

        let cutoff = now.addingTimeInterval(-Self.sevenDayWindow)
        state.records.removeAll { $0.timestamp < cutoff }
        files[path] = state
    }

    private func parse(_ chunk: Data) -> ParsedChunk {
        var parsed = ParsedChunk()
        var cursor = chunk.startIndex

        while cursor < chunk.endIndex {
            // Only newline-terminated lines are consumed. A crash can leave a partial tail, and
            // re-reading it after the next append is what lets the file heal itself.
            guard let newline = chunk[cursor...].firstIndex(of: 0x0A) else { break }
            let line = chunk[cursor..<newline]
            parsed.consumed += chunk.distance(from: cursor, to: newline) + 1
            cursor = chunk.index(after: newline)

            switch classify(line) {
            case .record(let record): parsed.records.append(record)
            case .skipped: parsed.skipped += 1
            case .ignored: break
            }
        }

        return parsed
    }

    private enum Classification {
        case record(Record)
        case skipped
        case ignored
    }

    private func classify(_ line: Data) -> Classification {
        guard !line.isEmpty else { return .ignored }
        guard line.range(of: Self.assistantMarker) != nil else { return .ignored }
        guard let entry = try? decoder.decode(LogEntry.self, from: line) else { return .skipped }
        guard entry.type == "assistant", let usage = entry.message?.usage else { return .ignored }
        guard let raw = entry.timestamp, let timestamp = ProviderSupport.iso8601Date(from: raw)
        else { return .skipped }

        return .record(
            Record(timestamp: timestamp, requestID: entry.requestID, tokens: usage.tokenTotal)
        )
    }

    // MARK: - Windowing

    private func aggregate(now: Date) -> Totals {
        let fiveHourCutoff = now.addingTimeInterval(-Self.fiveHourWindow)
        let sevenDayCutoff = now.addingTimeInterval(-Self.sevenDayWindow)

        var records: [Record] = []
        for state in files.values {
            records.append(contentsOf: state.records)
        }
        // Window membership is decided by `timestamp`, never by file order or record order.
        records.sort { $0.timestamp < $1.timestamp }

        var seenRequests = Set<String>()
        var fiveHour: Int64 = 0
        var sevenDay: Int64 = 0
        var considered = 0
        var newest: Date?

        for record in records {
            // Both windows are closed on the left: a record exactly on the boundary counts.
            guard record.timestamp >= sevenDayCutoff, record.timestamp <= now else { continue }

            if let requestID = record.requestID {
                // The same assistant turn can be written more than once; count it once, using
                // the earliest copy (the list is sorted).
                guard seenRequests.insert(requestID).inserted else { continue }
            }

            sevenDay += record.tokens
            if record.timestamp >= fiveHourCutoff {
                fiveHour += record.tokens
            }
            considered += 1
            if newest.map({ record.timestamp > $0 }) ?? true {
                newest = record.timestamp
            }
        }

        return Totals(
            fiveHourTokens: Int(clamping: fiveHour),
            sevenDayTokens: Int(clamping: sevenDay),
            requestsConsidered: considered,
            skippedLines: skippedLines,
            newestSampleAt: newest
        )
    }

    // MARK: - Debug

    #if DEBUG
        /// Malformed lines skipped since launch. Debug builds only: never rendered in UI copy,
        /// so a truncated write is not surfaced to the user as a number that "looks wrong".
        public var debugSkippedLines: Int { skippedLines }
    #endif

    // MARK: - Wire shape

    /// One transcript line. Everything is optional: the format is an implementation detail of
    /// Claude Code, and a missing field must degrade a single line, not the whole scan.
    private struct LogEntry: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let inputTokens: Int?
                let outputTokens: Int?
                let cacheCreationInputTokens: Int?
                let cacheReadInputTokens: Int?

                private enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case outputTokens = "output_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                }

                /// `input + output + cache_creation + cache_read`. Cache reads dominate real
                /// sessions, so hiding them would understate usage (docs/providers/claude-code.md).
                var tokenTotal: Int64 {
                    Int64(max(0, inputTokens ?? 0))
                        + Int64(max(0, outputTokens ?? 0))
                        + Int64(max(0, cacheCreationInputTokens ?? 0))
                        + Int64(max(0, cacheReadInputTokens ?? 0))
                }
            }

            let usage: Usage?
        }

        let type: String?
        let timestamp: String?
        let requestID: String?
        let message: Message?

        private enum CodingKeys: String, CodingKey {
            case type
            case timestamp
            case message
            case requestID = "requestId"
        }
    }
}
