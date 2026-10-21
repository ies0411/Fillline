import SwiftUI
import UsageCore

// MARK: - Data

/// One card's history trail: the samples to draw, plus the window they describe.
///
/// Bundling the window's name with the samples is deliberate. The line has no visible label,
/// so the accessibility summary is the only place it says *what* it is drawing; keeping both
/// in one value means the spoken label and the drawn series cannot drift apart.
struct SparklineData: Sendable, Equatable {
    /// How far back the line reaches. Matches `SnapshotHistory`'s default retention (7 days)
    /// and the product's longest horizon: "over the last 7 days".
    static let span: TimeInterval = 7 * 24 * 3600

    /// The window's own label ("Weekly", "Monthly"), used only for speech.
    let windowLabel: String
    /// Ascending by `capturedAt`, exactly as `SnapshotHistory.series(for:window:since:)`
    /// returns it. Never sorted, padded or de-duplicated here: the core owns those invariants.
    let samples: [HistorySample]
}

// MARK: - Sparkline

/// The trail behind a card's numbers: **remaining** fraction over the last seven days.
///
/// Design rules (docs/design/ui.md §12):
/// - One 1.15 pt line, one low-alpha area fill in the same tint. No axis, grid, legend,
///   markers or gradient.
/// - The y axis is fixed to `0...1` remaining, the same domain as the meter above it, so the
///   line is never rescaled: a two-point wiggle can't be drawn as a cliff.
/// - The x axis is the real seven days, oldest at the left edge and `now` at the right. The
///   line therefore starts short and grows leftward as history accumulates — it is never
///   stretched to fill the box.
/// - Fewer than two samples renders nothing at all. No flat line, no placeholder box, no
///   invented points; a 2-sample line is drawn as the one segment it really is.
struct Sparkline: View {
    let data: SparklineData
    let now: Date

    /// Short on purpose: the sparkline is a footnote to the meter, not a second chart.
    private static let height: CGFloat = 20
    /// Half a stroke stays inside the box, so the line is never clipped at the extremes.
    private static let inset: CGFloat = 1
    /// Extra breathing room top and bottom, so a healthy line cannot read as a rule under
    /// the meter above it.
    private static let verticalInset: CGFloat = 2.5
    private static let lineWidth: CGFloat = 1.15

    private var samples: [HistorySample] { data.samples }

    var body: some View {
        if samples.count >= 2 {
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .frame(height: Self.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(summary))
        }
    }

    // MARK: Drawing

    private func draw(in context: GraphicsContext, size: CGSize) {
        let points = plottedPoints(in: size)
        guard points.count >= 2 else { return }

        var line = Path()
        line.move(to: points[0])
        for point in points.dropFirst() {
            line.addLine(to: point)
        }

        // One subtle fill under the curve. With a fixed 0...1 domain it is what carries the
        // level: a card that has spent 20 points of its quota shows a visibly emptier box
        // even when the stroke itself only moves a few points.
        let baseline = size.height - Self.verticalInset
        var area = line
        area.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseline))
        area.addLine(to: CGPoint(x: points[0].x, y: baseline))
        area.closeSubpath()

        context.fill(area, with: .color(tint.opacity(0.10)))
        context.stroke(
            line,
            with: .color(tint),
            style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func plottedPoints(in size: CGSize) -> [CGPoint] {
        let inset = Self.inset
        let width = max(0, size.width - inset * 2)
        let height = max(0, size.height - Self.verticalInset * 2)
        let start = now.addingTimeInterval(-SparklineData.span)

        return samples.map { sample in
            let elapsed = sample.capturedAt.timeIntervalSince(start) / SparklineData.span
            let x = inset + width * min(max(elapsed, 0), 1)
            let remaining = min(max(sample.remainingFraction, 0), 1)
            return CGPoint(x: x, y: Self.verticalInset + height * (1 - remaining))
        }
    }

    // MARK: Colour

    /// No new hue: the line is the card's own ink when healthy and the card's warning colour
    /// once that window is already in the amber/red zone — the same rule as `MeterBar`, so a
    /// card never shows a grey line above an amber meter.
    private var tint: Color {
        switch severity {
        case .normal: Color.primary.opacity(0.45)
        case .warning: Color.orange.opacity(0.8)
        case .critical: Color.red.opacity(0.85)
        }
    }

    private var severity: RemainingSeverity {
        UsageFormat.severity(remainingFraction: samples.last?.remainingFraction ?? 1)
    }

    // MARK: Accessibility

    /// The trend is the one thing the card's numbers cannot say, so this view is an element
    /// of its own rather than decoration: direction, distance, the window, and the period
    /// the line actually covers.
    private var summary: String {
        guard let first = samples.first, let last = samples.last else {
            return "\(data.windowLabel) remaining trend"
        }

        let points = Int(((last.remainingFraction - first.remainingFraction) * 100).rounded())
        let direction: String
        if points <= -1 {
            direction = "down \(abs(points)) points"
        } else if points >= 1 {
            direction = "up \(points) points"
        } else {
            direction = "steady"
        }

        let covered = max(0, now.timeIntervalSince(first.capturedAt))
        let period =
            covered < 60
            ? "the last minute"
            : "the last \(UsageFormat.spokenDuration(covered))"

        return
            "\(data.windowLabel) remaining trend over \(period), \(direction), now \(UsageFormat.remainingText(last.remainingFraction))"
    }
}
