import AppKit
import SwiftUI
import UsageCore

/// Documentation screenshots (issue #6) are rendered **offscreen**, not captured from the
/// screen: the reference machine denies `screencapture` (TCC / Screen Recording), and the
/// images have to be of the shipping views — never of a mockup (AGENTS §7.3). `ImageRenderer`
/// draws the same `PopoverView` the app runs, at 2×, straight into a PNG.
@MainActor
enum ScreenshotRenderer {
    /// Set to an output directory to turn a normal launch into a render-and-exit run.
    static let environmentKey = "FILLLINE_RENDER_SHOTS"

    /// The directory named by `FILLLINE_RENDER_SHOTS`, or `nil` during an ordinary launch.
    static var requestedDirectory: URL? {
        guard
            let raw = ProcessInfo.processInfo.environment[environmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    // MARK: - Entry point

    /// Renders every state and appearance, then exits. `Never` on purpose: the caller is the
    /// app's initializer, and a documentation render must not fall through to the menu bar.
    static func runAndExit(directory: URL) -> Never {
        // "Do not leave a menu-bar item or a Dock icon behind": the process exists only to draw.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        do {
            try writeAll(to: directory)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("screenshot render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Rendering

    static func writeAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let states: [(name: String, model: AppModel)] = [
            ("healthy", AppModel(documentation: ScreenshotFixtures.healthy())),
            ("degraded", AppModel(documentation: ScreenshotFixtures.degraded())),
            // Six providers: the stack is taller than `PopoverView.cardStackCeiling`, so the
            // render is clamped and the bottom fade switches to its overflow height (#15).
            // This is also the render the fade review checked: nothing in the fifth card is
            // sliced, because the cut was measured to land in the band between its title and
            // its first numeral.
            ("crowded", AppModel(documentation: ScreenshotFixtures.crowded())),
        ]

        for state in states {
            for scheme in [ColorScheme.light, .dark] {
                let fileName = "app-popover-\(state.name)-\(appearanceName(of: scheme)).png"
                try write(
                    model: state.model,
                    scheme: scheme,
                    to: directory.appendingPathComponent(fileName, isDirectory: false)
                )
            }
        }
    }

    /// Draws one popover. Width is the view's own 340 pt; the height follows the content, so a
    /// taller degraded stack is not squeezed to fit a fixed frame.
    private static func write(model: AppModel, scheme: ColorScheme, to url: URL) throws {
        // Dynamic `NSColor`s (window background, labels) resolve through the app's appearance,
        // so it is switched for the duration of the render as well as in the environment.
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previousAppearance }

        let content = PopoverView()
            .environment(model)
            .environment(\.colorScheme, scheme)
            .environment(\.cardStackScrolls, false)
            .frame(width: PopoverView.popoverWidth)
            .background(surface(for: scheme))

        // Known limitations (macOS 26): `ImageRenderer` draws its "unsupported content"
        // placeholder — or nothing at all — for views composited by AppKit, which is what
        // `.buttonStyle(.borderless)`, `.link` and `ScrollView` are. The popover's controls
        // therefore use `GhostButtonStyle` and `LinkButtonStyle`
        // (`Views/PopoverButtonStyles.swift`), and `\.cardStackScrolls` swaps the scroll view
        // for a clipping container of the same size, so every pixel in these PNGs — including
        // the buttons and the crowded stack — comes from the shipping views.
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: PopoverView.popoverWidth, height: nil)

        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw RenderError.noImage(url.lastPathComponent)
        }

        try png.write(to: url, options: .atomic)
        print(
            "\(url.lastPathComponent)  \(bitmap.pixelsWide)×\(bitmap.pixelsHigh) px  \(png.count) bytes"
        )
    }

    // MARK: - Helpers

    /// The popover normally sits on the menu-bar window's material; `ImageRenderer` has no
    /// window, so the same surface is painted here. `Color(nsColor: .windowBackgroundColor)`
    /// is deliberately not used: NSColor-based colours resolve against the process appearance
    /// and would paint a light rectangle behind white dark-mode text.
    private static func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.12, green: 0.12, blue: 0.125)
            : Color(red: 0.93, green: 0.93, blue: 0.93)
    }

    private static func appearanceName(of scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }

    enum RenderError: Error, CustomStringConvertible {
        case noImage(String)

        var description: String {
            switch self {
            case .noImage(let name): "could not rasterize \(name)"
            }
        }
    }
}
