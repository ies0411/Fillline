import Foundation

/// Claude Code usage endpoint — **undocumented**, observed live from Claude Code 2.1.80
/// on 2026-10-21. It is not part of Anthropic's public API contract and can change without
/// notice. Use is subject to Anthropic's terms (see docs/providers/claude-code.md for the citation).
/// All endpoint URLs and headers for this provider live here (AGENTS §2).
public enum ClaudeCodeEndpoints {
    public static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static var host: String { usage.host() ?? "" }

    /// Required beta flag for the OAuth usage endpoint.
    public static let anthropicBeta = "oauth-2025-04-20"

    /// MANDATORY. Without this exact User-Agent the endpoint returns punitive 429s.
    public static let userAgent = "claude-code/2.1.80"

    public static func usageRequest(accessToken: Credential) -> URLRequest {
        var request = URLRequest(url: usage)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken.reveal())", forHTTPHeaderField: "Authorization")
        request.setValue(anthropicBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
