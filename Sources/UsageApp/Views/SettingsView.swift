import SwiftUI
import UsageCore

/// Settings window. Plain controls, no hidden state: everything here is persisted with
/// `UserDefaults` and takes effect on the next check.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var bindable = model

        Form {
            refreshSection(pollInterval: $bindable.pollInterval)
            menuBarSection(number: $bindable.menuBarNumber, style: $bindable.menuBarStyle)
            providersSection
            claudeSection(oauthEnabled: $bindable.claudeOAuthReadEnabled)
            startupSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 600)
    }

    // MARK: Refresh

    private func refreshSection(pollInterval: Binding<PollInterval>) -> some View {
        Section("Refresh") {
            Picker("Check every", selection: pollInterval) {
                ForEach(PollInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .pickerStyle(.segmented)

            Text("Claude Code is never checked more than once every 3 minutes, whatever you choose here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    model.refreshNow()
                } label: {
                    Label("Refresh now", systemImage: "arrow.clockwise")
                }
                .disabled(!model.hasCompletedOnboarding || model.isRefreshing)

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if let checked = model.lastCheckedAt {
                    Text("Last check \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.hasCompletedOnboarding {
                Text("Finish the welcome screen to start monitoring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Menu bar

    private func menuBarSection(
        number: Binding<MenuBarNumber>,
        style: Binding<MenuBarLabelStyle>
    ) -> some View {
        Section("Menu bar") {
            Picker("Number", selection: number) {
                ForEach(MenuBarNumber.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Text(model.menuBarNumber.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Label", selection: style) {
                ForEach(MenuBarLabelStyle.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            HStack {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                MenuBarLabel()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            Text("Compact shows only the lowest value; macOS truncates long labels from the right. A ~ means the number is the last known value.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Providers

    private var providersSection: some View {
        Section("Providers") {
            ForEach(ProviderID.allCases) { provider in
                Toggle(isOn: providerBinding(provider)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.displayName)
                        Text(providerSubtitle(provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("Turning a provider off stops its requests completely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func claudeSection(oauthEnabled: Binding<Bool>) -> some View {
        Section("Claude Code") {
            Toggle("Read Claude Code login", isOn: oauthEnabled)
                .disabled(!model.isProviderEnabled(.claudeCode))

            Text("Off by default. The token is read-only, held in memory, and never refreshed. Anthropic's policy restricts apps from collecting Claude.ai credentials, so this is your call.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link("Read the policy note", destination: AppLinks.readmePolicy)
                .font(.caption)

            Text("When off, the Claude card shows local logs only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var startupSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: .constant(false))
                .disabled(true)

            Text("Coming in a later version.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "0.1.0")

            Link("Privacy and limits", destination: AppLinks.readme)

            Button("Show welcome screen next time") {
                model.resetOnboarding()
            }

            Text("MIT licensed. Not affiliated with Anthropic, OpenAI, or OpenCode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func providerBinding(_ provider: ProviderID) -> Binding<Bool> {
        Binding(
            get: { model.isProviderEnabled(provider) },
            set: { model.setProvider(provider, enabled: $0) }
        )
    }

    private func providerSubtitle(_ provider: ProviderID) -> String {
        switch provider {
        case .claudeCode: "5-hour and weekly windows"
        case .codex: "Session and weekly windows"
        case .openCodeGo: "Rolling, weekly, and monthly windows"
        case .antigravity: "Runs agy once per poll — no credential access"
        }
    }
}
