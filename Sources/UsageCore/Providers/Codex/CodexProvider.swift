import Foundation

/// Ordered Codex data sources. The documented `app-server` RPC is preferred at runtime; the
/// undocumented `wham/usage` HTTP route is the fallback (docs/providers/codex.md).
public enum CodexStrategy: String, Sendable, Hashable, CaseIterable {
    case appServer = "app-server"
    case http
}

extension CodexStrategy {
    /// Sensible default: documented strategy first, HTTP fallback second.
    public static let defaultOrder: [CodexStrategy] = [.appServer, .http]
}

/// Codex provider. Runs the ordered strategies and returns the first success; every failure is
/// a `ProviderStatus` code so one broken path cannot blank the card (AGENTS §3).
///
/// The app-server path does not read tokens at all — the CLI owns its login. The HTTP path uses
/// the local ChatGPT login from `~/.codex/auth.json`; no token refresh happens anywhere
/// (AGENTS §2), and both successes report `Source.api`.
public struct CodexProvider: UsageProvider {
    public let id: ProviderID = .codex

    private let httpClient: any HTTPClient
    private let credentialStore: any CredentialStore
    private let appServerClient: CodexAppServerClient
    private let strategies: [CodexStrategy]

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        credentialStore: any CredentialStore = CodexAuthStore(),
        appServerClient: CodexAppServerClient = CodexAppServerClient(),
        strategies: [CodexStrategy] = CodexStrategy.defaultOrder
    ) {
        self.httpClient = httpClient
        self.credentialStore = credentialStore
        self.appServerClient = appServerClient
        self.strategies = strategies
    }

    public func fetch(now: Date) async -> UsageSnapshot {
        var lastFailure: UsageSnapshot?

        for strategy in strategies {
            let attempt: UsageSnapshot
            switch strategy {
            case .appServer:
                attempt = await fetchAppServer(now: now)
            case .http:
                attempt = await fetchHTTP(now: now)
            }
            if attempt.status.isSuccess { return attempt }
            lastFailure = attempt
        }

        return lastFailure
            ?? ProviderSupport.failureSnapshot(provider: id, status: .unsupported, now: now)
    }

    // MARK: - Strategies

    private func fetchAppServer(now: Date) async -> UsageSnapshot {
        do {
            let response = try await appServerClient.rateLimits()
            let windows = response.windows(now: now)
            guard !windows.isEmpty else {
                return ProviderSupport.failureSnapshot(
                    provider: id,
                    status: .error(ProviderSupport.Failure.emptyUsage),
                    now: now
                )
            }
            return UsageSnapshot(
                provider: id,
                plan: response.planDescription,
                windows: windows,
                source: .api,
                status: .ok,
                capturedAt: now
            )
        } catch let error as CodexAppServerError {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: Self.status(for: error),
                now: now
            )
        } catch {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .error("app-server-failed"),
                now: now
            )
        }
    }

    /// Stable codes only — `rpcError` keeps its numeric code, nothing else is propagated.
    static func status(for error: CodexAppServerError) -> ProviderStatus {
        switch error {
        case .notInstalled:
            .notInstalled
        case .launchFailed:
            .error("app-server-launch")
        case .ioFailed:
            .error("app-server-io")
        case .timedOut:
            .error("app-server-timeout")
        case .incompleteResponse:
            .error("app-server-incomplete")
        case .malformedResponse:
            .error("app-server-malformed")
        case .rpcError(let code):
            .error("app-server-rpc-\(abs(code))")
        }
    }

    private func fetchHTTP(now: Date) async -> UsageSnapshot {
        let credential: ProviderCredential
        do {
            credential = try credentialStore.loadCredentials()
        } catch let error as CredentialError {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: ProviderStatus.from(error),
                now: now
            )
        } catch {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .error("credential-read-failed"),
                now: now
            )
        }

        if credential.isExpired(at: now) {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .needsLogin,
                now: now
            )
        }

        let request = CodexEndpoints.usageRequest(
            accessToken: credential.accessToken,
            accountID: credential.accountID
        )
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.get(request)
        } catch let error as HTTPClientError {
            let code: String
            switch error {
            case .hostNotAllowed:
                code = "host-not-allowed"
            case .notHTTP, .transport:
                code = ProviderSupport.Failure.network
            }
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .error(code),
                now: now
            )
        } catch {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .error(ProviderSupport.Failure.network),
                now: now
            )
        }

        guard response.statusCode == 200 else {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: ProviderSupport.status(forHTTPStatusCode: response.statusCode, response: response, now: now),
                now: now
            )
        }

        do {
            let decoded = try ProviderSupport.decoder().decode(CodexUsageResponse.self, from: data)
            let windows = Self.windows(from: decoded, now: now)
            guard !windows.isEmpty else {
                return ProviderSupport.failureSnapshot(
                    provider: id,
                    status: .error(ProviderSupport.Failure.emptyUsage),
                    now: now
                )
            }
            return UsageSnapshot(
                provider: id,
                plan: decoded.planType,
                windows: windows,
                source: .api,
                status: .ok,
                capturedAt: now
            )
        } catch {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .error(ProviderSupport.Failure.decoding),
                now: now
            )
        }
    }

    // MARK: - Parsing

    static func windows(from response: CodexUsageResponse, now: Date) -> [LimitWindow] {
        var windows: [LimitWindow] = []
        if let window = makeWindow(
            id: "\(ProviderID.codex.rawValue).primary",
            from: response.rateLimit?.primaryWindow,
            now: now
        ) {
            windows.append(window)
        }
        if let window = makeWindow(
            id: "\(ProviderID.codex.rawValue).secondary",
            from: response.rateLimit?.secondaryWindow,
            now: now
        ) {
            windows.append(window)
        }
        return windows
    }

    private static func makeWindow(
        id: String,
        from window: CodexUsageResponse.Window?,
        now: Date
    ) -> LimitWindow? {
        guard let window, let usedPercent = window.usedPercent else { return nil }

        let descriptor = descriptor(forWindowSeconds: window.limitWindowSeconds)

        var resetsAt: Date?
        var isEstimated = false
        if let resetAt = window.resetAt {
            resetsAt = Date(timeIntervalSince1970: resetAt)
        } else if let resetAfter = window.resetAfterSeconds {
            resetsAt = now.addingTimeInterval(resetAfter)
            // Derived from a relative duration, not a server timestamp.
            isEstimated = true
        }

        return LimitWindow(
            id: id,
            kind: descriptor.kind,
            label: descriptor.label,
            usedFraction: usedPercent / 100,
            resetsAt: resetsAt,
            isEstimated: isEstimated,
            isPlaceholder: false,
            capturedAt: now
        )
    }

    static func descriptor(forWindowSeconds seconds: Int?) -> (kind: LimitWindow.Kind, label: String) {
        switch seconds {
        case 18_000:
            (.session5h, "Session (5h)")
        case 604_800:
            (.weekly7d, "Weekly")
        default:
            (.rolling, "Window")
        }
    }
}
