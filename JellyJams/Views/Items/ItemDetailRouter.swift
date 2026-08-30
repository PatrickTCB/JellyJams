import SwiftUI

/// Routes a `BaseItemDto` to the appropriate detail screen based on its type.
struct ItemDetailRouter: View {
    let item: BaseItemDto

    var body: some View {
        switch item.itemType {
        case .musicAlbum:
            AlbumDetailView(album: item)
        case .musicArtist:
            ArtistDetailView(artist: item)
        case .playlist:
            PlaylistDetailView(playlist: item)
        // `/Genres` returns `Genre`; the music-specific endpoints return
        // `MusicGenre`. Both describe the same thing.
        case let type? where type.isGenre:
            if let genre = GenreRef(item: item) {
                GenreResultsView(genre: genre)
            } else {
                unsupported
            }
        default:
            unsupported
        }
    }

    private var unsupported: some View {
        ContentUnavailableView {
            Label("Unsupported Item", systemImage: "questionmark.square.dashed")
        } description: {
            Text("Jelly Jams can’t open this kind of library item.")
        }
    }
}

extension View {
    /// Registers the navigation destinations for library items, genres and
    /// sections, so the values ``LibraryNavigator`` appends to a stack's path —
    /// and the ones its value-based `NavigationLink`s carry — resolve through
    /// ``ItemDetailRouter``, ``GenreResultsView`` and ``SectionRootView``.
    /// Applied once per navigation stack by ``LibraryNavigationStack``.
    ///
    /// Every push in the app goes through one of these, which keeps the stack's
    /// depth and its path in step. A `NavigationLink` that holds its destination
    /// inline pushes a screen the path has no element for, and a stack whose
    /// path disagrees with what it is showing resolves later pushes against the
    /// wrong screen.
    ///
    /// The `navigator` is re-injected onto each destination because a
    /// value-based destination is hosted by the stack rather than built inside
    /// the content, so it does not inherit the `environmentObject` placed on the
    /// stack's root. Passing it here keeps ``SimilarItemsSection`` and
    /// ``GenreChips`` — which push through it — from crashing when they render
    /// on a pushed album, playlist, artist, or genre screen.
    ///
    /// Those two push through ``LibraryNavigator`` rather than a
    /// `NavigationLink`: both sit inside a single `List` row on the album and
    /// playlist screens (``TrackListDetail``), and a `List` turns any row that
    /// contains a `NavigationLink` into one tap target — so a whole grid or flow
    /// of them collapses into a single button that opens whichever link is last
    /// (and, on iOS, each gets a disclosure chevron). A plain `Button` that
    /// appends to the path gets none of that treatment.
    func libraryNavigationDestinations(navigator: LibraryNavigator) -> some View {
        navigationDestination(for: BaseItemDto.self) {
            ItemDetailRouter(item: $0).environmentObject(navigator)
        }
        .navigationDestination(for: GenreRef.self) {
            GenreResultsView(genre: $0).environmentObject(navigator)
        }
        .navigationDestination(for: LibrarySection.self) {
            SectionRootView(section: $0).environmentObject(navigator)
        }
    }
}
