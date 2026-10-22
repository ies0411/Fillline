import Foundation

/// OpenRouter provider — shows the **USD credit balance** a key has left.
///
/// This provider is the one exception to the percent-first model: OpenRouter reports money, not
/// a fraction, so the window carries an absolute amount in its `label` (`"$8.50 left"`) and the
/// UI renders it as text with **no meter** (`UsageFormat.isAmountRow`). No percentage is ever
/// derived, because the key limit is not the account balance (issue #13).
///
/// `fetch` never throws: every failure is a stable card status (AGENTS §3).
public struct OpenRouterProvider: UsageProvider {
    public let id: ProviderID = .openRouter

    private let httpClient: any HTTPClient
    private let credentialStore: any CredentialStore

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        credentialStore: any CredentialStore = OpenRouterKeyStore()
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

        let request = OpenRouterEndpoints.keyRequest(apiKey: credential.accessToken)
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

        guard response.statusCode == 200 else {
            return ProviderSupport.failureSnapshot(
                provider: id,
                status: ProviderSupport.status(
                    forHTTPStatusCode: response.statusCode, response: response, now: now),
                now: now
            )
        }

        do {
            let decoded = try ProviderSupport.decoder().decode(
                OpenRouterUsageResponse.self,
                from: data
            )
            let plan = decoded.data?.isFreeTier == true ? "Free" : nil
            // No amount reported (no key cap and no effective budget) is a legitimate answer:
            // an empty window list renders as "nothing to chart", never as a fake 0%/100%.
            return UsageSnapshot(
                provider: id,
                plan: plan,
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

    /// Balance resolution order: `effective_budget.remaining_usd` (per-account budget) first,
    /// then the key's own `limit_remaining`. `nil` means the payload reports no balance.
    static func remainingUSD(from response: OpenRouterUsageResponse) -> Double? {
        response.data?.effectiveBudget?.remainingUsd ?? response.data?.limitRemaining
    }

    /// `true` when a key limit is known, i.e. the balance is finite. A `null` limit means
    /// "no cap" and is labelled as such rather than charted.
    static func hasCap(from response: OpenRouterUsageResponse) -> Bool {
        response.data?.limit != nil || response.data?.effectiveBudget?.limitUsd != nil
    }

    static func windows(from response: OpenRouterUsageResponse, now: Date) -> [LimitWindow] {
        guard let remaining = remainingUSD(from: response) else { return [] }

        let cap = hasCap(from: response)
        let label = cap ? "\(formatUSD(remaining)) left" : "\(formatUSD(remaining)) left · no cap"

        return [
            LimitWindow(
                id: "\(ProviderID.openRouter.rawValue).credits",
                kind: .credits,
                label: label,
                // Deliberately not a fraction: OpenRouter reports money and the key limit is not
                // the account balance, so any percentage here would be invented. `isAmountRow`
                // (label starts with "$") makes the UI render text-only, and AppModel keeps this
                // row out of percent-driven surfaces.
                usedFraction: 0,
                resetsAt: resetsAt(from: response),
                isEstimated: false,
                isPlaceholder: false,
                capturedAt: now
            )
        ]
    }

    /// The first budget reset the payload carries (`budgets[].resets_at`, ISO-8601 with
    /// milliseconds), falling back to the effective budget's own reset.
    static func resetsAt(from response: OpenRouterUsageResponse) -> Date? {
        if let fromBudgets = response.data?.budgets?.compactMap(\.resetsAt).first {
            return fromBudgets
        }
        return response.data?.effectiveBudget?.resetsAt
    }

    /// `$8.50`, `$0.00`, `-$0.25`. Locale-stable on purpose (the app never uses a user locale
    /// for a value that must match the provider's USD statement).
    static func formatUSD(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded < 0 {
            return "-$" + String(format: "%.2f", -rounded)
        }
        return "$" + String(format: "%.2f", rounded)
    }
}
