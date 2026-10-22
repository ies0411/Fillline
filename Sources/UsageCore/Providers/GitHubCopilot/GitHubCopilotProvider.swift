import Foundation

/// GitHub Copilot provider — reads the Copilot quota buckets for the signed-in GitHub account.
///
/// Token acquisition is handled by `GitHubTokenStore` (env → `gh auth token`); nothing here
/// touches GitHub's keychain or refresh cycle. `fetch` never throws: every failure is a stable
/// card status (AGENTS §3).
///
/// Unit polarity: Copilot reports **percent_remaining** (0–100 remaining), so the shared model's
/// used fraction is `(100 − p) / 100`. This is the opposite of Claude/Codex/OpenCode Go, which
/// report used percent (AGENTS §2).
public struct GitHubCopilotProvider: UsageProvider {
    public let id: ProviderID = .githubCopilot

    private let httpClient: any HTTPClient
    private let tokenStore: any GitHubTokenProviding

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        tokenStore: any GitHubTokenProviding = GitHubTokenStore()
    ) {
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    public func fetch(now: Date) async -> UsageSnapshot {
        let credential: ProviderCredential
        do {
            credential = try await tokenStore.loadToken()
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

        let request = GitHubCopilotEndpoints.usageRequest(token: credential.accessToken)
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
            return ProviderSupport.failureSnapshot(provider: id, status: .error(code), now: now)
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
            // A valid token whose account/org has no Copilot seat.
            return ProviderSupport.failureSnapshot(provider: id, status: .notSubscribed, now: now)
        case 404:
            // The endpoint is not exposed for this account type (e.g. a personal token with no
            // Copilot entitlement at all).
            return ProviderSupport.failureSnapshot(provider: id, status: .unsupported, now: now)
        default:
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: ProviderSupport.status(
                    forHTTPStatusCode: response.statusCode, response: response, now: now),
                now: now
            )
        }

        do {
            let decoded = try ProviderSupport.decoder().decode(
                GitHubCopilotUsageResponse.self,
                from: data
            )
            // An empty window list is a legitimate answer (every bucket is unlimited or the
            // plan has no metered quota). It renders as "nothing to chart", never as 0%/100%.
            return UsageSnapshot(
                provider: id,
                plan: Self.planLabel(decoded.copilotPlan ?? decoded.accessTypeSku),
                windows: Self.windows(from: decoded, now: now),
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

    /// Buckets the card can show, most constraining first. `premium_interactions` is the quota
    /// users actually run out of, so it leads (and drives the menu bar's "primary" window).
    static let bucketOrder: [(key: String, kind: LimitWindow.Kind, label: String)] = [
        ("premium_interactions", .monthly, "Premium"),
        ("chat", .monthly, "Chat"),
        ("completions", .monthly, "Completions"),
    ]

    static func windows(from response: GitHubCopilotUsageResponse, now: Date) -> [LimitWindow] {
        guard let snapshots = response.quotaSnapshots else { return [] }

        var windows: [LimitWindow] = []
        for bucket in bucketOrder {
            guard let snapshot = snapshots[bucket.key] else { continue }
            // `unlimited` buckets and zero-entitlement buckets have no fraction to draw.
            // Charting them would invent a 100% (or 0%) bar out of nothing (issue #14 trap).
            if snapshot.unlimited == true { continue }
            if let entitlement = snapshot.entitlement, entitlement <= 0 { continue }
            guard let remaining = snapshot.remainingFraction else { continue }

            windows.append(
                LimitWindow(
                    id: "\(ProviderID.githubCopilot.rawValue).\(bucket.key)",
                    kind: bucket.kind,
                    label: bucket.label,
                    // Copilot reports REMAINING; the model stores USED.
                    usedFraction: 1 - remaining,
                    resetsAt: snapshot.quotaResetAt ?? response.coarseResetsAt,
                    isEstimated: false,
                    isPlaceholder: false,
                    capturedAt: now
                )
            )
        }
        return windows
    }

    /// `"individual"` → `"Individual"`; unknown/absent plans stay `nil` rather than guessed.
    static func planLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "individual", "business", "enterprise", "free":
            return trimmed.capitalized
        default:
            // Copilot plan names change; show what the server said instead of mapping it.
            return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
