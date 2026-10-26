import SwiftUI

/// The playlists AudioMuse-AI generates, listed as radio stations.
///
/// A tap plays one instead of opening it: these are generated rather than
/// assembled by hand, so listening is what the user wants from them, and the
/// contents are only ever a snapshot of the last generation. The playlist
/// itself is still reachable through the context menu's "View", and every
/// station keeps the usual play, shuffle and queue actions.
///
/// Stations are shown under their own names, without the ending that marks
/// them as generated — see ``stationName(_:)``.
struct AIRadioView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @ObservedObject var model: PagedItems

    /// The split that picks AudioMuse-AI's playlists out of the library: what
    /// the list fetches with, and what takes the generated ending back off the
    /// names it shows.
    private var nameFilter: PlaylistNameFilter? {
        preferences.playlistNameFilter(for: model.list)
    }

    private var query: LibraryQuery {
        model.query(nameFilter: nameFilter)
    }

    var body: some View {
        ItemGrid(
            model: model,
            emptyMessage: "No AI radio stations",
            emptySystemImage: "radio",
            onSelect: play,
            title: stationName
        )
        .navigationTitle(LibrarySection.aiRadio.title)
        .refreshToolbarItem { await model.reload() }
        .task(id: query) { await model.load(query, from: session.library) }
        .refreshable { Task { await model.reload() } }
    }

    /// A station is called by its own name. The ending that identifies it as
    /// generated is the generator's business, and repeats on every tile of a
    /// section where nothing else exists.
    private func stationName(_ station: BaseItemDto) -> String {
        nameFilter?.trimmingMatchedEnding(from: station.displayName) ?? station.displayName
    }

    /// Starts a station playing, from its first track.
    ///
    /// The tracks are fetched on tap rather than carried by the grid, which
    /// only knows the playlists — so a screen of a hundred stations costs
    /// nothing until one of them is played.
    private func play(_ station: BaseItemDto) {
        Task {
            do {
                let tracks = try await session.library.tracks(for: station)
                guard !tracks.isEmpty else {
                    throw JellyfinError.emptyCollection(stationName(station))
                }
                player.play(tracks)
            } catch {
                // The root-hosted alert, as with the context menu's actions:
                // the failure lands long after the tap that caused it.
                playlistStore.presentActionError(error.userFacingMessage)
            }
        }
    }
}
