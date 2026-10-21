import SwiftUI

/// Menu-bar-only app: no dock icon (`LSUIElement` in the generated Info.plist), one
/// popover, one Settings window.
@main
@MainActor
struct UsageAppMain: App {
    @State private var model = AppModel()

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
