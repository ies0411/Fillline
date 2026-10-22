import Foundation

/// Claude Code provider.
///
/// Data sources (AGENTS §2), in order:
/// 1. undocumented OAuth usage endpoint (opt-in, read-only keychain credentials, no refresh);
/// 2. `~/.claude/projects/**/*.jsonl` aggregation — **credential-free**, token quantities only
///    (issue #16).
///
/// Path 2 is the default: with the token read off the app never touches the Keychain, and with
/// it on the API value wins while an estimate stands in only when the API cannot answer.
/// Poll no faster than every 180s when configured by the app.
public struct ClaudeCodeProvider: UsageProvider {
    public let id: ProviderID = .claudeCode

    private let httpClient: any HTTPClient
    private let credentialStore: any CredentialStore
    /// `false` keeps the Keychain untouched: every fetch comes from local logs.
    private let credentialReadEnabled: Bool
    /// Injected explicitly so nothing can read the developer's real `~/.claude` by accident.
    /// `nil` means this instance has no local-log path (the app always supplies one).
    private let localLogs: ClaudeLocalLogAggregator?

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        credentialStore: any CredentialStore = ClaudeCredentialStore(),
        credentialReadEnabled: Bool = true,
        localLogs: ClaudeLocalLogAggregator? = nil
    ) {
        self.httpClient = httpClient
        self.credentialStore = credentialStore
        self.credentialReadEnabled = credentialReadEnabled
        self.localLogs = localLogs
    }

    public func fetch(now: Date) async -> UsageSnapshot {
        guard credentialReadEnabled else {
            return await localLogSnapshot(now: now, fallbackStatus: .ok)
        }

        let credential: ProviderCredential
        do {
            credential = try credentialStore.loadCredentials()
        } catch let error as CredentialError {
            return await localLogSnapshot(
                now: now,
                fallbackStatus: ProviderStatus.from(error)
            )
        } catch {
            return await localLogSnapshot(now: now, fallbackStatus: .error("credential-read-failed"))
        }

        // Expired tokens are never refreshed: rotating the one-time refresh token would break
        // the user's Claude Code session. Ask the user to run the CLI instead.
        if credential.isExpired(at: now) {
            return await localLogSnapshot(now: now, fallbackStatus: .needsLogin)
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
            return await localLogSnapshot(
                now: now,
                fallbackStatus: .error(code)
            )
        } catch {
            return await localLogSnapshot(
                now: now,
                fallbackStatus: .error(ProviderSupport.Failure.network)
            )
        }

        guard response.statusCode == 200 else {
            return await localLogSnapshot(
                now: now,
                fallbackStatus: ProviderSupport.status(
                    forHTTPStatusCode: response.statusCode, response: response, now: now)
            )
        }

        do {
            let decoded = try ProviderSupport.decoder().decode(ClaudeUsageResponse.self, from: data)
            let windows = Self.windows(from: decoded, now: now)
            guard !windows.isEmpty else {
                return await localLogSnapshot(
                    now: now,
                    fallbackStatus: .error(ProviderSupport.Failure.emptyUsage)
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
            return await localLogSnapshot(
                now: now,
                fallbackStatus: .error(ProviderSupport.Failure.decoding)
            )
        }
    }

    // MARK: - Local-log estimate

    /// The credential-free path (issue #16).
    ///
    /// `fallbackStatus` is `.ok` when the token read is deliberately off. When the read is on but
    /// failed, the failure status is kept on purpose: `PollScheduler` then retains the last good
    /// API values instead of letting an estimate impersonate a fresh reading.
    private func localLogSnapshot(now: Date, fallbackStatus: ProviderStatus) async -> UsageSnapshot {
        guard let localLogs else {
            // No local-log path was supplied: say so instead of reading a directory the caller
            // never pointed at.
            return UsageSnapshot(
                provider: id,
                plan: nil,
                windows: [],
                source: .localLogs,
                status: fallbackStatus.isSuccess ? .unsupported : fallbackStatus,
                capturedAt: now
            )
        }

        let totals = await localLogs.totals(now: now)

        guard totals.hasUsableData else {
            return UsageSnapshot(
                provider: id,
                plan: nil,
                windows: [],
                source: .localLogs,
                status: fallbackStatus.isSuccess ? .unsupported : fallbackStatus,
                capturedAt: now
            )
        }

        return UsageSnapshot(
            provider: id,
            plan: nil,
            windows: Self.localWindows(from: totals, capturedAt: now),
            source: .localLogs,
            status: fallbackStatus.isSuccess ? .ok : fallbackStatus,
            capturedAt: now
        )
    }

    /// Two quantity rows — never a fraction.
    ///
    /// Local logs hold no plan limit, so `usedFraction` cannot be derived. `0` is the model's
    /// stand-in for "no percentage" (the model has no optional fraction); `isAmountRow` makes the
    /// UI render the label as text and keeps these rows out of the menu-bar percentage, the
    /// "lowest" summary, sparklines and alerts.
    static func localWindows(
        from totals: ClaudeLocalLogAggregator.Totals,
        capturedAt now: Date
    ) -> [LimitWindow] {
        let provider = ProviderID.claudeCode.rawValue
        return [
            LimitWindow(
                id: "\(provider).local.\(LimitWindow.Kind.rolling.rawValue)",
                kind: .rolling,
                label: "\(formatTokenCount(totals.fiveHourTokens)) tokens · 5h",
                usedFraction: 0,
                resetsAt: nil,
                isEstimated: true,
                isPlaceholder: false,
                capturedAt: now
            ),
            LimitWindow(
                id: "\(provider).local.\(LimitWindow.Kind.weekly7d.rawValue)",
                kind: .weekly7d,
                label: "\(formatTokenCount(totals.sevenDayTokens)) tokens · 7d",
                usedFraction: 0,
                resetsAt: nil,
                isEstimated: true,
                isPlaceholder: false,
                capturedAt: now
            ),
        ]
    }

    /// `"940"`, `"12.3K"`, `"1.2M"`. Locale-stable: the label must match what the docs describe.
    static func formatTokenCount(_ tokens: Int) -> String {
        let value = Double(max(0, tokens))
        if value >= 1_000_000 {
            return trimmedDecimal(value / 1_000_000) + "M"
        }
        if value >= 1_000 {
            return trimmedDecimal(value / 1_000) + "K"
        }
        return "\(max(0, tokens))"
    }

    private static func trimmedDecimal(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
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
