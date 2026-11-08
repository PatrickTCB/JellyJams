import SwiftUI

/// A home tile for a Jelly Jams Backend mixtape: a tap starts it playing,
/// matching the Mixtapes screen, rather than opening the playlist. The name is
/// shown without the ending the backend identifies its output by.
struct MixtapeTile: View {
    let mixtape: BaseItemDto

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        HomeItemTile(item: mixtape, title: preferences.mixtapeName(for: mixtape)) { _ in
            play()
        }
    }

    /// The tracks are fetched on tap, so a row of mixtapes costs nothing until
    /// one of them is played.
    private func play() {
        MixtapePlayback.play(
            mixtape,
            mixtapeName: preferences.mixtapeName(for: mixtape),
            library: session.library,
            player: player,
            playlistStore: playlistStore
        )
    }
}

/// Plays a mixtape: its tracks are resolved on demand, so a row of mixtapes
/// costs nothing until one of them plays, and a failure is reported through
/// the root-hosted action alert. Shared by the mixtape tiles and the pinned-
/// row flow that plays a re-resolved mixtape pin on tap.
@MainActor
enum MixtapePlayback {
    static func play(
        _ mixtape: BaseItemDto,
        mixtapeName: String,
        library: LibraryRepository,
        player: PlayerController,
        playlistStore: PlaylistStore
    ) {
        Task {
            do {
                let tracks = try await library.tracks(for: mixtape)
                guard !tracks.isEmpty else {
                    throw JellyfinError.emptyCollection(mixtapeName)
                }
                player.play(tracks)
            } catch {
                playlistStore.presentActionError(error.userFacingMessage)
            }
        }
    }
}
