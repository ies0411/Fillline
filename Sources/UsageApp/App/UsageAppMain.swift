import SwiftUI

/// Menu-bar-only app: no dock icon (`LSUIElement` in the generated Info.plist), one
/// popover, one Settings window.
@main
@MainActor
struct UsageAppMain: App {
    @State private var model: AppModel

    init() {
        // Documentation render (issue #6): when `FILLLINE_RENDER_SHOTS` names a directory, the
        // process draws the real popover offscreen and exits before any scene — and therefore
        // any menu-bar item — exists. With the variable unset this is the ordinary launch.
        if let directory = ScreenshotRenderer.requestedDirectory {
            ScreenshotRenderer.runAndExit(directory: directory)
        }
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
