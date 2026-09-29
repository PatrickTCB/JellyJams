import SwiftUI

/// A home tile for an AudioMuse-AI station: a tap starts it playing, matching
/// the AI Radio screen, rather than opening the playlist. The name is shown
/// without the ending that identifies it as generated.
struct StationTile: View {
    let station: BaseItemDto

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        HomeItemTile(item: station, title: preferences.aiRadioStationName(for: station)) { _ in
            play()
        }
    }

    /// The tracks are fetched on tap, so a row of stations costs nothing until
    /// one of them is played.
    private func play() {
        Task {
            do {
                let tracks = try await session.library.tracks(for: station)
                guard !tracks.isEmpty else {
                    throw JellyfinError.emptyCollection(preferences.aiRadioStationName(for: station))
                }
                player.play(tracks)
            } catch {
                playlistStore.presentActionError(error.userFacingMessage)
            }
        }
    }
}