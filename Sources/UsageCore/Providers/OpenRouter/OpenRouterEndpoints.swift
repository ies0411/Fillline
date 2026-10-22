import Foundation

/// OpenRouter credit endpoint and headers.
///
/// `GET https://openrouter.ai/api/v1/key` is the documented key endpoint (the same one the
/// dashboard calls). The host is `openrouter.ai` — `api.openrouter.ai` does not resolve.
///
/// The account balance lives behind `/api/v1/credits`, which is **management-key only** and
/// returns 403 to an inference key, so v1 does not call it (issue #13).
///
/// Everything describing the request lives in this one file (AGENTS §2).
public enum OpenRouterEndpoints {
    public static let key = URL(string: "https://openrouter.ai/api/v1/key")!

    public static var host: String { key.host() ?? "" }

    public static func keyRequest(apiKey: Credential) -> URLRequest {
        var request = URLRequest(url: key)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey.reveal())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
