import SwiftUI

extension View {
    /// Docks the persistent ``NowPlayingBar`` below this view.
    ///
    /// The bar renders nothing while the queue is empty, so the inset collapses
    /// to zero height and the layout is untouched until playback starts.
    ///
    /// Apply this to a tab's *content* rather than to a `TabView`: an inset
    /// added around a tab view is laid out outside the tab bar, so the bar ends
    /// up covering it.
    func nowPlayingDock() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBar()
        }
    }
}

#if os(iOS)
extension View {
    /// Docks the mini player inside a tab's content on OS versions without the
    /// tab bar accessory API. On iOS 26.1+ the tab view hosts the bar via
    /// ``nowPlayingTabAccessory()`` instead, so this is a no-op there.
    @ViewBuilder func nowPlayingTabContentDock() -> some View {
        if #available(iOS 26.1, *) {
            self
        } else {
            nowPlayingDock()
        }
    }

    /// Attaches the mini player to the tab bar as a bottom accessory on iOS
    /// 26.1+, floating it above the tab bar and letting it collapse alongside
    /// the bar as the user scrolls.
    @ViewBuilder func nowPlayingTabAccessory() -> some View {
        if #available(iOS 26.1, *) {
            modifier(NowPlayingTabAccessoryModifier())
        } else {
            self
        }
    }
}

/// Installs the accessory unconditionally and toggles it with `isEnabled` so
/// the tab bar reserves no space while nothing is playing.
///
/// The `isEnabled:` overload matters: applying `tabViewBottomAccessory` inside
/// an `if` instead re-creates the tab view when playback starts, which throws
/// away every tab's `@State` — including its navigation stack.
@available(iOS 26.1, *)
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
@available(iOS 26.0, *)
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
