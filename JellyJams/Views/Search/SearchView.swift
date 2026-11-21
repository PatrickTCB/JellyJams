import SwiftUI

struct SearchView: View {
    @Environment(SessionStore.self) private var session
    @Environment(PlayerController.self) private var player
    @Environment(PreferencesStore.self) private var preferences

    @State private var query = ""
    @State private var loader = LoadableModel(LibraryRepository.SearchResults())

    private var results: LibraryRepository.SearchResults { loader.value }

    var body: some View {
        List {
            if !results.lyricMatches.isEmpty {
                Section {
                    ForEach(Array(results.lyricMatches.enumerated()), id: \.element.id) { index, song in
                        // Whole-row taps, like the songs below — see the note
                        // there for why this List keeps no selection model.
                        TrackRow(track: song, showArtwork: true, tapBehavior: .play) {
                            player.play(results.lyricMatches, startAt: index)
                        }
                    }
                } header: {
                    Text("Lyric Matches")
                } footer: {
                    Text("Songs with lyrics matching your search.")
                }
            }
            if !results.songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, song in
                        // Tap-to-play: this List is a navigation list for its
                        // other sections, and a selection-bound List forces
                        // double-clicks to navigate on macOS — so the songs
                        // here keep whole-row taps rather than a selection
                        // model that would break the genres/artists/albums
                        // rows above them.
                        TrackRow(track: song, showArtwork: true, tapBehavior: .play) {
                            player.play(results.songs, startAt: index)
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
            if !results.genres.isEmpty {
                Section("Genres") {
                    ForEach(results.genres) { genre in
                        NavigationLink(value: genre) {
                            ItemRow(item: genre, placeholderSystemImage: "guitars")
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
            LoadFailureOverlay(title: "Couldn’t Search", message: errorMessage) {
                await runSearch()
                return loader.errorMessage == nil
            }
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

        await loader.load {
            try await session.library.search(term: term, lyricSearch: lyricSearchDestination)
        }
    }

    /// The backend to ask for lyric matches beside the Jellyfin results —
    /// nil when no backend is configured or nobody is signed in, which is
    /// every search that runs on Jellyfin alone. A configured backend's
    /// lyric matches join the results silently: no switch to turn on, and
    /// a backend that cannot answer simply adds nothing.
    private var lyricSearchDestination: BackendDestination? {
        BackendDestination(
            address: preferences.jellyJamsBackendAddress,
            deviceInfo: session.deviceInfo,
            userID: session.currentUser?.id
        )
    }

    private var currentTerm: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
