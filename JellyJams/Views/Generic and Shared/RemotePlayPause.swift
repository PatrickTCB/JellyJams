import SwiftUI

/// The action the Siri Remote's play/pause button performs for whatever
/// holds focus when the player has nothing loaded — an album tile plays its
/// album, a song row plays its song. Published by focusable items through
/// ``View/remotePlayAction(_:)`` and read by ``RemotePlayPauseModifier``.
/// With a track loaded — playing or paused — the button is transport only
/// and the focused action is ignored.
struct RemotePlayActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var remotePlayAction: (() -> Void)? {
        get { self[RemotePlayActionKey.self] }
        set { self[RemotePlayActionKey.self] = newValue }
    }
}

/// Answers the Siri Remote's play/pause button.
///
/// tvOS delivers that press to the foreground app as a press event, which
/// SwiftUI surfaces as `onPlayPauseCommand`. ``NowPlayingCenter``'s remote
/// commands never see it: they arrive from outside the app — background
/// playback, Control Centre, the TV Remote app, Siri — so a listener
/// pressing play/pause while looking at the app needs this handler instead.
///
/// With nothing loaded, a focused item that published a
/// ``FocusedValues/remotePlayAction`` gets that action — play/pause on an
/// album tile starts the album. Once a track is loaded, playing or paused,
/// the button only ever toggles that playback: pausing to browse and
/// pressing play/pause to resume must not start whatever tile focus happens
/// to rest on.
///
/// A sheet is its own presentation: a press inside one never reaches a
/// handler on the presenting screen. Every screen the listener can be
/// looking at therefore wears this — the shell once at its root, and each
/// sheet on its own content.
private struct RemotePlayPauseModifier: ViewModifier {
    @Environment(PlayerController.self) private var player
    @FocusedValue(\.remotePlayAction) private var focusedPlayAction

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.onPlayPauseCommand {
            if let focusedPlayAction, player.currentItem == nil {
                focusedPlayAction()
            } else {
                player.togglePlayPause()
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Toggles playback from the Siri Remote's play/pause button — tvOS
    /// only, a no-op elsewhere. Apply to each presentation's root (the app
    /// shell and every sheet): a press inside a sheet never reaches the
    /// presenting screen's handler.
    ///
    /// With nothing loaded, a focused view that published a
    /// ``remotePlayAction(_:)`` gets that action instead of the toggle.
    func remotePlayPause() -> some View {
        modifier(RemotePlayPauseModifier())
    }

    /// Publishes what the Siri Remote's play/pause button does while this
    /// view holds focus and the player has nothing loaded — an album tile
    /// plays its album, a song row plays its song. No-op on platforms without
    /// the press, so the value is never published where nothing reads it.
    func remotePlayAction(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        focusedValue(\.remotePlayAction, action)
        #else
        self
        #endif
    }
}