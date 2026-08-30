import SwiftUI

struct FavouritesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case songs, albums, artists

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @ObservedObject var songs: PagedItems
    @ObservedObject var albums: PagedItems
    @ObservedObject var artists: PagedItems
    @State private var tab: Tab = .songs

    /// The model backing the selected tab. Each tab keeps its own sort and
    /// loaded pages, so switching back and forth doesn't refetch.
    private var current: PagedItems {
        switch tab {
        case .songs: songs
        case .albums: albums
        case .artists: artists
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
            case .albums:
                ToolbarItem {
                    SortMenu(sortBy: $albums.sortBy, sortOrder: $albums.sortOrder, options: albums.sortOptions)
                }
            case .artists:
                ToolbarItem {
                    SortMenu(sortBy: $artists.sortBy, sortOrder: $artists.sortOrder, options: artists.sortOptions)
                }
            }
        }
        .refreshToolbarItem { await current.reload() }
        .task(id: current.query) { await current.load(from: session.library) }
        .refreshable { await current.reload() }
    }

    private var songsList: some View {
        List {
            Section {
                ForEach(Array(songs.items.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, showArtwork: true) {
                        player.play(songs.items, startAt: index)
                    }
                    .task { await songs.loadMoreIfNeeded(track) }
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
        .overlay {
            if let error = songs.errorMessage, songs.isEmpty {
                LoadFailureView(title: "Couldn’t Load Favourites", message: error) { await songs.reload() }
            } else if songs.hasLoadedOnce, songs.isEmpty, !songs.isLoading {
                ContentUnavailableView("No favourite songs", systemImage: "heart")
            }
        }
    }
}
