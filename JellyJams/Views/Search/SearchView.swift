import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController

    @State private var query = ""
    @StateObject private var loader = LoadableModel(LibraryRepository.SearchResults())

    private var results: LibraryRepository.SearchResults { loader.value }

    var body: some View {
        List {
            if !results.genres.isEmpty {
                Section("Genres") {
                    ForEach(results.genres) { genre in
                        NavigationLink(value: genre) {
                            ItemRow(item: genre, placeholderSystemImage: "guitars")
                        }
                    }
                }
            }
            if !results.artists.isEmpty {
                Section("Artists") {
                    ForEach(results.artists) { artist in
                        NavigationLink(value: artist) {
                            ItemRow(item: artist, circular: true, placeholderSystemImage: "music.mic")
                        }
                    }
                }
            }
            if !results.albums.isEmpty {
                Section("Albums") {
                    ForEach(results.albums) { album in
                        NavigationLink(value: album) {
                            ItemRow(item: album)
                        }
                    }
                }
            }
            if !results.songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, song in
                        TrackRow(track: song, showArtwork: true) {
                            player.play(results.songs, startAt: index)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Artists, albums, songs, genres")
        .overlay { overlay }
        .task(id: query) { await runSearch() }
    }

    @ViewBuilder private var overlay: some View {
        let trimmed = currentTerm
        if trimmed.isEmpty {
            ContentUnavailableView("Search your library", systemImage: "magnifyingglass")
        } else if let errorMessage = loader.errorMessage {
            LoadFailureView(title: "Couldn’t Search", message: errorMessage) { await runSearch() }
        } else if loader.isPending, results.isEmpty {
            ProgressView()
        } else if results.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        }
    }

    private func runSearch() async {
        let term = currentTerm
        // Clear first: the previous term's results are not an answer to this
        // one, and resetting is what puts a spinner up during the debounce.
        loader.reset()
        guard !term.isEmpty else { return }

        // Debounce rapid typing. `.task(id:)` cancels this task whenever the
        // term changes, so a superseded search never reaches the server.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        guard !Task.isCancelled, currentTerm == term else { return }

        await loader.load { try await session.library.search(term: term) }
    }

    private var currentTerm: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
