import SwiftUI

/// Maps a ``LibrarySection`` to its root browsing view, supplying each one the
/// cached model for the list it shows.
struct SectionRootView: View {
    @EnvironmentObject private var libraryCache: LibraryCache
    let section: LibrarySection

    var body: some View {
        switch section {
        case .albums:
            AlbumsView(model: libraryCache.items(for: .albums))
        case .artists:
            ArtistsView(model: libraryCache.items(for: .artists))
        case .songs:
            SongsView(model: libraryCache.items(for: .songs))
        case .playlists:
            PlaylistsView(model: libraryCache.items(for: .playlists))
        case .favorites:
            FavouritesView(
                songs: libraryCache.items(for: .favouriteSongs),
                albums: libraryCache.items(for: .favouriteAlbums),
                artists: libraryCache.items(for: .favouriteArtists)
            )
        case .search:
            SearchView()
        }
    }
}

/// iPhone "Library" tab: a hub linking to each browsing section.
///
/// The links carry the section as a value so the push lands in the stack's
/// ``LibraryNavigator/path`` like every other one. A `NavigationLink` holding
/// its destination inline pushes a screen the path knows nothing about, and the
/// stack then has more views on it than the path has elements — so the next
/// push, of an album or artist from the section below, gets reconciled against
/// the section screen instead of landing on top of it.
struct LibraryHubView: View {
    var body: some View {
        List {
            ForEach(LibrarySection.libraryGroup) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
        }
        .navigationTitle("Library")
    }
}
