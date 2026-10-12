import SwiftUI

/// The Downloads section: every song saved for offline playback, presented the
/// way Library and Favourites present theirs — a segmented
/// Songs / Albums / Artists / Playlists picker, with albums and artists as the
/// same artwork grids those sections show (square album covers, circular
/// artist photos) and songs and playlists as lists, and a
/// ``DownloadStatusBar`` under the picker while downloads run. Albums and
/// artists are views derived from the songs' own metadata, playlists are
/// saved membership records, and nothing here asks the server for anything:
/// the section is wrapped in ``downloadsBrowsing()``, cells and rows read the
/// manifest, and artwork comes from saved files. Removing a collection
/// unreferences its songs; only songs no other download requires disappear.
///
/// The Albums tab starts filtered to albums that are fully on disk — the filter
/// menu in the toolbar shows the partial ones, and the choice is remembered in
/// ``PreferencesStore/showsCompleteAlbumsOnly``.
/// How the Downloads songs list can be ordered: the manifest's own order —
/// the order files arrived in, newest first — or any field the saved tracks
/// carry, sorted the way the server would sort it.
enum DownloadSongSort: SortOption {
    case recentlyDownloaded
    case field(SortBy)

    var displayName: String {
        switch self {
        case .recentlyDownloaded: "Recently Downloaded"
        case .field(let field): field.displayName
        }
    }
}

struct DownloadsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case albums, artists, playlists, songs

        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        /// The derived view this tab lists, or `nil` for songs, which are the
        /// files themselves rather than a grouping of them.
        var groupKind: DownloadStore.GroupKind? {
            switch self {
            case .albums: .album
            case .artists: .artist
            case .playlists: .playlist
            case .songs: nil
            }
        }
    }

    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var preferences: PreferencesStore
    @State private var tab: Tab = .albums
    @State private var confirmingDeleteAll = false
    /// The downloaded songs the user has selected (rows are keyed by track
    /// id): click to select, double-click to play, shift-arrow to extend.
    @State private var songSelection: Set<String> = []
    @State private var songSort: DownloadSongSort = .field(.artist)
    @State private var songSortOrder: SortOrder = .ascending

    /// The selected songs in list order — what selection actions act on.
    private var selectedSongs: [BaseItemDto] {
        TrackEntry.rows(songs).filter { songSelection.contains($0.id) }.map(\.item)
    }

    /// The same fields the Library songs list sorts by, led by the section's
    /// own recency. The list opens on Artist, the way Library and Favourites
    /// songs do.
    private let songSortOptions: [DownloadSongSort] = [
        .recentlyDownloaded,
        .field(.artist), .field(.sortName), .field(.album), .field(.albumArtist),
        .field(.dateCreated), .field(.datePlayed), .field(.runtime), .field(.random),
    ]

    private var songs: [BaseItemDto] {
        switch songSort {
        case .recentlyDownloaded:
            let newestFirst = downloads.downloadedSongs()
            return songSortOrder == .descending ? newestFirst : Array(newestFirst.reversed())
        case .field(let field):
            return downloads.downloadedSongs().sorted(by: field, order: songSortOrder)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Live progress for every running download. This replaces the
            // rows the songs list used to show; the tab bar's icon and badge
            // keep telling the rest of the app a download is running.
            if !downloads.batches.isEmpty {
                DownloadStatusBar()
            }

            switch tab {
            case .songs: songsList
            case .albums, .artists: groupsGrid(tab: tab)
            case .playlists: playlistsList
            }
        }
        .navigationTitle("Downloads")
        .downloadsBrowsing()
        .toolbar {
            if tab == .albums {
                // A filtered grid says so with a filled glyph, and the toggle
                // that turns it off lives in the menu it opens.
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Toggle("Complete Albums Only", isOn: $preferences.showsCompleteAlbumsOnly)
                    } label: {
                        Image(systemName: preferences.showsCompleteAlbumsOnly
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle")
                    }
                    .help("Filter the downloaded albums by what is fully on disk")
                    .accessibilityLabel("Album filter")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) { confirmingDeleteAll = true } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .disabled(!downloads.batches.isEmpty
                          || (downloads.entries.isEmpty && downloads.playlists.isEmpty))
            }
            if tab == .songs, !selectedSongs.isEmpty {
                ToolbarItem { TrackSelectionMenu(tracks: selectedSongs) }
            }
            if tab == .songs {
                ToolbarItem(placement: .automatic) {
                    SortMenu(sortBy: $songSort, sortOrder: $songSortOrder, options: songSortOptions)
                }
            }
        }
        .alert("Delete all downloaded music?", isPresented: $confirmingDeleteAll) {
            Button("Delete All Downloads", role: .destructive) { downloads.removeAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var songsList: some View {
        // Resolved once; `songs` re-derives the downloaded list and
        // `selectedSongs` filters it, so naming them inside the `ForEach`
        // would redo that work per row.
        let tracks = songs
        let selected = selectedSongs
        List(selection: $songSelection) {
            Section {
                ForEach(TrackEntry.rows(tracks)) { entry in
                    TrackRow(track: entry.item, showArtwork: true, selectedTracks: songSelection.contains(entry.id) ? selected : []) {
                        player.play(tracks, startAt: tracks.firstIndex { $0.id == entry.item.id } ?? 0)
                    }
                }
            } header: {
                Text(Format.songCount(songs.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .shiftArrowSelection($songSelection, ids: songs.compactMap(\.id))
        .onKeyPress(.escape) {
            songSelection = []
            return .handled
        }
        .focusable()
        .overlay {
            if songs.isEmpty && downloads.batches.isEmpty {
                ContentUnavailableView("No downloaded songs", systemImage: "music.note")
            }
        }
    }

    /// One tab's groups as the same artwork grid the Library sections show:
    /// adaptive cells of big covers — square for albums, circular for artists
    /// — over a count header. Like every other browse path here, a cell's
    /// artwork is its saved file and its push opens the offline detail.
    private func groupsGrid(tab: Tab) -> some View {
        let kind = tab.groupKind ?? .album
        let all = downloads.groups(kind: kind)
        // Only albums are filtered: artists are their own list, and songs are
        // files rather than groupings that can be incomplete.
        let filtered = kind == .album && preferences.showsCompleteAlbumsOnly
        let visible = filtered ? all.filter(\.isFullyDownloaded) : all
        let hidden = all.count - visible.count
        let minCellWidth: CGFloat = tab == .artists ? 150 : 160
        return ScrollView {
            Section {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: minCellWidth), spacing: 16)],
                    spacing: 20
                ) {
                    ForEach(visible) { group in
                        NavigationLink(value: DownloadedGroupRef(group)) {
                            DownloadedGroupCell(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()

                // A filter that hides things says so where the results end, with
                // one tap to show them again.
                if filtered, hidden > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hiding \(Format.albumCount(hidden)) not downloaded in full.")
                        Button("Show partial albums") { preferences.showsCompleteAlbumsOnly = false }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            } header: {
                Text(countText(for: kind, visible.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if visible.isEmpty {
                if filtered, hidden > 0 {
                    // The filter emptied the grid rather than there being
                    // nothing downloaded.
                    ContentUnavailableView {
                        Label("No complete albums", systemImage: placeholder(for: kind))
                    } description: {
                        Text("Nothing is downloaded in full yet.")
                    } actions: {
                        Button("Show partial albums") { preferences.showsCompleteAlbumsOnly = false }
                    }
                } else {
                    ContentUnavailableView(
                        "No downloaded \(tab.title.lowercased())",
                        systemImage: placeholder(for: kind)
                    )
                }
            }
        }
    }

    /// The Playlists tab: the saved membership records as a list. (Albums and
    /// artists render as grids; songs are the files themselves.)
    private var playlistsList: some View {
        let playlists = downloads.groups(kind: .playlist)
        return List {
            Section {
                ForEach(playlists) { group in
                    DownloadedItemRow(group: group)
                }
            } header: {
                Text(Format.playlistCount(playlists.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .overlay {
            if playlists.isEmpty {
                ContentUnavailableView("No downloaded playlists", systemImage: "music.note.list")
            }
        }
    }

    private func countText(for kind: DownloadStore.GroupKind, _ count: Int) -> String {
        switch kind {
        case .album: Format.albumCount(count)
        case .artist: Format.artistCount(count)
        case .playlist, .genre: Format.playlistCount(count)
        }
    }

    private func placeholder(for kind: DownloadStore.GroupKind) -> String {
        switch kind {
        case .album: "square.stack"
        case .artist: "music.mic"
        case .playlist, .genre: "music.note.list"
        }
    }
}

/// One row of the Downloads Playlists tab: a saved playlist, with how much of
/// it is on disk, the full ``DownloadedGroupContextMenu`` of offline actions,
/// and a swipe to remove.
struct DownloadedItemRow: View {
    @EnvironmentObject private var downloads: DownloadStore
    let group: DownloadStore.DownloadGroup

    var body: some View {
        // Value-based so the push registers in ``LibraryNavigator/path``; the
        // ref resolves to the offline detail, not the online one.
        NavigationLink(value: DownloadedGroupRef(group)) {
            rowContent
        }
        .modifier(DownloadedGroupContextMenu(group: group))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: { downloads.remove(group.item) }) {
                Label("Remove Download", systemImage: "trash")
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            // No server artwork URL: a downloaded row's cover is its saved file
            // or a placeholder, never a request.
            ArtworkImage(
                url: nil,
                localURL: downloads.localArtworkURL(for: group),
                cornerRadius: 6,
                placeholderSystemImage: placeholder
            )
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).lineLimit(1)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            .buttonStyle(.borderless)
        }
    }

    private var placeholder: String {
        switch group.kind {
        case .album: "square.stack"
        case .artist: "music.mic"
        case .playlist, .genre: "music.note.list"
        }
    }

    /// What the group holds offline: songs for an album or playlist (with the
    /// server's total when it was known, so a partial album says "3 of 12"),
    /// albums for an artist.
    private var subtitleText: String {
        if group.kind == .artist {
            return Format.albumCount(downloads.downloadedAlbums(forArtistID: group.id).count)
        }
        if let total = group.totalSongs, total > group.downloadedSongs {
            return "\(Format.songCount(group.downloadedSongs)) of \(total)"
        }
        return Format.songCount(group.downloadedSongs)
    }
}

/// One tile of the Downloads albums and artists grids: the same artwork tile
/// the Library grids show — a big square album cover or a circular artist
/// photo, with title, favourite mark and subtitle — reading the group's saved
/// cover from disk. No server artwork URL is ever built; a downloaded tile's
/// cover is its saved file or a placeholder, never a request.
struct DownloadedGroupCell: View {
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var favourites: FavouriteStore
    let group: DownloadStore.DownloadGroup

    private var isArtist: Bool { group.kind == .artist }

    /// The album artist an album tile shows under its title; artists get
    /// none, the way the Library artist grid shows them.
    private var subtitle: String? {
        group.kind == .album ? group.item.subtitleAlbumArtist : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(
                url: nil,
                localURL: downloads.localArtworkURL(for: group),
                cornerRadius: isArtist ? 500 : 6,
                placeholderSystemImage: isArtist ? "music.mic" : "record.circle.fill"
            )
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)

            HStack(spacing: 4) {
                if isArtist { Spacer(minLength: 0) }
                Text(group.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                if favourites.isFavourite(group.item) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Favourite")
                }
                Spacer(minLength: 0)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .modifier(DownloadedGroupContextMenu(group: group))
    }
}

/// Right-click (macOS) and long-press (iOS / iPadOS) actions for a downloaded
/// group, whether it was downloaded itself or surfaced through another
/// collection. The actions match the ones a Library tile offers, but every
/// one is answered from the manifest: Play and Shuffle start the group's
/// songs on disk with playback resolving each to its saved file, Play Next
/// and Add to Queue enqueue them the same way. An album that isn't complete
/// also gets a fill-in action: the one deliberate, signed-in exception,
/// mirroring the offline playlist detail's refresh button. And removing
/// deletes the group's songs from disk — whatever else required them keeps
/// what it still has, a playlist keeping its membership and warning it is
/// incomplete until refreshed — so the action is offered on every group,
/// borrowed or not. (A grid tile has no swipe; a playlist row does, and this
/// menu works there too.)
private struct DownloadedGroupContextMenu: ViewModifier {
    let group: DownloadStore.DownloadGroup

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var player: PlayerController

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { player.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
            Button { player.play(tracks, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            Button { player.playNext(tracks) } label: { Label("Play Next", systemImage: "text.insert") }
            Button { player.addToQueue(tracks) } label: { Label("Add to Queue", systemImage: "text.append") }

            if group.kind == .album, !group.isFullyDownloaded, session.client != nil {
                Divider()
                // Songs already on disk just gain the album's reference,
                // so downloading the album fetches exactly what is missing.
                Button { downloads.download(group.item) } label: {
                    Label("Download Missing Songs", systemImage: "arrow.down.circle")
                }
                .disabled(downloads.isBusy(group.item))
            }

            Divider()
            Button(role: .destructive) { downloads.remove(group.item) } label: {
                Label("Remove Download", systemImage: "trash")
            }
            .disabled(downloads.isBusy(group.item))
        }
    }

    /// Resolved when an action is chosen, not on every render: a long list
    /// costs nothing until a menu is used.
    private var tracks: [BaseItemDto] {
        if group.kind == .artist {
            // Album by album, each in the order its detail lists — the same
            // order the artist's own Play button starts.
            return downloads.downloadedAlbums(forArtistID: group.id)
                .flatMap { downloads.tracks(in: $0).inAlbumOrder() }
        }
        if group.kind == .playlist {
            // The user's own order, not the album's.
            return downloads.tracks(for: group.item)
        }
        return downloads.tracks(for: group.item).inAlbumOrder()
    }
}
