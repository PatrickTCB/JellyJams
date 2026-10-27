import SwiftUI

/// The mixtapes the Jelly Jams Backend builds, listed as things to press play
/// on.
///
/// A tap plays one instead of opening it: these are generated rather than
/// assembled by hand, so listening is what the user wants from them, and the
/// contents are only ever a snapshot of the last generation. The playlist
/// itself is still reachable through the context menu's "View", and every
/// mixtape keeps the usual play, shuffle and queue actions.
///
/// Mixtapes are shown under their own names, without the ending the backend
/// puts on them — see ``mixtapeName(_:)``.
struct MixtapesView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @ObservedObject var model: PagedItems

    @State private var isComposingTape = false
    @State private var isShowingConfiguredTapes = false

    /// The split that picks the backend's mixtapes out of the library: what
    /// the list fetches with, and what takes the backend's ending back off
    /// the names it shows.
    private var nameFilter: PlaylistNameFilter? {
        preferences.playlistNameFilter(for: model.list)
    }

    private var query: LibraryQuery {
        model.query(nameFilter: nameFilter)
    }

    var body: some View {
        ItemGrid(
            model: model,
            emptyMessage: "No mixtapes",
            emptySystemImage: "recordingtape.circle.fill",
            onSelect: play,
            title: mixtapeName
        )
        .navigationTitle(LibrarySection.mixtapes.title)
        .refreshToolbarItem { await model.reload() }
        .toolbar {
            // The backend's own controls, beside the playlists they manage:
            // what tapes are set up (a read), and a new one (a write) —
            // the plus last, as on Playlists, with the tape list to its
            // left.
            ToolbarItem {
                Button { isShowingConfiguredTapes = true } label: {
                    Label("Configured Tapes", systemImage: "recordingtape.circle")
                }
            }
            ToolbarItem {
                Button { isComposingTape = true } label: {
                    Label("New Mixtape", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $isComposingTape) { MixtapeComposer() }
        .sheet(isPresented: $isShowingConfiguredTapes) { ConfiguredTapes() }
        .task(id: query) { await model.load(query, from: session.library) }
        .refreshable { Task { await model.reload() } }
    }

    /// A mixtape is called by its own name. The ending that identifies it as
    /// generated is the backend's business, and repeats on every tile of a
    /// section where nothing else exists.
    private func mixtapeName(_ mixtape: BaseItemDto) -> String {
        nameFilter?.trimmingMatchedEnding(from: mixtape.displayName) ?? mixtape.displayName
    }

    /// Starts a mixtape playing, from its first track.
    ///
    /// The tracks are fetched on tap rather than carried by the grid, which
    /// only knows the playlists — so a screen of a hundred mixtapes costs
    /// nothing until one of them is played.
    private func play(_ mixtape: BaseItemDto) {
        Task {
            do {
                let tracks = try await session.library.tracks(for: mixtape)
                guard !tracks.isEmpty else {
                    throw JellyfinError.emptyCollection(mixtapeName(mixtape))
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
