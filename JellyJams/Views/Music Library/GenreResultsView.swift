import SwiftUI

/// Everything in one genre, presented the way search results are: the albums
/// and artists tagged with it.
///
/// Reached from a genre chip on an album or artist screen, or from the Genres
/// section of search results.
struct GenreResultsView: View {
    let genre: GenreRef

    @EnvironmentObject private var session: SessionStore
    @StateObject private var loader = LoadableModel(LibraryRepository.GenreContents())

    private var contents: LibraryRepository.GenreContents { loader.value }

    var body: some View {
        List {
            if !contents.artists.isEmpty {
                Section("Artists") {
                    ForEach(contents.artists) { artist in
                        NavigationLink(value: artist) {
                            ItemRow(item: artist, circular: true, placeholderSystemImage: "music.mic")
                        }
                    }
                }
            }
            if !contents.albums.isEmpty {
                Section("Albums") {
                    ForEach(contents.albums) { album in
                        NavigationLink(value: album) {
                            ItemRow(item: album)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(genre.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await load() }
        .refreshToolbarItem { await load() }
        .overlay { overlay }
        .task(id: genre.id) { await load() }
    }

    @ViewBuilder private var overlay: some View {
        if let errorMessage = loader.errorMessage, contents.isEmpty {
            LoadFailureView(title: "Couldn’t Load Genre", message: errorMessage) { await load() }
        } else if contents.isEmpty, loader.isPending {
            ProgressView()
        } else if contents.isEmpty {
            ContentUnavailableView {
                Label("Nothing in \(genre.name)", systemImage: "guitars")
            } description: {
                Text("No music in your library is tagged with this genre.")
            }
        }
    }

    private func load() async {
        await loader.load { try await session.library.genreContents(genre) }
    }
}
