import Foundation

/// Production `HTTPClient`, backed by an ephemeral URLSession.
///
/// Privacy choices (AGENTS §4):
/// - ephemeral configuration: no disk cache, no cookies, no credential storage;
/// - host allowlist derived from provider `Endpoints.swift` constants;
/// - no telemetry, no third-party hosts.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 20

    /// Hosts the app may contact. Derived from the provider endpoint constants so URLs stay
    /// single-sourced in `Endpoints.swift` files.
    public static var defaultAllowedHosts: Set<String> {
        Set(
            [ClaudeCodeEndpoints.host, CodexEndpoints.host, OpenCodeGoEndpoints.host]
                .filter { !$0.isEmpty }
        )
    }

    private let session: URLSession
    private let allowedHosts: Set<String>

    /// Creates a client with an ephemeral session.
    public convenience init(
        allowedHosts: Set<String> = URLSessionHTTPClient.defaultAllowedHosts,
        timeout: TimeInterval = URLSessionHTTPClient.defaultTimeout
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        self.init(configuration: configuration, allowedHosts: allowedHosts)
    }

    public init(
        configuration: URLSessionConfiguration,
        allowedHosts: Set<String> = URLSessionHTTPClient.defaultAllowedHosts
    ) {
        self.session = URLSession(configuration: configuration)
        self.allowedHosts = allowedHosts
    }

    /// Injection point for tests or a preconfigured session.
    public init(
        session: URLSession,
        allowedHosts: Set<String> = URLSessionHTTPClient.defaultAllowedHosts
    ) {
        self.session = session
        self.allowedHosts = allowedHosts
    }

    public func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.httpMethod = "GET"

        if !allowedHosts.isEmpty {
            guard let host = request.url?.host(), allowedHosts.contains(host) else {
                throw HTTPClientError.hostNotAllowed
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Intentionally drop the underlying error: it can embed host/path details.
            throw HTTPClientError.transport
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.notHTTP
        }
        return (data, httpResponse)
    }
}
