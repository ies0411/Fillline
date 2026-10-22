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
        .frame(width: Self.popoverWidth)
        .animation(.easeInOut(duration: 0.2), value: model.hasCompletedOnboarding)
        .task { model.start() }
    }

    // MARK: Dashboard

    /// The popover is a fixed 340 pt wide column; only its height changes with the cards.
    static let popoverWidth: CGFloat = 340

    /// Ceiling for the provider stack, in points. Four cards (~674 pt) sit under it, so a
    /// four-provider popover does not scroll and comes out at the same size and layout it had
    /// before the scroll view existed; a fifth card (~+140 pt) crosses it and the stack
    /// scrolls instead of growing past the bottom of a 900 pt display (issue #15,
    /// docs/design/ui.md §2).
    ///
    /// **708, not 720.** The 28 pt fade below turns a cut card into a dissolving one, but at
    /// 720 the six-provider cut still landed 9 pt into the fifth card's "65%" numeral, leaving
    /// the tops of the digits legible through the fade. Moving the cut 12 pt up puts it in the
    /// empty 14 pt band between that card's title and its first numeral, so nothing is sliced.
    /// The number is measured, not picked: at 720 the clip landed on content y = 1439 (2× px
    /// below the stack's top edge) while the numeral occupied 1421–1451, so any ceiling in
    /// 696.5–710 pt clears the digits; 708 leaves 2.5 pt of margin under them. That is a 12 pt
    /// move, inside the 16 pt the review allowed (docs/design/ui.md §2).
    static let cardStackCeiling: CGFloat = 708

    /// Height of the fade at each edge of the stack when the cards fit under the ceiling.
    /// Ten points sits entirely inside the list's own top (12 pt) and bottom (10 pt) padding,
    /// so a fitted stack fades empty space and is pixel-for-pixel what it was before the
    /// scroll view existed — a four-provider popover does not dim its last card.
    static let fittedEdgeFade: CGFloat = 10

    /// Height of the fade at the bottom edge when the cards do *not* fit.
    ///
    /// Ten points is not enough once content is cut: a 20 pt headline numeral is ~15 pt tall,
    /// so the clip can land in the middle of its digits, and a 10 pt fade leaves the top of
    /// that numeral at ~80 % opacity — a sliced glyph, which reads as broken rather than as
    /// "more below". At 28 pt the same numeral enters the fade at ~30 % and reaches zero well
    /// before the clip, so the partially visible card dissolves (#15 review).
    static let overflowEdgeFade: CGFloat = 28

    private var dashboard: some View {
        TimelineView(.periodic(from: Date.now, by: 30)) { context in
            VStack(spacing: 0) {
                header(now: context.date)

                Divider()
                    .opacity(0.6)

                content(now: context.date)

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
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)
        } else {
            cardStack(now: now)
        }
    }

    /// The provider stack is the only part of the popover that grows with the number of
    /// providers, so it is the only part that scrolls: the header, the dividers and the footer
    /// stay put and the cards move under them.
    ///
    /// Under the ceiling (four cards, ~674 pt) the stack lays out exactly as it did before the
    /// scroll view existed, so nothing moves and no indicator appears; a fifth card crosses
    /// the 708 pt ceiling and the stack scrolls instead of pushing the footer off a 900 pt
    /// display.
    private func cardStack(now: Date) -> some View {
        Group {
            if cardStackScrolls {
                ScrollView(.vertical) {
                    cardList(now: now)
                }
            } else {
                // Offscreen-render path: the same list, clamped to the same ceiling and drawn
                // from the top. See `cardStackScrolls`.
                cardList(now: now)
                    .frame(maxHeight: Self.cardStackCeiling, alignment: .top)
                    .clipped()
            }
        }
        .frame(maxHeight: Self.cardStackCeiling)
        .mask { scrollEdgeMask }
        // The fade height depends on whether anything is cut, which is measured from the
        // laid-out list rather than inferred from the provider count: cards differ in height
        // by state (a stale footer, a sign-in body), so "five providers" is not the same as
        // "taller than the ceiling". The measurement runs in both paths — the scroll view and
        // the offscreen clip — because `cardList` reports it either way.
        .onPreferenceChange(CardStackContentHeight.self) { height in
            stackContentHeight = height
        }
        .onAppear { appeared = true }
    }

    /// The edges fade out, which is what says "there is more above/below this edge" when a
    /// card is cut by the ceiling.
    ///
    /// The bottom fade is conditional. When the stack fits it stays at `fittedEdgeFade`
    /// (10 pt, inside the list's own 10 pt bottom padding), so a fitted stack looks untouched.
    /// When the stack is taller than the ceiling it grows to `overflowEdgeFade` (28 pt), so the
    /// card under the clip dissolves while it is still faint instead of showing the top half of
    /// a headline numeral. The top edge keeps 10 pt: at rest the list starts 12 pt in, so
    /// nothing is under it, and growing it would dim the first card's own top edge.
    private var scrollEdgeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.fittedEdgeFade)

            Rectangle()
                .fill(Color.black)

            LinearGradient(
                colors: [.black, .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: bottomEdgeFade)
        }
    }

    /// 28 pt while the stack is cut, 10 pt (the value the fitted layout has always used) while
    /// it fits.
    private var bottomEdgeFade: CGFloat {
        stackOverflows ? Self.overflowEdgeFade : Self.fittedEdgeFade
    }

    /// Measured in `cardList`, not guessed: the laid-out height of the padded card list
    /// against the ceiling.
    private var stackOverflows: Bool {
        stackContentHeight > Self.cardStackCeiling + 0.5
    }

    /// Extra bottom padding the taller fade needs, so the fade only ever covers empty space.
    /// The list's own 10 pt bottom padding covers the fitted fade exactly; the overflow fade
    /// is 18 pt taller, so the end of the scrolling content gets 18 pt more room. Without it,
    /// scrolling to the end would leave the last card's bottom edge inside the fade and dim a
    /// card that has nothing below it.
    private var bottomContentInset: CGFloat {
        stackOverflows ? Self.overflowEdgeFade - Self.fittedEdgeFade : 0
    }

    private func cardList(now: Date) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(model.orderedProviders.enumerated()), id: \.element) {
                index,
                provider in
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
        // The 12 pt above the first card is the old outer 4 pt plus the stack's own 8 pt, so
        // the unscrolled layout is unchanged. The bottom padding lives *inside* the scrolling
        // content, which is what keeps the last card's margin from being clipped when the
        // stack is scrolled to its end; it grows with the fade (`bottomContentInset`) so the
        // taller overflow fade still covers empty space only.
        //
        // Width is pinned to the popover width rather than left flexible so a scroll indicator
        // can never take width away from a card: it is drawn over the 12 pt gutter the cards
        // already leave free (issue #15).
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, Self.fittedEdgeFade + bottomContentInset)
        .frame(width: Self.popoverWidth)
        // Reports the list's laid-out height, which is what decides whether the stack is cut.
        // A background, not an overlay: it must not take a pixel or a hit test from a card.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .allowsHitTesting(false)
                    .preference(
                        key: CardStackContentHeight.self,
                        value: proxy.size.height
                    )
            }
        }
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
    @Environment(\.cardStackScrolls) private var cardStackScrolls

    /// Laid-out height of the card list, published by the `GeometryReader` in `cardList`.
    /// 0 before the first layout, which reads as "fits" and is corrected in the same frame
    /// the list is measured.
    @State private var stackContentHeight: CGFloat = 0
    @State private var appeared = false
}

// MARK: - Stack measurement

/// Carries the card list's laid-out height up to the popover, so the bottom fade can tell a
/// fitted stack from a cut one. A preference rather than a fixed constant because card heights
/// vary with state: a stale footer or a sign-in body changes a card by 20–60 pt, so the
/// provider count alone does not say whether the stack is taller than the ceiling.
private struct CardStackContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Offscreen-render seam

/// Whether the provider stack is drawn inside a real `ScrollView`.
///
/// `ImageRenderer` cannot rasterize a `ScrollView` — it is AppKit-composited, so its content
/// comes out blank, the same failure the popover buttons hit with `.borderless` (see
/// `Views/PopoverButtonStyles.swift`). The documentation renderer therefore turns this off and
/// gets a container that clamps to the same ceiling and clips instead of scrolling, so the
/// screenshots still show the shipping layout. It is never off in the app: the popover is the
/// only caller that leaves the default alone.
private struct CardStackScrollsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var cardStackScrolls: Bool {
        get { self[CardStackScrollsKey.self] }
        set { self[CardStackScrollsKey.self] = newValue }
    }
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
