import Foundation

/// Every library read the UI performs, in one place.
///
/// Views describe *what* they want — a ``LibraryQuery``, an artist's overview,
/// a search term — and this type owns *how* it is fetched. No view builds a
/// Jellyfin request or reaches into ``SessionStore/client``, so a new screen
/// inherits paging, sorting and error handling instead of reimplementing them.
///
/// The client is optional so that a repository always exists, signed in or
/// not. A read attempted while signed out throws
/// ``JellyfinError/notAuthenticated`` rather than quietly doing nothing, which
/// is what used to leave detail screens behind a spinner that never resolved.
struct LibraryRepository: Sendable {
    let client: JellyfinService?

    /// Albums shown on an artist page. High enough to cover any real
    /// discography without paging.
    private static let artistAlbumLimit = 200
    /// Sample of an artist's tracks backing the header's Play/Shuffle buttons.
    private static let artistTrackLimit = 200

    private static let searchGenreLimit = 10
    private static let searchArtistLimit = 12
    private static let searchAlbumLimit = 20
    private static let searchSongLimit = 40
    /// How many matched genres feed the search fold-in. Searching "rock" can
    /// match Rock, Punk Rock and Rock & Roll; beyond a handful the extra ids
    /// lengthen the request without meaningfully changing what is shown.
    private static let searchGenreFoldIn = 5

    private static let genreItemLimit = 100

    init(client: JellyfinService?) {
        self.client = client
    }

    private func requireClient() throws -> JellyfinService {
        guard let client else { throw JellyfinError.notAuthenticated }
        return client
    }

    // MARK: - Paged lists

    /// Fetches one page of a browsable list. Backs every ``PagedItems``.
    func page(_ query: LibraryQuery, startIndex: Int, limit: Int) async throws -> BaseItemDtoQueryResult {
        let client = try requireClient()
        let filters = query.list.filters

        switch query.list.content {
        case .albums:
            return try await client.getItems(
                includeItemTypes: [.musicAlbum],
                recursive: true,
                sortBy: query.sortBy,
                sortOrder: query.sortOrder,
                filters: filters,
                startIndex: startIndex,
                limit: limit
            )
        case .artists:
            return try await client.getAlbumArtists(
                sortBy: query.sortBy,
                sortOrder: query.sortOrder,
                filters: filters,
                startIndex: startIndex,
                limit: limit
            )
        case .songs:
            return try await client.getItems(
                includeItemTypes: [.audio],
                recursive: true,
                sortBy: query.sortBy,
                sortOrder: query.sortOrder,
                filters: filters,
                startIndex: startIndex,
                limit: limit
            )
        case .playlists:
            return try await client.getItems(
                includeItemTypes: [.playlist],
                mediaTypes: [.audio],
                recursive: true,
                sortBy: query.sortBy,
                sortOrder: query.sortOrder,
                filters: filters,
                startIndex: startIndex,
                limit: limit
            )
        }
    }

    // MARK: - Detail screens

    /// Every audio track belonging to a collection item, in playback order.
    func tracks(for item: BaseItemDto) async throws -> [BaseItemDto] {
        try await requireClient().tracks(for: item)
    }

    struct ArtistOverview: Sendable, Equatable {
        var albums: [BaseItemDto] = []
        var topTracks: [BaseItemDto] = []
    }

    /// An artist's albums (newest first) plus a random sample of their tracks,
    /// fetched concurrently.
    func artistOverview(for artist: BaseItemDto) async throws -> ArtistOverview {
        let client = try requireClient()
        // Without an id the underlying queries would drop the artist filter and
        // return the entire library, so refuse rather than mislead.
        guard let artistId = artist.id else { throw JellyfinError.missingItemIdentifier }

        async let albumsResult = client.getItems(
            includeItemTypes: [.musicAlbum],
            recursive: true,
            sortBy: .productionYear,
            sortOrder: .descending,
            albumArtistIds: [artistId],
            limit: Self.artistAlbumLimit
        )
        async let tracksResult = client.getItems(
            includeItemTypes: [.audio],
            recursive: true,
            sortBy: .random,
            artistIds: [artistId],
            limit: Self.artistTrackLimit
        )

        let results = try await (albumsResult, tracksResult)
        return ArtistOverview(
            albums: results.0.items ?? [],
            topTracks: results.1.items ?? []
        )
    }

    // MARK: - Similar items

    /// Which "similar to this" lookup a screen wants.
    ///
    /// Jellyfin exposes albums and artists as separate endpoints and they are
    /// not interchangeable, so callers say which they mean rather than having
    /// it guessed from an item type that could be anything.
    enum SimilarKind: Sendable, Equatable {
        case albums
        case artists
    }

    /// Music the server considers similar to `item`.
    ///
    /// `limit` is sent to Jellyfin rather than applied to the response: the
    /// screens showing these ask for exactly as many as they have room to
    /// display, so nothing is fetched that cannot be shown.
    func similarItems(_ kind: SimilarKind, to item: BaseItemDto, limit: Int) async throws -> [BaseItemDto] {
        let client = try requireClient()
        guard limit > 0 else { return [] }
        let result: BaseItemDtoQueryResult
        switch kind {
        case .albums:
            result = try await client.getSimilarAlbums(itemId: item.id, limit: limit)
        case .artists:
            result = try await client.getSimilarArtists(itemId: item.id, limit: limit)
        }
        return result.items ?? []
    }

    // MARK: - Search

    struct SearchResults: Sendable, Equatable {
        var genres: [BaseItemDto] = []
        var artists: [BaseItemDto] = []
        var albums: [BaseItemDto] = []
        var songs: [BaseItemDto] = []

        var isEmpty: Bool { genres.isEmpty && artists.isEmpty && albums.isEmpty && songs.isEmpty }
    }

    /// Searches genres, artists, albums and songs concurrently, then folds the
    /// contents of any matched genre into the album and song results.
    ///
    /// The fold-in is what makes a genre name a useful thing to type: searching
    /// "shoegaze" matches no track title, but the user plainly meant the music.
    /// It needs a second round trip because the genres a term matches aren't
    /// known until the first one returns.
    func search(term: String) async throws -> SearchResults {
        let client = try requireClient()

        async let genresResult = client.getGenres(
            searchTerm: term,
            limit: Self.searchGenreLimit
        )
        async let artistsResult = client.getAlbumArtists(
            searchTerm: term,
            limit: Self.searchArtistLimit
        )
        async let albumsResult = client.getItems(
            includeItemTypes: [.musicAlbum],
            recursive: true,
            searchTerm: term,
            limit: Self.searchAlbumLimit
        )
        async let songsResult = client.getItems(
            includeItemTypes: [.audio],
            recursive: true,
            searchTerm: term,
            limit: Self.searchSongLimit
        )

        let results = try await (genresResult, artistsResult, albumsResult, songsResult)
        var found = SearchResults(
            genres: results.0.items ?? [],
            artists: results.1.items ?? [],
            albums: results.2.items ?? [],
            songs: results.3.items ?? []
        )

        // `getGenres` validates that every item carries an id, so matched
        // genres can always be filtered by id.
        let genreIds = Array(found.genres.compactMap(\.id).prefix(Self.searchGenreFoldIn))
        guard !genreIds.isEmpty else { return found }

        async let taggedAlbums = client.getItems(
            includeItemTypes: [.musicAlbum],
            recursive: true,
            sortBy: .sortName,
            sortOrder: .ascending,
            genreIds: genreIds,
            limit: Self.searchAlbumLimit
        )
        async let taggedSongs = client.getItems(
            includeItemTypes: [.audio],
            recursive: true,
            sortBy: .random,
            genreIds: genreIds,
            limit: Self.searchSongLimit
        )

        let tagged = try await (taggedAlbums, taggedSongs)
        // Name matches lead: someone typing an exact album title wants it first,
        // even when the title also happens to be a genre.
        found.albums = Self.merged(
            found.albums,
            tagged.0.items ?? [],
            limit: Self.searchAlbumLimit
        )
        found.songs = Self.merged(
            found.songs,
            tagged.1.items ?? [],
            limit: Self.searchSongLimit
        )
        return found
    }

    /// Appends `additional` to `primary`, skipping items already present and
    /// trimming to `limit`. An album matching both by name and by genre must
    /// appear once.
    private static func merged(
        _ primary: [BaseItemDto],
        _ additional: [BaseItemDto],
        limit: Int
    ) -> [BaseItemDto] {
        var seen = Set(primary.compactMap(\.id))
        var combined = primary
        for item in additional {
            guard let id = item.id, seen.insert(id).inserted else { continue }
            combined.append(item)
        }
        return Array(combined.prefix(limit))
    }

    // MARK: - Genres

    /// The albums and artists tagged with a genre.
    struct GenreContents: Sendable, Equatable {
        var artists: [BaseItemDto] = []
        var albums: [BaseItemDto] = []

        var isEmpty: Bool { artists.isEmpty && albums.isEmpty }
    }

    /// Everything in one genre, in a single request.
    ///
    /// Albums and artists are asked for together and split by type here. That
    /// keeps the screen to one round trip, at the cost of a limit shared
    /// between the two kinds rather than one each.
    func genreContents(_ genre: GenreRef) async throws -> GenreContents {
        let client = try requireClient()
        // Prefer the id. Only a genre taken from an item's name-only metadata
        // lacks one, and Jellyfin matches those by exact name.
        let ids = genre.genreId.map { [$0] }
        let names = genre.genreId == nil ? [genre.name] : nil

        let result = try await client.getItems(
            includeItemTypes: [.musicAlbum, .musicArtist],
            recursive: true,
            sortBy: .sortName,
            sortOrder: .ascending,
            genres: names,
            genreIds: ids,
            limit: Self.genreItemLimit
        )

        let items = result.items ?? []
        return GenreContents(
            artists: items.filter { $0.itemType == .musicArtist },
            albums: items.filter { $0.itemType == .musicAlbum }
        )
    }

    // MARK: - Artwork

    /// Artwork for an item, or `nil` when signed out or the item has no image.
    /// Returning `nil` rather than throwing keeps this usable inline in a view
    /// body, where a missing image is a placeholder and not an error.
    func artworkURL(for item: BaseItemDto, size: Int) -> URL? {
        client?.artworkURL(for: item, size: size)
    }
}
