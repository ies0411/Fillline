import Foundation

/// Where the numbers in a snapshot came from. Shown in the UI so an estimate is never
/// mistaken for an authoritative server value (AGENTS §9).
public enum Source: String, Codable, Sendable, Hashable, CaseIterable {
    /// Live provider endpoint.
    case api
    /// Aggregated from local CLI logs.
    case localLogs = "local-logs"
    /// Last successful value restored from disk because the network call failed.
    case cache

    public var displayLabel: String {
        switch self {
        case .api: "api"
        case .localLogs: "local logs"
        case .cache: "cached"
        }
    }
}
