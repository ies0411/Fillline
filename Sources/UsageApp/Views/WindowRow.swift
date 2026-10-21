import SwiftUI
import UsageCore

/// One quota window: big remaining number first, reset countdown and used-% as captions.
///
/// The meter fills with **remaining** (see docs/design/ui.md): a full bar means a full
/// quota, an empty bar means the wall. The notch at 15% is the warning threshold, so the
/// fill visibly drops behind it before anything turns amber.
struct WindowRow: View {
    let window: LimitWindow
    let now: Date

    private var remaining: Double { window.remainingFraction }
    private var severity: RemainingSeverity { UsageFormat.severity(remainingFraction: remaining) }
    private var reset: UsageFormat.ResetLabel {
        UsageFormat.resetLabel(
            resetsAt: window.resetsAt,
            now: now,
            isPlaceholder: window.isPlaceholder,
            isEstimated: window.isEstimated
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormat.remainingText(remaining))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .fixedSize()

                Text(window.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if severity == .critical {
                    LowCue()
                }

                Spacer(minLength: 6)

                Text(reset.text)
                    .font(.system(size: 9.5, weight: .regular).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !reset.isResetting {
                    Text("·")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(UsageFormat.usedText(window.usedFraction))
                        .font(.system(size: 9.5, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            MeterBar(remainingFraction: remaining, severity: severity)
        }
        .animation(.easeOut(duration: 0.35), value: remaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(UsageFormat.accessibilityLabel(for: window, now: now)))
    }
}

/// Colour-blind-safe cue: the word, not just the red.
private struct LowCue: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.red)
            Text("LOW")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.red.opacity(0.14)))
        .accessibilityHidden(true)
    }
}

/// Thin meter, filled with remaining quota, with a notch at the 15% warning threshold.
struct MeterBar: View {
    let remainingFraction: Double
    let severity: RemainingSeverity

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let clamped = min(max(remainingFraction, 0), 1)
            let fillWidth = clamped > 0 ? max(2, width * clamped) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                if fillWidth > 0 {
                    Capsule()
                        .fill(fillColor)
                        .frame(width: fillWidth)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 1, height: 7)
                    .offset(x: min(max(0, width * UsageFormat.warningThreshold - 0.5), width - 1))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var fillColor: Color {
        switch severity {
        case .normal: Color.primary.opacity(0.55)
        case .warning: .orange
        case .critical: .red
        }
    }
}
