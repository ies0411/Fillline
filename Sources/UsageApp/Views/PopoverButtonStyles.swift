import SwiftUI

// MARK: - Ghost

/// The popover's quiet icon/text button: the caller's label, plus a faint highlight on hover.
///
/// It exists because `ImageRenderer` cannot rasterise AppKit-composited button styles. The
/// documentation renders (`Scripts/screenshots.sh`) draw `.borderless` as SwiftUI's
/// "unsupported content" placeholder — a yellow box with a red slash — so every icon and text
/// button in the popover uses this style instead: same label, same font and foreground, same
/// hit area, with the hover, pressed and focus feedback drawn by SwiftUI itself.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration)
    }
}

private struct GhostButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovering = false

    /// Matches the 6 pt corners of the surrounding privacy tiles, so a hovered button reads as
    /// the same family of shape rather than as a new one.
    private static let cornerRadius: CGFloat = 6

    var body: some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.45)
            .background {
                // The highlight is drawn 2.5 pt outside the label. A background never takes part
                // in layout, so the 18 pt hit area and every gap in the header stay exactly as
                // they are — only the tint gets the breathing room a rounded rect needs.
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(highlight))
                    .padding(-2.5)
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.5)
                        .padding(-2.5)
                }
            }
            .onHover { isHovering = $0 }
    }

    /// Rest → 6 % primary; pressed is a step stronger. Nothing moves, nothing resizes.
    private var highlight: Double {
        configuration.isPressed ? 0.12 : (isHovering ? 0.06 : 0)
    }
}

// MARK: - Link

/// A link-shaped button: accent text, underlined only while hovered.
///
/// Same reason as `GhostButtonStyle`: `.link` is AppKit-composited too and rasterises as the
/// same placeholder, so the two "open Settings" links under the cards draw their own underline.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkButtonBody(configuration: configuration)
    }
}

private struct LinkButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .underline(isHovering)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 }
    }
}
