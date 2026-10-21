import Foundation

/// Codex usage sources. The documented `codex app-server` → `account/rateLimits/read` path is
/// preferred at runtime; the **undocumented** `wham/usage` backend route (contract captured
/// 2026-10-21) is the fallback. Use is subject to OpenAI's terms
/// (see docs/providers/codex.md for the citation).
/// All endpoint URLs, headers, and app-server constants for this provider live here (AGENTS §2).
public enum CodexEndpoints {
    public static let usage = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static var host: String { usage.host() ?? "" }

    public static let userAgent = "codex-cli"

    public static func usageRequest(accessToken: Credential, accountID: Credential?) -> URLRequest {
        var request = URLRequest(url: usage)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken.reveal())", forHTTPHeaderField: "Authorization")
        if let accountID {
            request.setValue(accountID.reveal(), forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - app-server (documented JSON-RPC-over-stdio)

    /// Resolved through `PATH` unless an absolute path is configured (AGENTS §2, codex.md).
    public static let appServerExecutableName = "codex"
    public static let appServerArguments = ["app-server", "--listen", "stdio://"]

    public static let appServerInitializeMethod = "initialize"
    public static let appServerRateLimitsMethod = "account/rateLimits/read"
    public static let appServerClientName = "Fillline"

    /// Request ids are part of the wire contract; the timeout covers handshake + read.
    public static let appServerInitializeRequestID = 1
    public static let appServerRateLimitsRequestID = 2
    public static let appServerTimeout: TimeInterval = 10

    /// `MARKETING_VERSION` when running inside the app bundle, `0.1.0` otherwise (tests, CLI).
    public static var appServerClientVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? fallbackClientVersion
    }

    public static let fallbackClientVersion = "0.1.0"
}
