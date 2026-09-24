import SwiftUI

/// A single track row used in album detail, songs, search and queue lists.
/// The whole row is a button that starts playback via `onPlay`; secondary
/// actions live in the context menu and (on iOS) swipe actions.
struct TrackRow: View {
    let track: BaseItemDto
    var showArtwork = false
    /// Set by playlist detail views to expose "Remove from Playlist" in the
    /// context menu and (on iOS) trailing swipe actions.
    var onRemoveFromPlaylist: (() -> Void)?
    var onPlay: () -> Void

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var favourites: FavouriteStore
    @EnvironmentObject private var downloads: DownloadStore

    @State private var isPresentingNewPlaylist = false
    @State private var newPlaylistName = ""

    private var isCurrent: Bool { player.currentItem?.id == track.id }
    private var isFavourite: Bool { favourites.isFavourite(track) }
    private var isDownloaded: Bool { downloads.isDownloaded(track) }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayName)
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if let artist = track.subtitleArtist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isFavourite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if downloads.isBusy(track) {
                    ProgressView()
                        .controlSize(.small)
                } else if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Format.duration(track.runtimeSeconds))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu }
        .onAppear { playlistStore.refreshIfNeeded() }
        .alert("New Playlist", isPresented: $isPresentingNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                perform(.newPlaylist(name: newPlaylistName))
                newPlaylistName = ""
            }
        } message: {
            Text("Create a playlist containing “\(track.displayName)”.")
        }
        #if os(iOS)
        .swipeActions(edge: .leading) {
            Button {
                favourites.toggle(track)
            } label: {
                Label(isFavourite ? "Unfavourite" : "Favourite", systemImage: isFavourite ? "heart.slash" : "heart")
            }
            .tint(.red)
        }
        .swipeActions(edge: .trailing) {
            Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
                .tint(.accentColor)
            if let onRemoveFromPlaylist {
                Button(role: .destructive, action: onRemoveFromPlaylist) {
                    Label("Remove from Playlist", systemImage: "minus.circle")
                }
            } else {
                Button { player.addToQueue([track]) } label: { Label("Queue", systemImage: "text.append") }
            }
        }
        #endif
    }

    @ViewBuilder private var leading: some View {
        if showArtwork {
            ArtworkImage(url: session.library.artworkURL(for: track, size: 96))
                .frame(width: 40, height: 40)
        } else if isCurrent {
            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 24)
        } else {
            Text(track.indexNumber.map(String.init) ?? "–")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)
        }
    }

    private enum TrackAction {
        case addToPlaylist(id: String)
        case newPlaylist(name: String)
    }

    private var destinationPlaylists: [BaseItemDto] {
        playlistStore.playlists.filter { $0.id != nil }
    }

    @ViewBuilder private var contextMenu: some View {
        Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
        Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
        Button { player.addToQueue([track]) } label: { Label("Add to Queue", systemImage: "text.append") }

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

        if let onRemoveFromPlaylist {
            Button(role: .destructive, action: onRemoveFromPlaylist) {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
        }
        Divider()
        Button { favourites.toggle(track) } label: {
            Label(isFavourite ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: isFavourite ? "heart.slash" : "heart")
        }
        .disabled(favourites.isBusy(track))
        Divider()
        Button {
            if isDownloaded {
                downloads.remove(track)
            } else {
                downloads.download(track)
            }
        } label: {
            Label(
                isDownloaded ? "Remove Download" : "Download",
                systemImage: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle"
            )
        }
        .disabled(downloads.isBusy(track))
    }

    // MARK: - Playlist Actions

    /// Presentations raised in the same run loop turn as a dismissing context
    /// menu are swallowed, so a prompt opened straight from a menu button
    /// waits for the menu to leave the screen first. Action errors don't need
    /// this — they surface through the root-hosted alert, which no dismissal
    /// can compete with.
    private func presentNewPlaylistPrompt() {
        Task {
            await Self.waitForPresentationDismissal()
            isPresentingNewPlaylist = true
        }
    }

    private static func waitForPresentationDismissal() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func perform(_ action: TrackAction) {
        guard let id = track.id else {
            playlistStore.presentActionError(JellyfinError.missingItemIdentifier.errorDescription)
            return
        }
        Task {
            do {
                switch action {
                case .addToPlaylist(let playlistId):
                    try await playlistStore.add(itemIds: [id], toPlaylistWithId: playlistId)
                case .newPlaylist(let name):
                    try await playlistStore.createPlaylist(named: name, itemIds: [id])
                }
            } catch {
                playlistStore.presentActionError(error.userFacingMessage)
            }
        }
    }
}
