import SwiftUI

/// Whether the full-screen player is showing.
///
/// This lives outside the view tree because ``NowPlayingBar`` is hosted by the
/// iOS 26 tab bar accessory, which the system tears down and re-creates when a
/// sheet covers the tab bar. State owned by the bar itself is lost when that
/// happens, so a sheet bound to it dismisses as soon as it finishes presenting.
/// Holding the flag here — and binding the sheet to a stable host such as
/// ``MainShellView`` — keeps the player up.
@MainActor
final class PlayerPresentation: ObservableObject {
    @Published var isShowingPlayer = false
}
