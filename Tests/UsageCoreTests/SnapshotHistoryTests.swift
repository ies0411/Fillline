import Foundation
import Testing
import UsageCore

/// Snapshot history for sparklines (issue #7). Every test uses its own throwaway directory:
/// the default directory is `~/Library/Application Support/Fillline`, which a unit test must
/// never touch.
@Suite("Snapshot history")
struct SnapshotHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_572_000)

    // MARK: - Factories

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FilllineHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func window(
        _ kind: LimitWindow.Kind = .session5h,
        usedFraction: Double,
        at capturedAt: Date,
        isEstimated: Bool = false,
        isPlaceholder: Bool = false
    ) -> LimitWindow {
        LimitWindow(
            id: "test.\(kind.rawValue)",
            kind: kind,
            label: "Test window",
            usedFraction: usedFraction,
            resetsAt: nil,
            isEstimated: isEstimated,
            isPlaceholder: isPlaceholder,
            capturedAt: capturedAt
        )
    }

    private func snapshot(
        provider: ProviderID = .claudeCode,
        status: ProviderStatus = .ok,
        at capturedAt: Date,
        windows: [LimitWindow]
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            plan: "Max",
            windows: windows,
            source: .api,
            status: status,
            capturedAt: capturedAt
        )
    }

    private func history(
        in directory: URL,
        retention: TimeInterval = 7 * 24 * 3600,
        maxSamplesPerSeries: Int = 720
    ) -> SnapshotHistory {
        SnapshotHistory(
            directory: directory,
            retention: retention,
            maxSamplesPerSeries: maxSamplesPerSeries
        )
    }

    // MARK: - Round trip

    @Test("record then read returns the recorded points")
    func recordThenRead() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        let added = await store.record(
            snapshot(
                at: t0,
                windows: [
                    window(.session5h, usedFraction: 0.25, at: t0),
                    window(.weekly7d, usedFraction: 0.8, at: t0),
                ])
        )
        #expect(added == 2)

        let session = await store.series(for: .claudeCode, window: .session5h, since: .distantPast)
        let sample = try #require(session.first)
        #expect(session.count == 1)
        #expect(sample.capturedAt == t0)
        #expect(sample.usedFraction == 0.25)
        #expect(sample.remainingFraction == 0.75)
        #expect(sample.remainingPercent == 75)
        #expect(sample.windowKind == .session5h)
        #expect(sample.provider == .claudeCode)

        let weekly = await store.series(for: .claudeCode, window: .weekly7d, since: .distantPast)
        #expect(weekly.map(\.usedFraction) == [0.8])
    }

    @Test("series is sorted ascending even when samples arrive out of order")
    func ascendingOrder() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        for offset in [120.0, 0.0, 60.0] {
            let at = t0.addingTimeInterval(offset)
            await store.record(snapshot(at: at, windows: [window(usedFraction: 0.1, at: at)]))
        }

        let samples = await store.series(for: .claudeCode, window: .session5h, since: .distantPast)
        #expect(samples.map(\.capturedAt) == [t0, t0.addingTimeInterval(60), t0.addingTimeInterval(120)])
    }

    @Test("since filters out older samples")
    func sinceFilter() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        for offset in [0.0, 60.0, 120.0] {
            let at = t0.addingTimeInterval(offset)
            await store.record(snapshot(at: at, windows: [window(usedFraction: 0.1, at: at)]))
        }

        let recent = await store.series(
            for: .claudeCode,
            window: .session5h,
            since: t0.addingTimeInterval(60)
        )
        #expect(recent.count == 2)
        #expect(recent.first?.capturedAt == t0.addingTimeInterval(60))

        let future = await store.series(
            for: .claudeCode,
            window: .session5h,
            since: t0.addingTimeInterval(600)
        )
        #expect(future.isEmpty)
    }

    // MARK: - Filters

    @Test("estimated and placeholder windows are never recorded")
    func estimatesAndPlaceholdersSkipped() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        await store.record(
            snapshot(
                at: t0,
                windows: [
                    window(.session5h, usedFraction: 0.2, at: t0),
                    window(.weekly7d, usedFraction: 0.3, at: t0, isEstimated: true),
                    window(.monthly, usedFraction: 0.4, at: t0, isPlaceholder: true),
                ])
        )

        #expect(await store.sampleCount == 1)
        #expect(await store.series(for: .claudeCode, window: .weekly7d, since: .distantPast).isEmpty)
        #expect(await store.series(for: .claudeCode, window: .monthly, since: .distantPast).isEmpty)
        #expect(await store.series(for: .claudeCode, window: .session5h, since: .distantPast).count == 1)
    }

    @Test("snapshots with a failure status contribute nothing")
    func failureStatusSkipped() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        let statuses: [ProviderStatus] = [
            .needsLogin,
            .notSubscribed,
            .notInstalled,
            .rateLimited(retryAfter: 30),
            .unsupported,
            .error("http-500"),
        ]

        for (index, status) in statuses.enumerated() {
            let at = t0.addingTimeInterval(Double(index) * 60)
            let added = await store.record(
                snapshot(status: status, at: at, windows: [window(usedFraction: 0.5, at: at)])
            )
            #expect(added == 0)
        }

        #expect(await store.sampleCount == 0)
    }

    @Test("a snapshot without windows is not recorded")
    func emptySnapshotSkipped() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        await store.record(snapshot(at: t0, windows: []))
        #expect(await store.sampleCount == 0)
    }

    @Test("the same capturedAt cannot be recorded twice")
    func duplicateCapturedAtRejected() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        await store.record(snapshot(at: t0, windows: [window(usedFraction: 0.1, at: t0)]))
        // Replay with a different value but the same timestamp: the first point stands.
        let added = await store.record(snapshot(at: t0, windows: [window(usedFraction: 0.9, at: t0)]))
        #expect(added == 0)

        let samples = await store.series(for: .claudeCode, window: .session5h, since: .distantPast)
        #expect(samples.count == 1)
        #expect(samples.first?.usedFraction == 0.1)
    }

    // MARK: - Bounds

    @Test("samples older than the retention window are pruned")
    func retentionPruning() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory, retention: 3600)

        let now = Date()
        let old = now.addingTimeInterval(-7200)
        // Two hours old with a one-hour retention: dropped on write, not on the next launch.
        await store.record(snapshot(at: old, windows: [window(usedFraction: 0.1, at: old)]))
        #expect(await store.sampleCount == 0)

        let recent = now.addingTimeInterval(-1800)
        await store.record(snapshot(at: recent, windows: [window(usedFraction: 0.2, at: recent)]))
        #expect(await store.sampleCount == 1)

        // Pruning also happens on load, so old points never come back from disk.
        let reopened = history(in: directory, retention: 3600)
        #expect(await reopened.sampleCount == 1)
    }

    @Test("each series is capped, keeping the newest samples")
    func perSeriesCap() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory, maxSamplesPerSeries: 5)

        for index in 0..<8 {
            let at = t0.addingTimeInterval(Double(index) * 60)
            await store.record(snapshot(at: at, windows: [window(usedFraction: Double(index) / 10, at: at)]))
        }

        let samples = await store.series(for: .claudeCode, window: .session5h, since: .distantPast)
        #expect(samples.count == 5)
        #expect(samples.map(\.capturedAt) == (3..<8).map { t0.addingTimeInterval(Double($0) * 60) })
        #expect(samples.last?.usedFraction == 0.7)
        #expect(await store.sampleCount == 5)

        // The cap is enforced on disk too, so a relaunch cannot resurrect the dropped points.
        let reopened = history(in: directory, maxSamplesPerSeries: 5)
        #expect(await reopened.series(for: .claudeCode, window: .session5h, since: .distantPast).count == 5)
    }

    // MARK: - Persistence and damage control

    @Test("history survives re-instantiation over the same directory")
    func persistenceAcrossInstances() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = history(in: directory)
        for offset in [0.0, 60.0] {
            let at = t0.addingTimeInterval(offset)
            await first.record(
                snapshot(
                    at: at,
                    windows: [
                        window(.session5h, usedFraction: 0.2, at: at),
                        window(.weekly7d, usedFraction: 0.6, at: at),
                    ])
            )
        }

        let second = history(in: directory)
        #expect(await second.sampleCount == 4)
        let session = await second.series(for: .claudeCode, window: .session5h, since: .distantPast)
        #expect(session.map(\.capturedAt) == [t0, t0.addingTimeInterval(60)])
        #expect(session.map(\.usedFraction) == [0.2, 0.2])
        #expect(await second.series(for: .claudeCode, window: .weekly7d, since: .distantPast).count == 2)
    }

    @Test("a corrupt file yields empty history instead of throwing")
    func corruptFileTolerated() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8)
            .write(to: directory.appendingPathComponent("history.json"))

        let store = history(in: directory)
        #expect(await store.sampleCount == 0)
        #expect(await store.series(for: .claudeCode, window: .session5h, since: .distantPast).isEmpty)

        // Recording still works and replaces the broken file with valid JSON.
        await store.record(snapshot(at: t0, windows: [window(usedFraction: 0.4, at: t0)]))
        #expect(await store.sampleCount == 1)
        #expect(await history(in: directory).sampleCount == 1)
    }

    @Test("unknown providers and window kinds in the file are ignored")
    func unknownSeriesTolerated() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
            {
              "version": 1,
              "series": [
                {
                  "provider": "some-future-cli",
                  "windowKind": "session-5h",
                  "samples": [{ "capturedAt": 1792572000, "usedFraction": 0.5 }]
                },
                {
                  "provider": "claude-code",
                  "windowKind": "semester",
                  "samples": [{ "capturedAt": 1792572000, "usedFraction": 0.5 }]
                }
              ]
            }
            """
        try Data(json.utf8).write(to: directory.appendingPathComponent("history.json"))

        let store = history(in: directory)
        #expect(await store.sampleCount == 0)
    }

    @Test("clear removes both memory and the file")
    func clearRemovesEverything() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        let historyFile = directory.appendingPathComponent("history.json")
        await store.record(snapshot(at: t0, windows: [window(usedFraction: 0.3, at: t0)]))
        #expect(FileManager.default.fileExists(atPath: historyFile.path))

        try await store.clear()
        #expect(await store.sampleCount == 0)
        #expect(!FileManager.default.fileExists(atPath: historyFile.path))
        #expect(await history(in: directory).sampleCount == 0)
    }

    @Test("recording leaves exactly one file behind, with no temp files")
    func atomicWriteLeavesNoTempFiles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        for offset in [0.0, 60.0, 120.0] {
            let at = t0.addingTimeInterval(offset)
            await store.record(snapshot(at: at, windows: [window(usedFraction: 0.1, at: at)]))
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents == ["history.json"])
    }

    // MARK: - Format

    @Test("Codable shape is stable and preserves sub-second timestamps")
    func codableShape() async throws {
        let capturedAt = Date(timeIntervalSince1970: 1_792_572_000.123)
        let sample = HistorySample(
            capturedAt: capturedAt,
            usedFraction: 0.35,
            windowKind: .weekly7d,
            provider: .openCodeGo
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["capturedAt", "usedFraction", "windowKind", "provider"])
        #expect(object["capturedAt"] is NSNumber)
        #expect(object["windowKind"] as? String == "weekly-7d")
        #expect(object["provider"] as? String == "opencode-go")

        let decoded = try JSONDecoder().decode(HistorySample.self, from: data)
        #expect(decoded == sample)
        // Sub-second precision survives, so two polls in the same second stay distinct points.
        #expect(decoded.capturedAt == capturedAt)
    }

    @Test("on-disk payload shape is versioned and self-describing")
    func filePayloadShape() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = history(in: directory)

        await store.record(
            snapshot(at: t0, windows: [window(.session5h, usedFraction: 0.5, at: t0)])
        )

        let data = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["version"] as? Int == 1)

        let series = try #require(payload["series"] as? [[String: Any]])
        let entry = try #require(series.first)
        #expect(Set(entry.keys) == ["provider", "windowKind", "samples"])
        #expect(entry["provider"] as? String == "claude-code")
        #expect(entry["windowKind"] as? String == "session-5h")

        let stored = try #require(entry["samples"] as? [[String: Any]])
        #expect(stored.count == 1)
        let storedSample = try #require(stored.first)
        #expect(Set(storedSample.keys) == ["capturedAt", "usedFraction"])
    }
}
