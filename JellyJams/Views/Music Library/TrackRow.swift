import SwiftUI

/// A single track row used in album detail, songs, search and queue lists.
/// The row follows the standard music-list model everywhere: a single tap or
/// click belongs to the enclosing list's selection, and playback is a
/// deliberate second gesture — a double-click on macOS, a tap outside edit
/// mode on iOS. Lists that keep whole-row tap-to-play (search results, whose
/// List is a navigation list and binds no selection) set ``tapBehavior`` to
/// `.play`. Secondary actions live in the context menu and (on iOS) swipe
/// actions.
struct TrackRow: View {
    let track: BaseItemDto
    var showArtwork = false
    /// How the row answers a tap; see ``TapBehavior``.
    var tapBehavior: TapBehavior = .select
    /// The enclosing list's selected tracks, in list order. When this row is
    /// one of them, the context menu's actions apply to the whole selection —
    /// the standard multi-selection behaviour: acting on one acts on all —
    /// otherwise they apply to this row alone. Lists that bind no selection
    /// (search) leave it empty.
    var selectedTracks: [BaseItemDto] = []
    /// Set by playlist detail views to expose "Remove from Playlist" in the
    /// context menu and (on iOS) trailing swipe actions.
    var onRemoveFromPlaylist: (() -> Void)?
    var onPlay: () -> Void

    /// How the row answers a tap. `.select` (the default) gives the single
    /// tap to the enclosing list's selection, with playback on a deliberate
    /// second gesture: a double-click on macOS, and on iOS a tap while the
    /// list is NOT in edit mode (in edit mode the tap toggles the row's
    /// checkmark, so the label must not compete with it as a button).
    /// `.play` makes the whole row a plain button that starts playback, for
    /// lists that bind no selection of their own.
    enum TapBehavior {
        /// The single tap belongs to the enclosing list's selection.
        case select
        /// The whole row is a plain button that starts playback.
        case play
    }

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var favourites: FavouriteStore
    @EnvironmentObject private var downloads: DownloadStore

    @State private var isPresentingNewPlaylist = false
    @State private var newPlaylistName = ""

    #if os(iOS)
    /// Active while an enclosing list is in edit mode — playlist detail's
    /// selection mode. The row then stops playing on tap so the list can
    /// select it instead. macOS has no edit mode: rows are selected there
    /// with a click and modifier-clicks, and keep playing on a plain click.
    @Environment(\.editMode) private var editMode
    #endif

    private var isCurrent: Bool { player.currentItem?.id == track.id }
    private var isFavourite: Bool { favourites.isFavourite(track) }
    private var isDownloaded: Bool { downloads.isDownloaded(track) }

    var body: some View {
        playTarget
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
                Text(newPlaylistMessage)
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

    /// The row's tap behaviour. `.play` lists wrap the whole row in a plain
    /// button: tap or click anywhere to play. `.select` lists own the single
    /// tap — playlist detail's selection — so the row is bare and playback
    /// happens on a deliberate second gesture: a double-click on macOS, and
    /// on iOS a tap while the list is NOT in edit mode (in edit mode the tap
    /// toggles the row's checkmark, so the label must not compete with it
    /// as a button).
    @ViewBuilder private var playTarget: some View {
        switch tapBehavior {
        case .play:
            playButton
        case .select:
            #if os(iOS)
            if editMode?.wrappedValue == .active {
                rowLabel
            } else {
                playButton
            }
            #else
            rowLabel
                .onTapGesture(count: 2, perform: onPlay)
            #endif
        }
    }

    private var playButton: some View {
        Button(action: onPlay) { rowLabel }
            .buttonStyle(.plain)
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayName)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
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

    @ViewBuilder private var leading: some View {
        if showArtwork {
            let localArtworkURL = downloads.isDownloaded(track)
                ? downloads.localArtworkURL(forImageTag: track.primaryImageTag ?? track.albumPrimaryImageTag ?? "")
                : nil
            ArtworkImage(
                url: session.library.artworkURL(for: track, size: 96),
                localURL: localArtworkURL
            )
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

    /// The tracks the context menu acts on: the whole selection when this row
    /// is part of it — acting on one selected row acts on all, the standard
    /// multi-selection behaviour — otherwise this row alone. Compared by
    /// playlist entry key so the same song twice in a playlist stays two
    /// distinct rows.
    private var contextTracks: [BaseItemDto] {
        guard selectedTracks.contains(where: { $0.playlistEntryKey == track.playlistEntryKey }) else {
            return [track]
        }
        return selectedTracks
    }

    /// Whether every track the menu acts on is favourited — the menu then
    /// removes the favourite from all; otherwise it adds the missing ones.
    private var allFavourite: Bool { contextTracks.allSatisfy(favourites.isFavourite) }
    private var allDownloaded: Bool { contextTracks.allSatisfy(downloads.isDownloaded) }

    @ViewBuilder private var contextMenu: some View {
        Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
        Button { player.playNext(contextTracks) } label: { Label("Play Next", systemImage: "text.insert") }
        Button { player.addToQueue(contextTracks) } label: { Label("Add to Queue", systemImage: "text.append") }

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
        Button { toggleFavourites() } label: {
            Label(allFavourite ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: allFavourite ? "heart.slash" : "heart")
        }
        .disabled(contextTracks.contains { favourites.isBusy($0) })
        Divider()
        Button {
            if allDownloaded {
                for track in contextTracks { downloads.remove(track) }
            } else {
                for track in contextTracks where !downloads.isDownloaded(track) {
                    downloads.download(track)
                }
            }
        } label: {
            Label(
                allDownloaded ? "Remove Download" : "Download",
                systemImage: allDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle"
            )
        }
        .disabled(contextTracks.contains { downloads.isBusy($0) })
    }

    /// Favourites every track the menu acts on: removes the favourite from
    /// all when all are favourited, otherwise adds only the missing ones (a
    /// mixed selection keeps its favourites rather than flipping them off).
    private func toggleFavourites() {
        if allFavourite {
            for track in contextTracks { favourites.toggle(track) }
        } else {
            for track in contextTracks where !favourites.isFavourite(track) {
                favourites.toggle(track)
            }
        }
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

    private var newPlaylistMessage: String {
        if contextTracks.count == 1 {
            return "Create a playlist containing “\(track.displayName)”."
        }
        return "Create a playlist containing \(Format.songCount(contextTracks.count))."
    }

    private func perform(_ action: TrackAction) {
        let ids = contextTracks.compactMap(\.id)
        guard !ids.isEmpty else {
            playlistStore.presentActionError(JellyfinError.missingItemIdentifier.errorDescription)
            return
        }
        Task {
            do {
                switch action {
                case .addToPlaylist(let playlistId):
                    try await playlistStore.add(itemIds: ids, toPlaylistWithId: playlistId)
                case .newPlaylist(let name):
                    try await playlistStore.createPlaylist(named: name, itemIds: ids)
                }
            } catch {
                playlistStore.presentActionError(error.userFacingMessage)
            }
        }
    }
}
