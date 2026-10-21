import Foundation

/// OpenCode Go provider. Key discovery is handled by `OpenCodeAuthStore`.
///
/// HTTP 403 means "valid key, no Go subscription" and maps to `.notSubscribed`, which is a
/// different UI message than 401 `.needsLogin` (contract, 2026-10-21).
public struct OpenCodeGoProvider: UsageProvider {
    public let id: ProviderID = .openCodeGo

    private let httpClient: any HTTPClient
    private let credentialStore: any CredentialStore

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        credentialStore: any CredentialStore = OpenCodeAuthStore()
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

        let request = OpenCodeGoEndpoints.usageRequest(apiKey: credential.accessToken)
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

        switch response.statusCode {
        case 200:
            break
        case 403:
            return ProviderSupport.failureSnapshot(provider: id, status: .notSubscribed, now: now)
        default:
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: ProviderSupport.status(
                    forHTTPStatusCode: response.statusCode, response: response, now: now),
                now: now
            )
        }

        do {
            let decoded = try ProviderSupport.decoder().decode(OpenCodeGoUsageResponse.self, from: data)
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
                plan: nil,
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

    static func windows(from response: OpenCodeGoUsageResponse, now: Date) -> [LimitWindow] {
        var windows: [LimitWindow] = []
        if let window = makeWindow(
            id: "\(ProviderID.openCodeGo.rawValue).rolling",
            from: response.usage?.rolling,
            kind: .rolling,
            label: "Rolling",
            now: now
        ) {
            windows.append(window)
        }
        if let window = makeWindow(
            id: "\(ProviderID.openCodeGo.rawValue).weekly",
            from: response.usage?.weekly,
            kind: .weekly7d,
            label: "Weekly",
            now: now
        ) {
            windows.append(window)
        }
        if let window = makeWindow(
            id: "\(ProviderID.openCodeGo.rawValue).monthly",
            from: response.usage?.monthly,
            kind: .monthly,
            label: "Monthly",
            now: now
        ) {
            windows.append(window)
        }
        return windows
    }

    private static func makeWindow(
        id: String,
        from window: OpenCodeGoUsageResponse.Window?,
        kind: LimitWindow.Kind,
        label: String,
        now: Date
    ) -> LimitWindow? {
        guard let window, let percent = window.percent else { return nil }
        return LimitWindow(
            id: id,
            kind: kind,
            label: label,
            usedFraction: percent / 100,
            resetsAt: window.resetsAt,
            isEstimated: false,
            // 0% means the upstream reset time is a synthetic now+window placeholder.
            isPlaceholder: percent == 0,
            capturedAt: now
        )
    }
}
