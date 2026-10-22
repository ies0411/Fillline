import AppKit
import SwiftUI

/// The popover: a compact instrument panel, or the one-screen welcome on first run.
struct PopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.hasCompletedOnboarding {
                dashboard
            } else {
                OnboardingView()
            }
        }
        .frame(width: 340)
        .animation(.easeInOut(duration: 0.2), value: model.hasCompletedOnboarding)
        .task { model.start() }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        TimelineView(.periodic(from: Date.now, by: 30)) { context in
            VStack(spacing: 0) {
                header(now: context.date)

                Divider()
                    .opacity(0.6)

                content(now: context.date)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 10)

                Divider()
                    .opacity(0.6)

                footer
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "speedometer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Fillline")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(-0.1)

            Spacer(minLength: 6)

            if let checked = model.lastCheckedAt {
                Text("checked \(UsageFormat.relativeAge(since: checked, now: now))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Button {
                model.refreshNow()
            } label: {
                Group {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(model.isRefreshing)
            .help("Refresh now")
            .accessibilityLabel(Text(model.isRefreshing ? "Refreshing usage" : "Refresh usage"))

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 10.5, weight: .medium))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GhostButtonStyle())
            .help("Settings")
            .accessibilityLabel("Open settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if model.orderedProviders.isEmpty {
            hiddenState
        } else {
            cards(now: now)
        }
    }

    private func cards(now: Date) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(model.orderedProviders.enumerated()), id: \.element) { index, provider in
                ProviderCard(
                    provider: provider,
                    snapshot: model.snapshot(for: provider),
                    isClaudeOAuthReadEnabled: model.claudeOAuthReadEnabled,
                    now: now
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 5)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeOut(duration: 0.24).delay(Double(index) * 0.045),
                    value: appeared
                )
            }
        }
        .padding(.top, 8)
        .onAppear { appeared = true }
    }

    private var hiddenState: some View {
        VStack(spacing: 7) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)

            Text("All cards are hidden")
                .font(.system(size: 12, weight: .semibold))

            Text("Turn a provider back on to see its numbers here.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SettingsLink {
                Text("Open Settings")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(LinkButtonStyle())
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock")
                .font(.system(size: 8, weight: .medium))
                .accessibilityHidden(true)

            Text("Read-only · no telemetry")

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(GhostButtonStyle())
            .font(.system(size: 9.5))
            .accessibilityLabel("Quit Fillline")
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: Animation state

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
}

// MARK: - First run

private struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            masthead

            VStack(alignment: .leading, spacing: 5) {
                Text("See the wall before you hit it.")
                    .font(.system(size: 21, weight: .semibold))
                    .tracking(-0.4)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Remaining usage for Claude Code, Codex, and OpenCode Go — in your menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 9) {
                privacyRow(
                    symbol: "lock.shield",
                    title: "Reads logins you already have",
                    detail: "No sign-in flow. Credentials stay where your CLIs put them."
                )
                privacyRow(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Never refreshes tokens",
                    detail: "Refreshing would rotate a one-time token and sign out the CLI."
                )
                privacyRow(
                    symbol: "hand.raised",
                    title: "No telemetry",
                    detail: "Nothing is uploaded. Requests go only to the three providers."
                )
            }

            claudePanel

            Button {
                model.completeOnboarding()
            } label: {
                Text("Start monitoring")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Shows the provider cards in this popover")

            HStack(spacing: 6) {
                Text("No account needed.")
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(GhostButtonStyle())
                .font(.system(size: 9.5))
                .accessibilityLabel("Quit Fillline")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 12)
    }

    private var masthead: some View {
        HStack(spacing: 7) {
            Image(systemName: "speedometer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Fillline")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(-0.1)

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 10.5, weight: .medium))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GhostButtonStyle())
            .help("Settings")
            .accessibilityLabel("Open settings")
        }
    }

    private func privacyRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var claudePanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Advanced · read my Claude token")
                    .font(.system(size: 11.5, weight: .medium))

                Spacer(minLength: 4)

                Toggle("", isOn: claudeOptIn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Read my Claude Code token")
            }

            Text(
                model.claudeOAuthReadEnabled
                    ? "On · read-only, held in memory only." : "Off · local logs only."
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            Text(
                "The only provider that reads a stored credential. Anthropic's policy doesn't allow apps to collect Claude.ai credentials, so this stays off unless you choose it."
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Link("Read the policy note", destination: AppLinks.readmePolicy)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var claudeOptIn: Binding<Bool> {
        Binding(
            get: { model.claudeOAuthReadEnabled },
            set: { model.claudeOAuthReadEnabled = $0 }
        )
    }
}
