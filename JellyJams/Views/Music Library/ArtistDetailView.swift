import SwiftUI

struct ArtistDetailView: View {
    let artist: BaseItemDto

    /// Cap on genres inferred from an artist's albums. A long discography can
    /// touch a dozen adjacent genres, and a wall of chips stops being a useful
    /// summary of what the artist sounds like.
    private static let derivedGenreLimit = 8

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @StateObject private var loader = LoadableModel(LibraryRepository.ArtistOverview())
    @State private var contentWidth: CGFloat = 0

    private var overview: LibraryRepository.ArtistOverview { loader.value }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CollectionHeader(
                    item: artist,
                    subtitle: Format.albumCount(overview.albums.count),
                    isCircular: true,
                    canPlay: !overview.topTracks.isEmpty,
                    onPlay: { player.play(overview.topTracks) },
                    onShuffle: { player.play(overview.topTracks, shuffled: true) }
                )

                if overview.albums.isEmpty, loader.isPending {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let errorMessage = loader.errorMessage,
                          overview.albums.isEmpty,
                          overview.topTracks.isEmpty {
                    LoadFailureView(title: "Couldn’t Load Artist", message: errorMessage) {
                        await load()
                    }
                } else if !overview.albums.isEmpty {
                    Text("Albums")
                        .font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 20) {
                        ForEach(overview.albums) { album in
                            NavigationLink(value: album) {
                                ItemGridCell(item: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                GenreChips(genres: genres)

                SimilarItemsSection(kind: .artists, item: artist, availableWidth: contentWidth)
            }
            .padding()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .navigationTitle(artist.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: artist.id) { await load() }
        #if os(iOS)
        .nowPlayingTabContentDock()
        #endif
        
    }

    /// The artist's own genres, falling back to the genres of their albums.
    /// Jellyfin doesn't reliably tag artist entries themselves, so without the
    /// fallback the section would be missing for most artists even when every
    /// one of their albums is tagged.
    private var genres: [GenreRef] {
        let own = artist.genreRefs
        guard own.isEmpty else { return own }
        let fromAlbums = overview.albums.flatMap(\.genreRefs).uniquedByName
        return Array(fromAlbums.prefix(Self.derivedGenreLimit))
    }

    private func load() async {
        await loader.load { try await session.library.artistOverview(for: artist) }
    }
}
