import SwiftUI
import UsageCore

/// Small capsule that names a non-`ok` state. The dot is decoration; the word is the
/// signal, so colour is never the only cue.
struct StatusBadge: View {
    let status: ProviderStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 4.5, height: 4.5)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.7)
                .textCase(.uppercase)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var label: String {
        switch status {
        case .ok: "Live"
        case .stale: "Stale"
        case .needsLogin: "Sign in"
        case .notSubscribed: "No plan"
        case .notInstalled: "Not installed"
        case .rateLimited: "Limited"
        case .unsupported: "Unsupported"
        case .error: "Error"
        }
    }

    private var accessibilityText: String {
        switch status {
        case .ok: "Live"
        case .stale: "Stale, showing last known values"
        case .needsLogin: "Sign-in required"
        case .notSubscribed: "No subscription"
        case .notInstalled: "Not installed"
        case .rateLimited: "Rate limited"
        case .unsupported: "Unsupported"
        case .error(let code): "Error, \(code)"
        }
    }

    private var tint: Color {
        switch status {
        case .ok: .green
        case .stale, .notInstalled, .notSubscribed, .unsupported: .secondary
        case .needsLogin, .rateLimited: .orange
        case .error: .red
        }
    }
}

/// `MAX`, `PLUS`, `TEAM` — the plan the provider reported, never inferred.
struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(plan)
            .font(.system(size: 8.5, weight: .medium))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.055)))
    }
}

/// Provenance marker for numbers that are not a live server reading.
struct SourceBadge: View {
    let source: Source

    var body: some View {
        Text(label)
            .font(.system(size: 8.5, weight: .medium))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var label: String {
        switch source {
        case .api: "Live"
        case .localLogs: "Estimated"
        case .cache: "Cached"
        }
    }
}
