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
    /// Cap on an artist's songs from albums they don't headline. Guest
    /// appearances rarely run this long; the cap is headroom, not a routine
    /// cutoff.
    private static let artistFeatureTrackLimit = 500

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
            return try await playlistPage(query, startIndex: startIndex, limit: limit)
        }
    }

    /// A page of playlists, split by name when the query asks for one half of
    /// the AudioMuse-AI partition.
    ///
    /// The split is applied here rather than by the server. Jellyfin's only
    /// name query is `searchTerm`, which matches anywhere in a name and would
    /// still need a local pass to insist on the ending; and trimming a page in
    /// place would break ``PagedItems``, which advances its start index by the
    /// number of items it was *handed* — so a filtered page would ask for the
    /// same window again forever. A split list is therefore fetched whole and
    /// returned as one complete page, with a total that counts what is actually
    /// shown. An unsplit list pages exactly as before.
    ///
    /// Deliberately no cap on the whole-list fetch: unlike ``JellyfinService``'s
    /// `getPlaylists()`, which feeds a menu that nobody scrolls past a few
    /// hundred entries, this response *is* the screen's content, so a limit
    /// would quietly leave stations out of a large library.
    private func playlistPage(
        _ query: LibraryQuery,
        startIndex: Int,
        limit: Int
    ) async throws -> BaseItemDtoQueryResult {
        let client = try requireClient()
        let nameFilter = query.nameFilter

        let result = try await client.getItems(
            includeItemTypes: [.playlist],
            mediaTypes: [.audio],
            recursive: true,
            sortBy: query.sortBy,
            sortOrder: query.sortOrder,
            filters: query.list.filters,
            startIndex: nameFilter == nil ? startIndex : nil,
            limit: nameFilter == nil ? limit : nil
        )

        guard let nameFilter else { return result }
        let kept = (result.items ?? []).filter { nameFilter.matches($0.name ?? "") }
        return BaseItemDtoQueryResult(
            items: kept,
            startIndex: startIndex,
            totalRecordCount: kept.count
        )
    }

    // MARK: - Home

    /// Which of Jellyfin's "latest" streams a home row wants. Albums and
    /// artists are requested separately because the endpoint filters by item
    /// type, and a mixed request would let one kind crowd out the other.
    enum LatestKind: Sendable, Equatable {
        case albums
        case artists

        var itemType: ItemType {
            switch self {
            case .albums: .musicAlbum
            case .artists: .musicArtist
            }
        }
    }

    /// The newest music of one kind, newest first.
    func latestItems(_ kind: LatestKind, limit: Int) async throws -> [BaseItemDto] {
        let client = try requireClient()
        guard limit > 0 else { return [] }
        return try await client.getLatestMedia(includeItemTypes: [kind.itemType], limit: limit)
    }

    /// Resolves specific item ids, in whatever order the server answers.
    ///
    /// Ids the server no longer knows are simply absent from the result, which
    /// is how the caller tells a deleted item from a failed request: a failure
    /// throws, an answer is authoritative.
    func items(withIds ids: [String]) async throws -> [BaseItemDto] {
        let client = try requireClient()
        guard !ids.isEmpty else { return [] }
        let result = try await client.getItems(recursive: true, ids: ids, limit: ids.count)
        return result.items ?? []
    }

    /// The first `limit` AudioMuse-AI stations, by name.
    ///
    /// Reuses the same whole-list fetch and name split as the AI Radio screen:
    /// Jellyfin cannot filter by name ending, so a window applied server-side
    /// could hide matches beyond it.
    func aiRadioStations(nameFilter: PlaylistNameFilter, limit: Int) async throws -> [BaseItemDto] {
        guard limit > 0 else { return [] }
        let result = try await page(
            LibraryQuery(list: .aiRadioPlaylists, nameFilter: nameFilter),
            startIndex: 0,
            limit: limit
        )
        return Array((result.items ?? []).prefix(limit))
    }

    // MARK: - Detail screens

    /// Every audio track belonging to a collection item, in playback order.
    func tracks(for item: BaseItemDto) async throws -> [BaseItemDto] {
        try await requireClient().tracks(for: item)
    }

    /// Removes entries from a playlist; entry ids come from
    /// `BaseItemDto.playlistItemID`, not the track id.
    func removeFromPlaylist(playlistId: String?, entryIds: [String]) async throws {
        try await requireClient().removeFromPlaylist(playlistId: playlistId, entryIds: entryIds)
    }

    /// Moves a playlist entry to a new position; the entry id comes from
    /// `BaseItemDto.playlistItemID`, not the track id.
    func moveInPlaylist(playlistId: String?, entryId: String, to index: Int) async throws {
        try await requireClient().moveItemInPlaylist(playlistId: playlistId, entryId: entryId, to: index)
    }

    struct ArtistOverview: Sendable, Equatable {
        var albums: [BaseItemDto] = []
        var appearsOn: [BaseItemDto] = []
        /// The artist's songs on albums they don't headline, grouped per
        /// album and ordered like `appearsOn`.
        var featuredAlbums: [FeaturedAlbum] = []
        /// Capped random sample of the artist's tracks, backing the header's
        /// Play/Shuffle buttons.
        var playbackSample: [BaseItemDto] = []
        /// Total tracks the artist appears on. `playbackSample` is capped,
        /// so its count is not this.
        var songCount: Int = 0

        /// One "appears on" album and the artist's songs that appear on it.
        struct FeaturedAlbum: Sendable, Equatable, Identifiable {
            let album: BaseItemDto
            let tracks: [BaseItemDto]

            var id: String { album.id ?? album.displayName }
        }
    }

    /// An artist's albums (newest first), albums they only appear on, their
    /// songs on those albums, plus a random sample of their tracks. The
    /// first three are fetched concurrently where possible; the featured
    /// songs need the appears-on ids, so they cost a second round trip.
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
        // The web app's "Appears On": albums where the artist contributed
        // (compilations, features) without being the album artist.
        async let appearsOnResult = client.getItems(
            includeItemTypes: [.musicAlbum],
            recursive: true,
            sortBy: .productionYear,
            sortOrder: .descending,
            contributingArtistIds: [artistId],
            limit: Self.artistAlbumLimit
        )
        // The header's Play/Shuffle buttons need a sample of the artist's
        // own songs; the sample's total doubles as the page's song count.
        async let tracksResult = client.getItems(
            includeItemTypes: [.audio],
            recursive: true,
            sortBy: .random,
            artistIds: [artistId],
            limit: Self.artistTrackLimit
        )

        let results = try await (albumsResult, appearsOnResult, tracksResult)
        let albums = results.0.items ?? []
        // Servers differ on whether contributingArtistIds also returns albums
        // the artist led, so never show the same album in both sections.
        let ownIds = Set(albums.compactMap(\.id))
        let appearsOn = (results.1.items ?? []).filter { item in
            guard let id = item.id else { return false }
            return !ownIds.contains(id)
        }

        // The artist's songs on those albums can only be asked for once the
        // album ids exist, so this is a deliberate second round trip — and
        // it is skipped entirely for artists with nothing to appear on.
        var featuredAlbums: [ArtistOverview.FeaturedAlbum] = []
        let appearsOnIds = appearsOn.compactMap(\.id)
        if !appearsOnIds.isEmpty {
            let featuredResult = try await client.getItems(
                includeItemTypes: [.audio],
                recursive: true,
                // Disc then track order. The numbers run per album, so
                // albums arrive interleaved; the grouping re-collects them,
                // and each album keeps that disc/track order.
                sortBy: .discAndTrack,
                artistIds: [artistId],
                albumIds: appearsOnIds,
                limit: Self.artistFeatureTrackLimit
            )
            featuredAlbums = Self.featuredAlbums(
                grouping: featuredResult.items ?? [],
                in: appearsOn
            )
        }

        return ArtistOverview(
            albums: albums,
            appearsOn: appearsOn,
            featuredAlbums: featuredAlbums,
            playbackSample: results.2.items ?? [],
            songCount: results.2.totalRecordCount ?? results.2.items?.count ?? 0
        )
    }

    /// Groups guest songs by the album they appear on, ordered like the
    /// "Appears On" grid they sit beneath, keeping each album's server-
    /// supplied disc/track order. Songs whose album is not in `albums` — a
    /// server that ignored the `albumIds` filter, or an item missing its
    /// album id — are dropped rather than shown under a heading nobody can
    /// trace back to the grid.
    private static func featuredAlbums(
        grouping tracks: [BaseItemDto],
        in albums: [BaseItemDto]
    ) -> [ArtistOverview.FeaturedAlbum] {
        var byAlbumId: [String: [BaseItemDto]] = [:]
        for track in tracks {
            guard let albumId = track.albumID else { continue }
            byAlbumId[albumId, default: []].append(track)
        }
        return albums.compactMap { album in
            guard let id = album.id, let albumTracks = byAlbumId[id], !albumTracks.isEmpty else {
                return nil
            }
            return ArtistOverview.FeaturedAlbum(album: album, tracks: albumTracks)
        }
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
