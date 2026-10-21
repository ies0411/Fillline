import Foundation

/// Where the numbers in a snapshot came from. Shown in the UI so an estimate is never
/// mistaken for an authoritative server value (AGENTS §9).
public enum Source: String, Codable, Sendable, Hashable, CaseIterable {
    /// Live provider endpoint.
    case api
    /// Provider-documented local/stdio interface (Codex `app-server` RPC).
    case appServer = "app-server"
    /// Aggregated from local CLI logs.
    case localLogs = "local-logs"
    /// Last successful value restored from disk because the network call failed.
    case cache

    public var displayLabel: String {
        switch self {
        case .api: "api"
        case .appServer: "app server"
        case .localLogs: "local logs"
        case .cache: "cached"
        }
    }

    /// `true` only for a path the provider actually publishes. A documented source outranks an
    /// undocumented HTTP endpoint, and it is never an estimate (AGENTS §10 #8).
    public var isDocumented: Bool {
        switch self {
        case .appServer: true
        case .api, .localLogs, .cache: false
        }
    }

    /// `true` when the numbers came from the provider itself rather than from logs or disk.
    public var isLive: Bool {
        switch self {
        case .api, .appServer: true
        case .localLogs, .cache: false
        }
    }
}
