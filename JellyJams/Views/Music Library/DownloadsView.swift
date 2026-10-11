import SwiftUI

/// The Downloads section: every song saved for offline playback, presented the
/// way Favourites is — a segmented Songs / Albums / Artists / Playlists picker
/// above a list, with a ``DownloadStatusBar`` under the picker while
/// downloads run. Albums and artists are views derived from the songs' own
/// metadata, playlists are saved membership records, and nothing here asks the
/// server for anything: the section is wrapped in ``downloadsBrowsing()``, rows
/// read the manifest, and artwork comes from saved files. Removing a collection
/// unreferences its songs; only songs no other download requires disappear.
///
/// The Albums tab starts filtered to albums that are fully on disk — the filter
/// menu in the toolbar shows the partial ones, and the choice is remembered in
/// ``PreferencesStore/showsCompleteAlbumsOnly``.
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

    /// The selected songs in list order — what selection actions act on.
    private var selectedSongs: [BaseItemDto] {
        TrackEntry.rows(songs).filter { songSelection.contains($0.id) }.map(\.item)
    }

    private var songs: [BaseItemDto] { downloads.downloadedSongs() }

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
            default: groupsList(tab: tab)
            }
        }
        .navigationTitle("Downloads")
        .downloadsBrowsing()
        .toolbar {
            if tab == .albums {
                // A filtered list says so with a filled glyph, and the toggle
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

    /// One tab's groups. Albums and artists come from grouping the songs;
    /// playlists are the saved membership records.
    private func groupsList(tab: Tab) -> some View {
        let kind = tab.groupKind ?? .album
        let all = downloads.groups(kind: kind)
        // Only albums are filtered: artists and playlists are their own lists,
        // and songs are files rather than groupings that can be incomplete.
        let filtered = kind == .album && preferences.showsCompleteAlbumsOnly
        let visible = filtered ? all.filter(\.isFullyDownloaded) : all
        let hidden = all.count - visible.count
        return List {
            Section {
                ForEach(visible) { group in
                    DownloadedItemRow(group: group)
                }
            } header: {
                Text(countText(for: kind, visible.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } footer: {
                // A filter that hides things says so where the results end, with
                // one tap to show them again.
                if filtered, hidden > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hiding \(Format.albumCount(hidden)) not downloaded in full.")
                        Button("Show partial albums") { preferences.showsCompleteAlbumsOnly = false }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if visible.isEmpty {
                if filtered, hidden > 0 {
                    // The filter emptied the list rather than there being
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

/// One row of the Downloads section: a derived group or a saved playlist, with
/// how much of it is on disk.
struct DownloadedItemRow: View {
    @EnvironmentObject private var downloads: DownloadStore
    let group: DownloadStore.DownloadGroup

    var body: some View {
        // Value-based so the push registers in ``LibraryNavigator/path``; the
        // ref resolves to the offline detail, not the online one.
        NavigationLink(value: DownloadedGroupRef(group)) {
            rowContent
        }
        .modifier(DownloadedAlbumContextMenu(group: group))
        .swipeActions(edge: .trailing) {
            // Only a group that was itself downloaded has anything to remove:
            // a borrowed album's songs are required by whatever else brought
            // them, so removing it would be a no-op.
            if group.isExplicit {
                Button(role: .destructive, action: { downloads.remove(group.item) }) {
                    Label("Remove Download", systemImage: "trash")
                }
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

/// Right-click (macOS) and long-press (iOS / iPadOS) actions for a downloaded
/// album: queue its songs as they are on disk, in the order the album detail
/// lists them. Like every other browse path here the queueing asks the server
/// for nothing — the manifest holds the songs — and playback resolves each
/// queued track to its saved file. An album that isn't complete also gets a
/// fill-in action: the one deliberate, signed-in exception, mirroring the
/// offline playlist detail's refresh button. Artists and playlists get no
/// menu: an artist row is a view over albums, and both actions are
/// album-shaped.
private struct DownloadedAlbumContextMenu: ViewModifier {
    let group: DownloadStore.DownloadGroup

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var player: PlayerController

    func body(content: Content) -> some View {
        if group.kind == .album {
            content.contextMenu {
                Button { player.playNext(tracks) } label: { Label("Play Next", systemImage: "text.insert") }
                Button { player.addToQueue(tracks) } label: { Label("Add to Queue", systemImage: "text.append") }

                if !group.isFullyDownloaded, session.client != nil {
                    Divider()
                    // Songs already on disk just gain the album's reference,
                    // so downloading the album fetches exactly what is missing.
                    Button { downloads.download(group.item) } label: {
                        Label("Download Missing Songs", systemImage: "arrow.down.circle")
                    }
                    .disabled(downloads.isBusy(group.item))
                }
            }
        } else {
            content
        }
    }

    /// Resolved when an action is chosen, not on every render: a long album
    /// list costs nothing until a menu is used.
    private var tracks: [BaseItemDto] {
        downloads.tracks(for: group.item).inAlbumOrder()
    }
}
