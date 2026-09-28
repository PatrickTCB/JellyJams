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
    /// The playlists AudioMuse-AI generates, kept apart from ``playlists`` by
    /// ``LibraryQuery/nameFilter``. A separate list — and so a separate
    /// ``PagedItems`` — because it is its own screen with its own scroll
    /// position, not the same list rendered differently.
    case aiRadioPlaylists
    case favouriteSongs
    case favouriteAlbums
    case favouriteArtists
    case favouritePlaylists

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
        case .playlists, .aiRadioPlaylists, .favouritePlaylists: .playlists
        }
    }

    /// Server-side filters that narrow the list. Only the favourite lists use
    /// one; everything else browses the whole library. Splitting AI Radio out
    /// of the playlists is a *name* rule, which Jellyfin cannot express, so it
    /// lives in ``LibraryQuery/nameFilter`` instead.
    var filters: [ItemFilter]? {
        switch self {
        case .favouriteSongs, .favouriteAlbums, .favouriteArtists, .favouritePlaylists: [.isFavorite]
        case .albums, .artists, .songs, .playlists, .aiRadioPlaylists: nil
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
        case .artists, .favouriteArtists, .playlists, .aiRadioPlaylists, .favouritePlaylists: .sortName
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
        case .artists, .playlists, .aiRadioPlaylists, .favouriteSongs, .favouritePlaylists:
            []
        }
    }
}

/// Splits the playlist list in two by a name ending — how the playlists
/// AudioMuse-AI generates are told apart from the ones the user made.
///
/// Jellyfin has no "name ends with" query, so the rule is described here and
/// applied by ``LibraryRepository`` to what the server returns.
enum PlaylistNameFilter: Hashable, Sendable {
    /// Only playlists whose name ends with this.
    case endsWith(String)
    /// Every playlist except those whose name ends with this.
    case notEndsWith(String)

    /// Whether a playlist name belongs to this side of the split. Compared
    /// case-insensitively: the suffix is a convention of the generator, not
    /// something the user typed to match it exactly.
    func matches(_ name: String) -> Bool {
        switch self {
        case .endsWith(let suffix):
            return Self.endsIgnoringCase(name, suffix)
        case .notEndsWith(let suffix):
            return !Self.endsIgnoringCase(name, suffix)
        }
    }

    /// The name with the ending taken off, for showing a station under its own
    /// name rather than the generator's marker — "Chill_automatic" is called
    /// "Chill" once it has its own section to live in.
    ///
    /// Recognition follows ``matches(_:)``, so whatever was identified as a
    /// station is what gets trimmed, at any case. Names that don't carry the
    /// ending come back untouched, as does a name that *is* the ending and
    /// would otherwise be shown as nothing.
    func trimmingMatchedEnding(from name: String) -> String {
        switch self {
        case .endsWith(let suffix), .notEndsWith(let suffix):
            guard Self.endsIgnoringCase(name, suffix) else { return name }
            let trimmed = name.dropLast(suffix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? name : trimmed
        }
    }

    private static func endsIgnoringCase(_ name: String, _ suffix: String) -> Bool {
        name.lowercased().hasSuffix(suffix.lowercased())
    }
}

/// A ``LibraryList`` together with the sort applied to it: the complete
/// description of what to fetch, and the key ``PagedItems`` uses to decide
/// whether the items it already holds still answer the question being asked.
struct LibraryQuery: Hashable, Sendable {
    var list: LibraryList
    var sortBy: SortBy
    var sortOrder: SortOrder
    /// The playlist-name split this query wants, if any. Nil for every list
    /// that isn't a playlist list, and for playlist lists while the AI Radio
    /// feature is off.
    var nameFilter: PlaylistNameFilter?

    init(
        list: LibraryList,
        sortBy: SortBy? = nil,
        sortOrder: SortOrder? = nil,
        nameFilter: PlaylistNameFilter? = nil
    ) {
        self.list = list
        self.sortBy = sortBy ?? list.defaultSortBy
        self.sortOrder = sortOrder ?? list.defaultSortOrder
        self.nameFilter = nameFilter
    }
}
