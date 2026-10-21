import Foundation

/// Claude Code provider.
///
/// Data source: undocumented OAuth usage endpoint, read-only keychain credentials, no
/// token refresh (AGENTS §2). Poll no faster than every 180s when configured by the app.
public struct ClaudeCodeProvider: UsageProvider {
    public let id: ProviderID = .claudeCode

    private let httpClient: any HTTPClient
    private let credentialStore: any CredentialStore

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        credentialStore: any CredentialStore = ClaudeCredentialStore()
    ) {
        self.httpClient = httpClient
        self.credentialStore = credentialStore
    }

    public func fetch(now: Date) async -> UsageSnapshot {
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

        // Expired tokens are never refreshed: rotating the one-time refresh token would break
        // the user's Claude Code session. Ask the user to run the CLI instead.
        if credential.isExpired(at: now) {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .needsLogin,
                plan: credential.planHint,
                now: now
            )
        }

        let request = ClaudeCodeEndpoints.usageRequest(accessToken: credential.accessToken)
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
                plan: credential.planHint,
                now: now
            )
        } catch {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .error(ProviderSupport.Failure.network),
                plan: credential.planHint,
                now: now
            )
        }

        guard response.statusCode == 200 else {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: ProviderSupport.status(
                    forHTTPStatusCode: response.statusCode, response: response, now: now),
                plan: credential.planHint,
                now: now
            )
        }

        do {
            let decoded = try ProviderSupport.decoder().decode(ClaudeUsageResponse.self, from: data)
            let windows = Self.windows(from: decoded, now: now)
            guard !windows.isEmpty else {
                return ProviderSupport.failureSnapshot(
                    provider: id,
                    status: .error(ProviderSupport.Failure.emptyUsage),
                    plan: credential.planHint,
                    now: now
                )
            }
            return UsageSnapshot(
                provider: id,
                plan: credential.planHint,
                windows: windows,
                source: .api,
                status: .ok,
                capturedAt: now
            )
        } catch {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: .error(ProviderSupport.Failure.decoding),
                plan: credential.planHint,
                now: now
            )
        }
    }

    // MARK: - Parsing

    /// Prefers the structured `limits[]` array and falls back to `five_hour` / `seven_day`.
    static func windows(from response: ClaudeUsageResponse, now: Date) -> [LimitWindow] {
        var windows: [LimitWindow] = []

        if let limits = response.limits, !limits.isEmpty {
            for (index, limit) in limits.enumerated() {
                guard let percent = limit.percent, let kind = kind(forLimitKind: limit.kind) else {
                    continue
                }
                windows.append(
                    LimitWindow(
                        id: "\(ProviderID.claudeCode.rawValue).\(kind.rawValue).\(index)",
                        kind: kind,
                        label: label(for: kind, scope: limit.scope),
                        usedFraction: percent / 100,
                        resetsAt: limit.resetsAt,
                        isEstimated: false,
                        isPlaceholder: false,
                        capturedAt: now
                    )
                )
            }
        }

        if windows.isEmpty {
            if let utilization = response.fiveHour?.utilization {
                windows.append(
                    LimitWindow(
                        id: "\(ProviderID.claudeCode.rawValue).\(LimitWindow.Kind.session5h.rawValue)",
                        kind: .session5h,
                        label: "5-hour",
                        usedFraction: utilization / 100,
                        resetsAt: response.fiveHour?.resetsAt,
                        capturedAt: now
                    )
                )
            }
            if let utilization = response.sevenDay?.utilization {
                windows.append(
                    LimitWindow(
                        id: "\(ProviderID.claudeCode.rawValue).\(LimitWindow.Kind.weekly7d.rawValue)",
                        kind: .weekly7d,
                        label: "Weekly",
                        usedFraction: utilization / 100,
                        resetsAt: response.sevenDay?.resetsAt,
                        capturedAt: now
                    )
                )
            }
        }

        return windows
    }

    static func kind(forLimitKind raw: String?) -> LimitWindow.Kind? {
        switch raw {
        case "session": .session5h
        case "weekly_all": .weekly7d
        case "weekly_scoped": .weeklyScoped
        default: nil
        }
    }

    private static func label(for kind: LimitWindow.Kind, scope: ClaudeUsageResponse.Limit.Scope?) -> String {
        switch kind {
        case .session5h:
            return "5-hour"
        case .weekly7d:
            return "Weekly"
        case .weeklyScoped:
            // Spec: label a scoped weekly bucket with the model display name (e.g. "Fable").
            return scope?.model?.displayName ?? "Weekly (scoped)"
        default:
            return kind.rawValue
        }
    }
}
