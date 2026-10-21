import Foundation

/// Parsed `/usage` output from the official `agy` CLI.
///
/// The payload is **observed, not contractual**, so the parser tolerates both camelCase and
/// snake_case keys, three envelope nestings, and a plain-text fallback. Two rules matter:
///
/// 1. `remainingFraction` is **REMAINING**, so `used = 1 − remaining`. Every other provider in
///    this package reports *used*; do not copy their arithmetic here.
/// 2. A missing usage panel is not 0%. Enterprise/Business accounts omit it entirely, which is
///    surfaced as `.unsupported` by the provider rather than a fabricated value.
public struct AntigravityUsageReport: Sendable, Hashable {
    public struct Bucket: Sendable, Hashable {
        public let bucketID: String
        /// Raw group label from the CLI, e.g. `Gemini Models`, `Claude and GPT models`.
        public let groupDisplayName: String
        /// Raw cadence code, e.g. `5h`, `weekly`. Unknown codes are preserved verbatim.
        public let windowCode: String
        public let resetsAt: Date?
        /// `0...1` **REMAINING** fraction, clamped.
        public let remainingFraction: Double

        public init(
            bucketID: String,
            groupDisplayName: String,
            windowCode: String,
            resetsAt: Date?,
            remainingFraction: Double
        ) {
            self.bucketID = bucketID
            self.groupDisplayName = groupDisplayName
            self.windowCode = windowCode
            self.resetsAt = resetsAt
            self.remainingFraction = remainingFraction.clampedToUnitInterval
        }
    }

    public let buckets: [Bucket]
    /// `false` when a recognised usage envelope carried no usage panel at all
    /// (Enterprise/Business). Distinguishes "no data by design" from "could not decode".
    public let panelPresent: Bool
    /// `true` when the numbers were recovered from the plain-text report instead of JSON.
    public let isEstimated: Bool

    public init(buckets: [Bucket], panelPresent: Bool, isEstimated: Bool) {
        self.buckets = buckets
        self.panelPresent = panelPresent
        self.isEstimated = isEstimated
    }
}

// MARK: - Parsing

extension AntigravityUsageReport {
    /// Parses the CLI's stdout. Returns `nil` only when neither the JSON envelope nor the
    /// plain-text report contains anything usable — the caller maps that to `decoding-failed`.
    public static func parse(_ data: Data) -> AntigravityUsageReport? {
        guard !data.isEmpty else { return nil }

        let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        if let root = object as? [String: Any], let report = jsonReport(root) {
            return report
        }
        if let text = textPayload(in: object, data: data), let report = textReport(text) {
            return report
        }
        return nil
    }

    // MARK: JSON

    private static func jsonReport(_ root: [String: Any]) -> AntigravityUsageReport? {
        for container in usageContainers(in: root) {
            guard let groups = groups(in: container) else { continue }
            let buckets = groups.enumerated().flatMap { index, group in
                parseBuckets(in: group, groupIndex: index)
            }
            // An empty `groups` array means the CLI has no panel to show — same user-visible
            // situation as an Enterprise account that omits it.
            return AntigravityUsageReport(
                buckets: buckets,
                panelPresent: !groups.isEmpty,
                isEstimated: false
            )
        }

        // Recognised envelope without a usage panel: Enterprise/Business accounts.
        if isUsageEnvelope(root) {
            return AntigravityUsageReport(buckets: [], panelPresent: false, isEstimated: false)
        }
        return nil
    }

    /// `groups` lives under `command.data`, `data`, or `result` depending on CLI build.
    private static func usageContainers(in root: [String: Any]) -> [[String: Any]] {
        var containers: [[String: Any]] = []

        func append(_ value: Any?) {
            guard let dictionary = value as? [String: Any] else { return }
            containers.append(dictionary)
        }

        if let command = root["command"] as? [String: Any] {
            append(command["data"])
            append(command["result"])
            append(command["usage"])
        }
        append(root["data"])
        append(root["result"])
        append(root["usage"])
        containers.append(root)
        return containers
    }

    private static func groups(in container: [String: Any]) -> [[String: Any]]? {
        for key in ["groups", "usageGroups", "usage_groups", "limits"] {
            if let groups = container[key] as? [[String: Any]] {
                return groups
            }
        }
        return nil
    }

    private static func isUsageEnvelope(_ root: [String: Any]) -> Bool {
        if root["groups"] != nil {
            return true
        }
        if let command = root["command"] as? [String: Any],
            let name = command["name"] as? String,
            name.lowercased().contains("usage")
        {
            return true
        }
        return false
    }

    private static func parseBuckets(in group: [String: Any], groupIndex: Int) -> [Bucket] {
        let displayName =
            string(group, ["displayName", "display_name", "groupName", "group_name", "name"])
            ?? "Usage"
        guard let rawBuckets = (group["buckets"] ?? group["items"] ?? group["windows"]) as? [[String: Any]]
        else {
            return []
        }

        return rawBuckets.enumerated().compactMap { index, raw in
            // Some rows only carry a reset time; there is no number to show for those.
            guard let remaining = remainingFraction(from: raw) else { return nil }

            let bucketID =
                string(raw, ["bucketId", "bucket_id", "id"])
                ?? "\(slug(displayName))-\(groupIndex)-\(index)"
            let windowCode =
                string(raw, ["window", "windowCode", "window_code", "cadence"])
                ?? inferredWindowCode(from: bucketID)
                ?? "unknown"
            return Bucket(
                bucketID: bucketID,
                groupDisplayName: displayName,
                windowCode: windowCode,
                resetsAt: resetDate(in: raw),
                remainingFraction: remaining
            )
        }
    }

    private static func remainingFraction(from bucket: [String: Any]) -> Double? {
        if let value = number(bucket["remainingFraction"] ?? bucket["remaining_fraction"]) {
            // Tolerates a 0–100 payload from a future CLI build.
            return value > 1 ? value / 100 : value
        }
        if let value = number(bucket["remainingPercent"] ?? bucket["remaining_percent"]) {
            return value / 100
        }
        return nil
    }

    private static func resetDate(in bucket: [String: Any]) -> Date? {
        for key in ["resetTime", "reset_time", "resetsAt", "resets_at", "reset"] {
            guard let raw = bucket[key] else { continue }
            if let text = raw as? String, let date = ProviderSupport.iso8601Date(from: text) {
                return date
            }
            if let value = number(raw), value > 0 {
                // Epoch milliseconds are tolerated; the observed form is ISO-8601.
                let seconds = value > 1_000_000_000_000 ? value / 1000 : value
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    private static func inferredWindowCode(from bucketID: String) -> String? {
        let lowered = bucketID.lowercased()
        if lowered.contains("weekly") || lowered.contains("7d") { return "weekly" }
        if lowered.contains("5h") || lowered.contains("session") { return "5h" }
        if lowered.contains("monthly") { return "monthly" }
        return nil
    }

    // MARK: Text fallback

    /// The plain-text report looks like `Gemini Models: 5h 82% left`. Only lines that carry both
    /// a percentage and a "left/remaining" word are accepted, so unrelated output is ignored.
    private static func textReport(_ text: String) -> AntigravityUsageReport? {
        var buckets: [Bucket] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let lowered = line.lowercased()
            guard
                lowered.contains("left")
                    || lowered.contains("remaining")
                    || lowered.contains("available")
            else { continue }
            guard let percent = firstPercent(in: line) else { continue }

            let groupName = groupName(in: line)
            let windowCode = windowCode(in: lowered)
            buckets.append(
                Bucket(
                    bucketID: "text-\(buckets.count)-\(slug(groupName))",
                    groupDisplayName: groupName,
                    windowCode: windowCode,
                    resetsAt: nil,
                    remainingFraction: percent / 100
                )
            )
        }

        guard !buckets.isEmpty else { return nil }
        return AntigravityUsageReport(buckets: buckets, panelPresent: true, isEstimated: true)
    }

    /// Raw text, or a text field inside an otherwise unrecognisable JSON envelope.
    private static func textPayload(in object: Any?, data: Data) -> String? {
        if let text = object as? String { return text }

        if let root = object as? [String: Any] {
            for key in ["result", "output", "text", "stdout", "message"] {
                if let text = root[key] as? String, text.contains("%") { return text }
            }
            if let command = root["command"] as? [String: Any] {
                if let text = command["data"] as? String { return text }
                if let text = command["result"] as? String { return text }
            }
        }
        return String(data: data, encoding: .utf8)
    }

    private static func firstPercent(in line: String) -> Double? {
        var digits = ""
        for character in line {
            if character == "%" {
                if let value = Double(digits), value.isFinite { return value }
                digits = ""
            } else if character.isNumber || character == "." {
                digits.append(character)
            } else {
                digits = ""
            }
        }
        return nil
    }

    private static func groupName(in line: String) -> String {
        var name: String
        if let separator = line.firstIndex(where: { $0 == ":" || $0 == "·" }) {
            name = String(line[..<separator])
        } else {
            // No separator: take the leading words before the first numeric token
            // ("Gemini Models 5h 82% left" → "Gemini Models").
            let words = line.split(separator: " ")
            let leading = words.prefix { !$0.contains(where: { $0.isNumber }) }
            name = leading.joined(separator: " ")
        }

        name = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-*•")))
        guard !name.isEmpty else { return "Usage" }
        return String(name.prefix(40))
    }

    private static func windowCode(in loweredLine: String) -> String {
        if loweredLine.contains("weekly") || loweredLine.contains("week") { return "weekly" }
        if loweredLine.contains("5h") || loweredLine.contains("5-hour") || loweredLine.contains("5 hour") {
            return "5h"
        }
        if loweredLine.contains("monthly") { return "monthly" }
        if loweredLine.contains("daily") || loweredLine.contains("24h") { return "24h" }
        return "unknown"
    }

    // MARK: Key helpers

    private static func string(_ dictionary: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        // `Bool` bridges to `NSNumber` on Darwin; never treat `true` as 1.0.
        if value is Bool { return nil }
        if let double = value as? Double { return double.isFinite ? double : nil }
        if let integer = value as? Int { return Double(integer) }
        if let text = value as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "usage" : collapsed
    }
}
