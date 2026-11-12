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
    /// Registers the navigation destinations for library items, genres,
    /// sections and downloaded groups, so the values ``LibraryNavigator``
    /// appends to a stack's path — and the ones its value-based
    /// `NavigationLink`s carry — resolve through ``ItemDetailRouter``,
    /// ``GenreResultsView``, ``SectionRootView`` and the offline details.
    /// Applied once per navigation stack by ``LibraryNavigationStack``.
    ///
    /// Every push in the app goes through one of these, which keeps the stack's
    /// depth and its path in step. A `NavigationLink` that holds its destination
    /// inline pushes a screen the path has no element for, and a stack whose
    /// path disagrees with what it is showing resolves later pushes against the
    /// wrong screen.
    ///
    /// The destinations are handed the stack's navigator rather than left to
    /// find it in the environment: on macOS, inside the sidebar-adaptable
    /// `TabView`, environment set on the `NavigationStack` reaches its root
    /// but never the screens it pushes — and the screens these build declare
    /// the navigator (``TrackListDetail``, ``TrackRow``, ``ItemContextMenu``),
    /// which `@Environment` resolves as soon as a view renders.
    ///
    /// ``SimilarItemsSection`` and ``GenreChips`` push through it rather than
    /// through a `NavigationLink`: both sit inside a single `List` row on the
    /// album screen (``TrackListDetail``), and a `List` turns any row that
    /// contains a `NavigationLink` into one tap target — so a whole grid or
    /// flow of them collapses into a single button that opens whichever link
    /// is last (and, on iOS, each gets a disclosure chevron). A plain `Button`
    /// that appends to the path gets none of that treatment.
    func libraryNavigationDestinations(navigator: LibraryNavigator) -> some View {
        navigationDestination(for: BaseItemDto.self) {
            ItemDetailRouter(item: $0)
                .environment(navigator)
        }
        .navigationDestination(for: GenreRef.self) {
            GenreResultsView(genre: $0)
                .environment(navigator)
        }
        .navigationDestination(for: LibrarySection.self) {
            SectionRootView(section: $0)
                .environment(navigator)
        }
        .navigationDestination(for: DownloadedGroupRef.self) { ref in
            DownloadedGroupDestination(ref: ref)
                .environment(navigator)
        }
    }
}

/// Resolves a downloaded-group push through the store, which is the source of
/// truth for what is on disk; the ref only identifies it. An album or artist
/// whose last song has been removed resolves to nothing, so the screen says so
/// rather than opening an empty offline detail; a playlist resolves while its
/// membership record exists, and its detail reports what is still on disk.
private struct DownloadedGroupDestination: View {
    let ref: DownloadedGroupRef

    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        if let group = downloads.group(id: ref.id, kind: ref.kind) {
            if group.kind == .artist {
                DownloadedArtistDetail(artist: group)
            } else {
                DownloadedCollectionDetail(group: group)
            }
        } else {
            ContentUnavailableView {
                Label("No Longer Downloaded", systemImage: "arrow.down.circle")
            } description: {
                Text("“\(ref.title)” has no downloaded songs any more.")
            }
        }
    }
}
