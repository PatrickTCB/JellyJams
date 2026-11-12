import SwiftUI

#if os(iOS)
extension View {
    /// Attaches the mini player to the tab bar as a bottom accessory, floating
    /// it above the tab bar and letting it collapse alongside the bar as the
    /// user scrolls.
    func nowPlayingTabAccessory() -> some View {
        modifier(NowPlayingTabAccessoryModifier())
    }
}

/// Installs the accessory unconditionally and toggles it with `isEnabled` so
/// the tab bar reserves no space while nothing is playing.
///
/// The `isEnabled:` overload matters: applying `tabViewBottomAccessory` inside
/// an `if` instead re-creates the tab view when playback starts, which throws
/// away every tab's `@State` — including its navigation stack.
private struct NowPlayingTabAccessoryModifier: ViewModifier {
    @EnvironmentObject private var player: PlayerController

    func body(content: Content) -> some View {
        content
            .tabViewBottomAccessory(isEnabled: player.currentItem != nil) {
                NowPlayingTabAccessory()
            }
            .tabBarMinimizeBehavior(.onScrollDown)
    }
}

/// The mini player as an iOS 26 tab bar accessory, condensed when the tab bar
/// minimises on scroll.
struct NowPlayingTabAccessory: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if player.currentItem != nil {
            NowPlayingBar(presentation: placement == .inline ? .accessoryInline : .accessory)
        }
    }
}
#endif
