import SwiftUI

/// Right-click (macOS) and long-press (iOS / iPadOS) actions for a library
/// collection tile — album, artist, playlist or genre.
///
/// The item's songs are resolved lazily, only once an action is chosen, so a
/// grid of hundreds of tiles costs no extra requests.
struct ItemContextMenu: ViewModifier {
    let item: BaseItemDto

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var favourites: FavouriteStore

    @State private var isPresentingNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var errorMessage: String?

    private enum CollectionAction {
        case play
        case shuffle
        case playNext
        case addToQueue
        case addToPlaylist(id: String)
        case newPlaylist(name: String)
    }

    /// Playlists a collection can be added to. A playlist can't be added to
    /// itself.
    private var destinationPlaylists: [BaseItemDto] {
        playlistStore.playlists.filter { $0.id != nil && $0.id != item.id }
    }

    func body(content: Content) -> some View {
        content
            .contextMenu { menuItems }
            .onAppear { playlistStore.refreshIfNeeded() }
            .alert("New Playlist", isPresented: $isPresentingNewPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
                Button("Create") {
                    perform(.newPlaylist(name: newPlaylistName))
                    newPlaylistName = ""
                }
            } message: {
                Text("Create a playlist from the songs in “\(item.displayName)”.")
            }
            .alert(
                "Couldn’t Complete Action",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    // MARK: - Menu

    @ViewBuilder private var menuItems: some View {
        Button { perform(.play) } label: { Label("Play", systemImage: "play.fill") }
        Button { perform(.shuffle) } label: { Label("Shuffle", systemImage: "shuffle") }
        Button { perform(.playNext) } label: { Label("Play Next", systemImage: "text.insert") }
        Button { perform(.addToQueue) } label: { Label("Add to Queue", systemImage: "text.append") }

        Divider()

        Menu {
            Button {
                newPlaylistName = item.displayName
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

        Divider()

        Button { favourites.toggle(item) } label: {
            Label(
                favourites.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites",
                systemImage: favourites.isFavourite(item) ? "heart.slash" : "heart"
            )
        }
        .disabled(favourites.isBusy(item))
    }

    // MARK: - Actions

    /// Presentations raised in the same run loop turn as a dismissing menu or
    /// alert are swallowed, so anything that shows an alert waits for the
    /// previous presentation to leave the screen first.
    private func presentNewPlaylistPrompt() {
        Task {
            await Self.waitForPresentationDismissal()
            isPresentingNewPlaylist = true
        }
    }

    private func present(error message: String?) {
        Task {
            await Self.waitForPresentationDismissal()
            errorMessage = message
        }
    }

    private static func waitForPresentationDismissal() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func perform(_ action: CollectionAction) {
        guard let client = session.client else {
            present(error: JellyfinError.notAuthenticated.errorDescription)
            return
        }
        if case .newPlaylist(let name) = action,
           name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            present(error: JellyfinError.emptyPlaylistName.errorDescription)
            return
        }

        Task {
            do {
                let tracks = try await client.tracks(for: item)
                guard !tracks.isEmpty else {
                    throw JellyfinError.emptyCollection(item.displayName)
                }
                switch action {
                case .play:
                    player.play(tracks)
                case .shuffle:
                    player.play(tracks, shuffled: true)
                case .playNext:
                    player.playNext(tracks)
                case .addToQueue:
                    player.addToQueue(tracks)
                case .addToPlaylist(let playlistId):
                    try await playlistStore.add(itemIds: tracks.compactMap(\.id),
                                                toPlaylistWithId: playlistId)
                case .newPlaylist(let name):
                    try await playlistStore.createPlaylist(named: name,
                                                           itemIds: tracks.compactMap(\.id))
                }
            } catch {
                present(error: error.userFacingMessage)
            }
        }
    }
}

extension View {
    /// Adds the shared library item actions as a context menu (right-click on
    /// macOS, long-press on iOS and iPadOS).
    func itemContextMenu(for item: BaseItemDto) -> some View {
        modifier(ItemContextMenu(item: item))
    }
}
