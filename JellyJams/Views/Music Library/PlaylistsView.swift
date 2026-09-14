import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject var model: PagedItems

    var body: some View {
        ItemGrid(model: model, emptyMessage: "No playlists", emptySystemImage: "music.note.list")
            .navigationTitle("Playlists")
            .newPlaylistToolbarItem { await model.reload() }
            .refreshToolbarItem { await model.reload() }
            .task(id: model.query) { await model.load(from: session.library) }
            .refreshable { Task {await model.reload() }}
    }
}
