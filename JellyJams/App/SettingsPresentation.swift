import SwiftUI

/// Whether the settings sheet is showing.
///
/// macOS has a `Settings` scene, so nothing there needs this: `SettingsLink`
/// and the app menu's ⌘, item open the settings window directly. iOS has no
/// such scene, so ``MainShellView`` presents ``SettingsView`` as a sheet
/// instead.
///
/// The flag lives outside the view tree so that every affordance that can raise
/// settings — an ``AccountMenu`` in any tab's toolbar, or ``SettingsCommands``
/// — drives one sheet hosted on a view that stays put, rather than each
/// toolbar item owning a sheet of its own.
@MainActor
final class SettingsPresentation: ObservableObject {
    @Published var isShowingSettings = false
}
