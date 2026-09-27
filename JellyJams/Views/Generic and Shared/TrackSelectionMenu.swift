import SwiftUI

/// Toolbar actions for the tracks selected in a list — Play Next, Add to
/// Queue, Add to Playlist — applied to every selected track at once, in list
/// order. The hosting screen shows it only while something is selected, the
/// same condition-under-which pattern as playlist detail's "Remove N".
///
/// Only the three actions that make sense for any track list live here;
/// selection-specific ones (removing playlist entries) stay with the screen
/// that owns them.
struct TrackSelectionMenu: View {
    /// The selected tracks in list order.
    let tracks: [BaseItemDto]

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playlistStore: PlaylistStore

    @State private var isPresentingNewPlaylist = false
    @State private var newPlaylistName = ""

    private var itemIds: [String] { tracks.compactMap(\.id) }

    var body: some View {
        Menu {
            Button { player.playNext(tracks) } label: { Label("Play Next", systemImage: "text.insert") }
            Button { player.addToQueue(tracks) } label: { Label("Add to Queue", systemImage: "text.append") }

            Menu {
                Button {
                    presentNewPlaylistPrompt()
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }

                if !destinationPlaylists.isEmpty {
                    Divider()
                    ForEach(destinationPlaylists) { playlist in
                        Button(playlist.displayName) {
                            if let id = playlist.id { perform(.addToPlaylist(id: id)) }
                        }
                    }
                }
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        } label: {
            Label("\(tracks.count) Selected", systemImage: "checkmark.circle")
        }
        .onAppear { playlistStore.refreshIfNeeded() }
        .alert("New Playlist", isPresented: $isPresentingNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                perform(.newPlaylist(name: newPlaylistName))
                newPlaylistName = ""
            }
        } message: {
            Text("Create a playlist containing \(Format.songCount(tracks.count)).")
        }
    }

    // MARK: - Playlist Actions

    private var destinationPlaylists: [BaseItemDto] {
        playlistStore.playlists.filter { $0.id != nil }
    }

    /// Presentations raised in the same run loop turn as a dismissing menu
    /// are swallowed, so a prompt opened straight from a menu button waits
    /// for the menu to leave the screen first. Action errors don't need
    /// this — they surface through the root-hosted alert, which no dismissal
    /// can compete with.
    private func presentNewPlaylistPrompt() {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            isPresentingNewPlaylist = true
        }
    }

    private func perform(_ action: TrackAction) {
        guard !itemIds.isEmpty else {
            playlistStore.presentActionError(JellyfinError.missingItemIdentifier.errorDescription)
            return
        }
        Task {
            do {
                switch action {
                case .addToPlaylist(let playlistId):
                    try await playlistStore.add(itemIds: itemIds, toPlaylistWithId: playlistId)
                case .newPlaylist(let name):
                    try await playlistStore.createPlaylist(named: name, itemIds: itemIds)
                }
            } catch {
                playlistStore.presentActionError(error.userFacingMessage)
            }
        }
    }

    private enum TrackAction {
        case addToPlaylist(id: String)
        case newPlaylist(name: String)
    }
}
