import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @ObservedObject var model: PagedItems

    /// The playlists the user made. While AI Radio is on, the ones AudioMuse-AI
    /// generated belong to that section instead and are left out of this list.
    private var query: LibraryQuery {
        model.query(nameFilter: preferences.playlistNameFilter(for: model.list))
    }

    var body: some View {
        ItemGrid(model: model, emptyMessage: "No playlists", emptySystemImage: "music.note.list")
            .navigationTitle("Playlists")
            .newPlaylistToolbarItem { await model.reload() }
            .refreshToolbarItem { await model.reload() }
            .task(id: query) { await model.load(query, from: session.library) }
            .refreshable { Task {await model.reload() }}
    }
}
