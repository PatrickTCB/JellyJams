import SwiftUI

struct FavouritesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case songs, albums, artists, playlists

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @Environment(SessionStore.self) private var session
    @Environment(PlayerController.self) private var player
    @Bindable var songs: PagedItems
    @Bindable var albums: PagedItems
    @Bindable var artists: PagedItems
    let playlists: PagedItems
    @State private var tab: Tab = .songs
    /// The favourite songs the user has selected (rows are keyed by track
    /// id): click to select, double-click to play, shift-arrow to extend.
    @State private var songSelection: Set<String> = []

    /// The selected songs in list order — what selection actions act on.
    private var selectedSongs: [BaseItemDto] {
        TrackEntry.rows(songs.items).filter { songSelection.contains($0.id) }.map(\.item)
    }

    /// On tvOS the single press belongs to playback: there is no selection
    /// gesture to give it to — no edit mode, no drag, no keyboard — so rows
    /// play on select, as ``TrackListDetail``'s do.
    private var rowTapBehavior: TrackRow.TapBehavior {
        #if os(tvOS)
        .play
        #else
        .select
        #endif
    }

    /// The model backing the selected tab. Each tab keeps its own sort and
    /// loaded pages, so switching back and forth doesn't refetch.
    private var current: PagedItems {
        switch tab {
        case .songs: songs
        case .albums: albums
        case .artists: artists
        case .playlists: playlists
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

            switch tab {
            case .songs: songsList
            case .albums: ItemGrid(model: albums, emptyMessage: "No favourite albums", emptySystemImage: "heart").refreshable {
                Task { await albums.reload() }
            }
            case .artists: ItemGrid(model: artists, minCellWidth: 150 * ArtworkImage.sizeMultiplier, emptyMessage: "No favourite artists", emptySystemImage: "heart").refreshable {
                Task { await artists.reload() }
            }
            case .playlists: ItemGrid(model: playlists, emptyMessage: "No favourite playlists", emptySystemImage: "heart").refreshable {
                Task { await playlists.reload() }
            }
            }
        }
        .navigationTitle("Favourites")
        .tvScrollingBar(title: "Favourites") { tabActions }
        .toolbar {
            ToolbarItemGroup { tabActions }
        }
        .refreshToolbarItem { await current.reload() }
        .task(id: current.query) { await current.load(from: session.library) }
        .refreshable { await current.reload() }
    }

    /// The selected tab's actions, shared by the system toolbar and the
    /// tvOS scrolling bar.
    @ViewBuilder private var tabActions: some View {
        switch tab {
        case .songs:
            Button { player.play(songs.items, shuffled: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(songs.isEmpty)
            if !selectedSongs.isEmpty {
                TrackSelectionMenu(tracks: selectedSongs)
            }
            SortMenu(sortBy: $songs.sortBy, sortOrder: $songs.sortOrder, options: songs.sortOptions)
        case .albums:
            SortMenu(sortBy: $albums.sortBy, sortOrder: $albums.sortOrder, options: albums.sortOptions)
        case .artists:
            SortMenu(sortBy: $artists.sortBy, sortOrder: $artists.sortOrder, options: artists.sortOptions)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var songsList: some View {
        songsContainer
            .overlay {
                if let error = songs.errorMessage, songs.isEmpty {
                    LoadFailureOverlay(title: "Couldn’t Load Favourites", message: error) {
                        await songs.reload()
                        return songs.errorMessage == nil
                    }
                } else if songs.hasLoadedOnce, songs.isEmpty, !songs.isLoading {
                    ContentUnavailableView("No favourite songs", systemImage: "heart")
                }
            }
    }

    /// The bar and the song rows in their scroll container.
    ///
    /// tvOS scrolls a plain stack, like the grids: a `List` row there is one
    /// focus target as a whole, which swallows the bar's buttons into a single
    /// row-sized highlight the remote cannot move inside — and a focus section
    /// on the row's content does not override the row itself. In a stack each
    /// bar button and each row is its own focus target. The other platforms
    /// keep the List and its selection machinery.
    @ViewBuilder private var songsContainer: some View {
        // Resolved once; naming the computed properties inside the `ForEach`
        // would re-derive them per row.
        let entries = TrackEntry.rows(songs.items)
        let items = songs.items
        let selected = selectedSongs
        #if os(tvOS)
        ScrollView {
            TVScrollingBarSlot()
            Section {
                LazyVStack(alignment: .leading, spacing: 12) {
                    songRows(entries: entries, items: items, selected: selected)
                    songsFooter
                }
                .padding(.horizontal)
                .padding(.top, 8)
            } header: {
                songsCountHeader
            }
        }
        #else
        List(selection: $songSelection) {
            TVScrollingBarSlot()
            Section {
                songRows(entries: entries, items: items, selected: selected)
                songsFooter
            } header: {
                songsCountHeader
            }
        }
        .listStyle(.plain)
        .shiftArrowSelection($songSelection, ids: songs.items.compactMap(\.id))
        .onKeyPress(.escape) {
            songSelection = []
            return .handled
        }
        // Keyboard platforms need the list itself focusable for the selection
        // keys.
        .focusable()
        #endif
    }

    /// The song rows, shared by both containers.
    @ViewBuilder
    private func songRows(entries: [TrackEntry], items: [BaseItemDto], selected: [BaseItemDto]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            TrackRow(track: entry.item, showArtwork: true, tapBehavior: rowTapBehavior, selectedTracks: songSelection.contains(entry.id) ? selected : []) {
                player.play(items, startAt: index)
            }
            .remotePlayAction { player.play(items, startAt: index) }
            .task(id: songs.settledLoads) { await songs.loadMoreIfNeeded(entry.item) }
        }
    }

    /// The loading spinner / load-more failure shown after the last row.
    @ViewBuilder private var songsFooter: some View {
        if songs.isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
        } else if let error = songs.errorMessage, !songs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn’t load more favourites", systemImage: "wifi.exclamationmark")
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await songs.loadNextPage() } }
            }
        }
    }

    private var songsCountHeader: some View {
        Text("\(songs.total) songs")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
