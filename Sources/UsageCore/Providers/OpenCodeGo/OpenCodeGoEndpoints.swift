import Foundation

/// OpenCode Go usage endpoint — **undocumented** quota endpoint (captured live 2026-10-21).
/// Not a public contract; review OpenCode's terms (https://opencode.ai/terms) before use.
/// All endpoint URLs and headers for this provider live here (AGENTS §2).
public enum OpenCodeGoEndpoints {
    public static let usage = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    public static var host: String { usage.host() ?? "" }

    public static func usageRequest(apiKey: Credential) -> URLRequest {
        var request = URLRequest(url: usage)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey.reveal())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
