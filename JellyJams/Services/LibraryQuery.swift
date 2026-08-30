import Foundation

/// A browsable list of library items, described independently of how it is
/// fetched.
///
/// This is the cache identity: ``LibraryCache`` keeps one ``PagedItems`` per
/// case for the lifetime of a sign-in, so leaving a list and coming back
/// restores its loaded pages, sort selection and scroll position. Sort
/// deliberately lives in ``LibraryQuery`` rather than here — keying the cache
/// on the sort too would accumulate a separate copy of the list for every sort
/// permutation the user tries.
enum LibraryList: String, Hashable, Sendable, CaseIterable {
    case albums
    case artists
    case songs
    case playlists
    case favouriteSongs
    case favouriteAlbums
    case favouriteArtists

    /// The kind of item the list contains. The favourite lists request exactly
    /// the same item types as their browse counterparts and differ only by
    /// ``filters``, so the repository handles both from one branch.
    enum Content: Hashable, Sendable {
        case albums
        case artists
        case songs
        case playlists
    }

    var content: Content {
        switch self {
        case .albums, .favouriteAlbums: .albums
        case .artists, .favouriteArtists: .artists
        case .songs, .favouriteSongs: .songs
        case .playlists: .playlists
        }
    }

    /// Server-side filters that narrow the list. Only the favourite lists use
    /// one; everything else browses the whole library.
    var filters: [ItemFilter]? {
        switch self {
        case .favouriteSongs, .favouriteAlbums, .favouriteArtists: [.isFavorite]
        case .albums, .artists, .songs, .playlists: nil
        }
    }

    /// Track lists page in smaller batches than the artwork grids: each row is
    /// cheap to render, so a smaller page reaches the screen sooner.
    var pageSize: Int {
        switch content {
        case .songs: 200
        case .albums, .artists, .playlists: 300
        }
    }

    var defaultSortBy: SortBy {
        switch self {
        case .albums, .favouriteAlbums: .albumArtist
        case .artists, .favouriteArtists, .playlists: .sortName
        case .songs, .favouriteSongs: .artist
        }
    }

    var defaultSortOrder: SortOrder { .ascending }

    /// Sort fields offered in the list's toolbar menu. An empty array means the
    /// list has no sort field picker — either because the order is fixed
    /// (playlists, favourite songs) or because only the direction is
    /// adjustable (artists).
    var sortOptions: [SortBy] {
        switch self {
        case .albums, .favouriteAlbums:
            [.albumArtist, .sortName, .dateCreated, .productionYear, .random]
        case .songs:
            [.artist, .sortName, .album, .albumArtist, .dateCreated, .datePlayed, .runtime, .random]
        case .favouriteArtists:
            [.sortName, .random]
        case .artists, .playlists, .favouriteSongs:
            []
        }
    }
}

/// A ``LibraryList`` together with the sort applied to it: the complete
/// description of what to fetch, and the key ``PagedItems`` uses to decide
/// whether the items it already holds still answer the question being asked.
struct LibraryQuery: Hashable, Sendable {
    var list: LibraryList
    var sortBy: SortBy
    var sortOrder: SortOrder

    init(list: LibraryList, sortBy: SortBy? = nil, sortOrder: SortOrder? = nil) {
        self.list = list
        self.sortBy = sortBy ?? list.defaultSortBy
        self.sortOrder = sortOrder ?? list.defaultSortOrder
    }
}
