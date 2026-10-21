import AppKit
import SwiftUI
import UsageCore

/// One provider panel. Every non-`ok` state has its own deliberate body, never a blank
/// card and never a fabricated `0%`.
struct ProviderCard: View {
    let provider: ProviderID
    let snapshot: UsageSnapshot?
    let isClaudeOAuthReadEnabled: Bool
    let now: Date

    /// The history trail is ambient per-provider state owned by the model, not something the
    /// popover threads through. Reading it here keeps the card's initialiser unchanged.
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            if provider == .claudeCode, !isClaudeOAuthReadEnabled {
                localOnlyState
            } else if let snapshot, !snapshot.windows.isEmpty {
                windows(snapshot)
                sparkline
                if snapshot.status.isFailure {
                    StatusFooter(snapshot: snapshot, now: now)
                }
            } else if let snapshot {
                unavailableState(for: snapshot)
            } else {
                loadingState
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: provider.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 15)
                .accessibilityHidden(true)

            Text(provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let plan = snapshot?.plan, !plan.isEmpty {
                PlanBadge(plan: plan)
            }

            if let resetCredits = snapshot?.resetCredits, resetCredits > 0 {
                Text(resetCredits == 1 ? "1 reset" : "\(resetCredits) resets")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(
                        Text(
                            resetCredits == 1
                                ? "1 limit reset available"
                                : "\(resetCredits) limit resets available"
                        )
                    )
            }

            Spacer(minLength: 4)

            if let source = snapshot?.source, showsSourceBadge(source) {
                SourceBadge(source: source)
            }

            if let status = snapshot?.status, !status.isSuccess {
                StatusBadge(status: status)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// `api` is the default path and says nothing new; every other source changes how the
    /// number should be read, so the card names it.
    private func showsSourceBadge(_ source: Source) -> Bool {
        switch source {
        case .appServer, .localLogs, .cache: true
        case .api: false
        }
    }

    private func windows(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.windows) { window in
                WindowRow(window: window, now: now)
            }
        }
    }

    /// Full width, directly under the meters it continues. It contributes no height at all
    /// until two samples exist (docs/design/ui.md §12).
    @ViewBuilder
    private var sparkline: some View {
        if let data = model.sparkline(for: provider), data.samples.count >= 2 {
            Sparkline(data: data, now: now)
        }
    }

    // MARK: States

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
            Text("Checking…")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Checking \(provider.displayName) usage"))
    }

    /// Claude's OAuth read is off. This is a consent state, not an error.
    private var localOnlyState: some View {
        HStack(alignment: .top, spacing: 9) {
            stateIcon("doc.text.magnifyingglass")

            VStack(alignment: .leading, spacing: 3) {
                Text("Local logs only")
                    .font(.system(size: 12, weight: .semibold))

                Text(
                    "Reading the Claude Code login is off, so this app isn't using it. Local-log estimates aren't available in this build."
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                SettingsLink {
                    Text("Turn on in Settings")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.link)
                .padding(.top, 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func unavailableState(for snapshot: UsageSnapshot) -> some View {
        let state = UnavailableCopy(provider: provider, snapshot: snapshot, now: now)

        return HStack(alignment: .top, spacing: 9) {
            stateIcon(state.symbol)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(state.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let command = state.command {
                    CommandPill(command: command)
                        .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func stateIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Empty state copy

private struct UnavailableCopy {
    let symbol: String
    let title: String
    let detail: String
    let command: String?

    init(provider: ProviderID, snapshot: UsageSnapshot, now: Date) {
        let command = provider.signInCommand

        switch snapshot.status {
        case .needsLogin:
            symbol = "key.fill"
            title = "Sign in to \(provider.shortName)"
            detail = "Run the CLI once to refresh its login. Tokens are read-only and never stored."
            self.command = command
        case .notInstalled:
            symbol = "shippingbox"
            title = "\(provider.shortName) CLI not found"
            detail = "Install it and sign in once; this card fills in on its own."
            self.command = nil
        case .notSubscribed:
            symbol = "creditcard"
            title = provider == .openCodeGo ? "This key has no Go plan" : "No \(provider.shortName) plan"
            detail = "The key is valid, but there's no subscription attached to it."
            self.command = nil
        case .rateLimited(let retryAfter):
            symbol = "hourglass"
            title = "Rate limited"
            if let retryAfter {
                detail = "Too many requests. The next try is in \(UsageFormat.duration(retryAfter))."
            } else {
                detail = "Too many requests. Backing off before the next try."
            }
            self.command = nil
        case .unsupported:
            symbol = "nosign"
            title = "Not available for this account"
            detail = "The provider didn't return usage for this login."
            self.command = nil
        case .error(let code):
            symbol = "exclamationmark.triangle"
            title = "Couldn't read usage"
            detail = "The request failed (\(code)). It will retry automatically."
            self.command = nil
        case .stale:
            symbol = "clock.arrow.circlepath"
            title = "Waiting for fresh data"
            detail =
                "The last check was \(UsageFormat.relativeAge(since: snapshot.capturedAt, now: now)). Nothing new came back."
            self.command = nil
        case .ok:
            symbol = "questionmark.circle"
            title = "No windows reported"
            detail = "The provider answered, but didn't include any quota windows."
            self.command = nil
        }
    }
}

// MARK: - Footer for a failed refresh with retained values

private struct StatusFooter: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
                .opacity(0.55)
                .padding(.bottom, 2)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(spokenMessage))
            }

            if let command {
                CommandPill(command: command)
                    .padding(.leading, 15)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch snapshot.status {
        case .stale: "clock.arrow.circlepath"
        case .needsLogin: "key.fill"
        case .rateLimited: "hourglass"
        case .notInstalled: "shippingbox"
        case .notSubscribed: "creditcard"
        case .unsupported: "nosign"
        case .error: "exclamationmark.triangle"
        case .ok: "checkmark"
        }
    }

    private var message: String {
        let age = UsageFormat.relativeAge(since: snapshot.capturedAt, now: now)

        switch snapshot.status {
        case .stale:
            return "Stale · \(age)\(failureCountSuffix) — showing last known values."
        case .needsLogin:
            return "Sign-in required. Values are from \(age)."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited · retry in \(UsageFormat.duration(retryAfter)) · values from \(age)."
            }
            return "Rate limited · backing off · values from \(age)."
        case .notInstalled:
            return "\(snapshot.provider.shortName) CLI not found · values from \(age)."
        case .notSubscribed:
            return "No subscription · values from \(age)."
        case .unsupported:
            return "Usage unavailable for this account · values from \(age)."
        case .error(let code):
            return "Couldn't refresh (\(code)) · values from \(age)."
        case .ok:
            return "Live."
        }
    }

    /// One failure is the ordinary case for a single bad poll, so it stays silent; two or
    /// more mean the values are not just a minute old, they are stuck (issue #9).
    private var failureCountSuffix: String {
        let failures = snapshot.consecutiveFailures
        guard failures >= 2 else { return "" }
        return " · \(failures) failures"
    }

    /// Same information in words: VoiceOver reads the count as "after 3 failed refreshes"
    /// rather than a bare number.
    private var spokenMessage: String {
        switch snapshot.status {
        case .stale:
            let failures = snapshot.consecutiveFailures
            guard failures >= 2 else {
                return "Stale for \(spokenAge), showing last known values."
            }
            return "Stale for \(spokenAge) after \(failures) failed refreshes, showing last known values."
        default:
            return message
        }
    }

    /// `capturedAt` age in whole words, measured the same way `relativeAge` rounds it.
    private var spokenAge: String {
        UsageFormat.spokenDuration(max(0, now.timeIntervalSince(snapshot.capturedAt)))
    }

    private var command: String? {
        guard case .needsLogin = snapshot.status else { return nil }
        return snapshot.provider.signInCommand
    }
}

// MARK: - Command pill

/// Shows the exact command that refreshes a CLI-owned login, with a copy button.
private struct CommandPill: View {
    let command: String
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 5) {
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                didCopy = true
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(didCopy ? "Copied" : "Copy command"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
