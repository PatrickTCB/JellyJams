#if os(iOS)
import SwiftUI

/// Gives iOS the same ⌘, shortcut macOS gets for free from its `Settings`
/// scene, so hardware keyboards on iPad reach settings without the menu.
struct SettingsCommands: Commands {
    @ObservedObject var presentation: SettingsPresentation

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { presentation.isShowingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
