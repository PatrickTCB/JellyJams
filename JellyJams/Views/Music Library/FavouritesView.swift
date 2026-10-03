import SwiftUI

struct FavouritesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case songs, albums, artists, playlists

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @ObservedObject var songs: PagedItems
    @ObservedObject var albums: PagedItems
    @ObservedObject var artists: PagedItems
    @ObservedObject var playlists: PagedItems
    @State private var tab: Tab = .songs
    /// The favourite songs the user has selected (rows are keyed by track
    /// id): click to select, double-click to play, shift-arrow to extend.
    @State private var songSelection: Set<String> = []

    /// The selected songs in list order — what selection actions act on.
    private var selectedSongs: [BaseItemDto] {
        TrackEntry.rows(songs.items).filter { songSelection.contains($0.id) }.map(\.item)
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
            case .albums: ItemGrid(model: albums, emptyMessage: "No favourite albums", emptySystemImage: "heart")
            case .artists: ItemGrid(model: artists, minCellWidth: 150, emptyMessage: "No favourite artists", emptySystemImage: "heart")
            case .playlists: ItemGrid(model: playlists, emptyMessage: "No favourite playlists", emptySystemImage: "heart")
            }
        }
        .navigationTitle("Favourites")
        .toolbar {
            switch tab {
            case .songs:
                ToolbarItem {
                    Button { player.play(songs.items, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .disabled(songs.isEmpty)
                }
                if !selectedSongs.isEmpty {
                    ToolbarItem { TrackSelectionMenu(tracks: selectedSongs) }
                }
            case .albums:
                ToolbarItem {
                    SortMenu(sortBy: $albums.sortBy, sortOrder: $albums.sortOrder, options: albums.sortOptions)
                }
            case .artists:
                ToolbarItem {
                    SortMenu(sortBy: $artists.sortBy, sortOrder: $artists.sortOrder, options: artists.sortOptions)
                }
            default:
                ToolbarItemGroup {}
            }
        }
        .refreshToolbarItem { await current.reload() }
        .task(id: current.query) { await current.load(from: session.library) }
        .refreshable { await current.reload() }
    }

    @ViewBuilder
    private var songsList: some View {
        // Resolved once; naming the computed properties inside the `ForEach`
        // would re-derive them per row.
        let entries = TrackEntry.rows(songs.items)
        let items = songs.items
        let selected = selectedSongs
        List(selection: $songSelection) {
            Section {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    TrackRow(track: entry.item, showArtwork: true, selectedTracks: songSelection.contains(entry.id) ? selected : []) {
                        player.play(items, startAt: index)
                    }
                    .task { await songs.loadMoreIfNeeded(entry.item) }
                }
                if songs.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                } else if let error = songs.errorMessage, !songs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Couldn’t load more favourites", systemImage: "wifi.exclamationmark")
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry") { Task { await songs.loadNextPage() } }
                    }
                }
            } header: {
                Text("\(songs.total) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .shiftArrowSelection($songSelection, ids: songs.items.compactMap(\.id))
        .onKeyPress(.escape) {
            songSelection = []
            return .handled
        }
        .focusable()
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
}
