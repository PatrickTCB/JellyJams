import Foundation
import XCTest
@testable import JellyJams

/// Covers the translation from UI intent (a ``LibraryQuery``, an artist, a
/// search term) into the Jellyfin requests actually sent. These assertions are
/// the contract every browse screen depends on, so a query built wrongly here
/// shows up as a failing test rather than a screen full of the wrong items.
final class LibraryRepositoryTests: XCTestCase {
    private var recorder = RequestRecorder()

    override func setUp() {
        super.setUp()
        recorder = RequestRecorder()
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    // MARK: - Paged lists

    func testAlbumsQueryRequestsAlbumsRecursivelyWithoutFilters() async throws {
        let request = try await recordPage(for: LibraryQuery(list: .albums))

        XCTAssertEqual(request.path, "/jellyfin/Items")
        XCTAssertEqual(request.values(for: "includeItemTypes"), ["MusicAlbum"])
        XCTAssertEqual(request.value(for: "recursive"), "true")
        XCTAssertTrue(request.values(for: "filters").isEmpty)
    }

    func testArtistsQueryRequestsArtists() async throws {
        let request = try await recordPage(for: LibraryQuery(list: .artists))

        XCTAssertEqual(request.values(for: "includeItemTypes"), ["MusicArtist"])
        XCTAssertTrue(request.values(for: "filters").isEmpty)
    }

    func testSongsQueryRequestsAudio() async throws {
        let request = try await recordPage(for: LibraryQuery(list: .songs))

        XCTAssertEqual(request.values(for: "includeItemTypes"), ["Audio"])
        XCTAssertTrue(request.values(for: "filters").isEmpty)
    }

    func testPlaylistsQueryRestrictsToAudioPlaylists() async throws {
        let request = try await recordPage(for: LibraryQuery(list: .playlists))

        XCTAssertEqual(request.values(for: "includeItemTypes"), ["Playlist"])
        XCTAssertEqual(request.values(for: "mediaTypes"), ["Audio"])
    }

    /// Each favourite list must request the same item type as its browse
    /// counterpart, adding only the favourite filter.
    func testFavouriteListsAddTheFavouriteFilterToTheirBrowseCounterpart() async throws {
        let expected: [(LibraryList, String)] = [
            (.favouriteSongs, "Audio"),
            (.favouriteAlbums, "MusicAlbum"),
            (.favouriteArtists, "MusicArtist"),
        ]

        for (list, itemType) in expected {
            let request = try await recordPage(for: LibraryQuery(list: list))

            XCTAssertEqual(request.values(for: "includeItemTypes"), [itemType], "\(list)")
            XCTAssertEqual(request.values(for: "filters"), ["IsFavorite"], "\(list)")
        }
    }

    func testBrowseListsNeverRequestTheFavouriteFilter() async throws {
        for list in [LibraryList.albums, .artists, .songs, .playlists] {
            let request = try await recordPage(for: LibraryQuery(list: list))

            XCTAssertTrue(request.values(for: "filters").isEmpty, "\(list)")
        }
    }

    func testQuerySortAndWindowReachTheServer() async throws {
        let query = LibraryQuery(list: .songs, sortBy: .dateCreated, sortOrder: .descending)
        let request = try await recordPage(for: query, startIndex: 40, limit: 20)

        XCTAssertEqual(request.values(for: "sortBy"), ["DateCreated", "SortName"])
        XCTAssertEqual(request.value(for: "sortOrder"), "Descending")
        XCTAssertEqual(request.value(for: "startIndex"), "40")
        XCTAssertEqual(request.value(for: "limit"), "20")
    }

    /// Sort defaults live on the list, so a query built without an explicit
    /// sort still asks the server for a sensible order.
    func testQueryDefaultsToTheListsOwnSort() async throws {
        let request = try await recordPage(for: LibraryQuery(list: .albums))

        XCTAssertEqual(request.values(for: "sortBy"), ["AlbumArtist", "SortName"])
        XCTAssertEqual(request.value(for: "sortOrder"), "Ascending")
    }

    // MARK: - Artist overview

    func testArtistOverviewFetchesAlbumsAndTracksForThatArtistOnly() async throws {
        URLProtocolStub.handler = { [recorder] request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await TestFixtures.stubbedRepository()
            .artistOverview(for: TestFixtures.item(id: "artist-id", type: .musicArtist))

        let requests = recorder.all
        XCTAssertEqual(requests.count, 2)

        let albums = try XCTUnwrap(requests.first { $0.values(for: "includeItemTypes") == ["MusicAlbum"] })
        XCTAssertEqual(albums.values(for: "albumArtistIds"), ["artist-id"])
        XCTAssertEqual(albums.value(for: "sortOrder"), "Descending")

        let tracks = try XCTUnwrap(requests.first { $0.values(for: "includeItemTypes") == ["Audio"] })
        XCTAssertEqual(tracks.values(for: "artistIds"), ["artist-id"])
    }

    /// An artist with no id would otherwise have its filter dropped from the
    /// query, quietly returning the entire library as that artist's albums.
    func testArtistOverviewRefusesAnArtistWithoutAnIdentifier() async {
        URLProtocolStub.handler = { [recorder] request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        do {
            _ = try await TestFixtures.stubbedRepository()
                .artistOverview(for: BaseItemDto(type: .musicArtist))
            XCTFail("Expected a missing identifier error")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .missingItemIdentifier)
        }
        XCTAssertTrue(recorder.all.isEmpty, "No request should be sent for an unidentified artist")
    }

    func testArtistOverviewSeparatesAlbumsFromTracks() async throws {
        URLProtocolStub.handler = { request in
            let isAlbums = RecordedRequest(request).values(for: "includeItemTypes") == ["MusicAlbum"]
            let id = isAlbums ? "album-1" : "track-1"
            let type = isAlbums ? "MusicAlbum" : "Audio"
            let payload = Data(#"{"Items":[{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)"}],"TotalRecordCount":1,"StartIndex":0}"#.utf8)
            return (try emptyResponse(for: request, statusCode: 200), payload)
        }

        let overview = try await TestFixtures.stubbedRepository()
            .artistOverview(for: TestFixtures.item(id: "artist-id", type: .musicArtist))

        XCTAssertEqual(overview.albums.compactMap(\.id), ["album-1"])
        XCTAssertEqual(overview.topTracks.compactMap(\.id), ["track-1"])
    }

    // MARK: - Search

    func testSearchQueriesGenresArtistsAlbumsAndSongsWithTheSameTerm() async throws {
        URLProtocolStub.handler = { [recorder] request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await TestFixtures.stubbedRepository().search(term: "portishead")

        let requests = recorder.all
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(Set(requests.compactMap { $0.value(for: "searchTerm") }), ["portishead"])
        XCTAssertEqual(requests.filter { $0.path == "/jellyfin/Genres" }.count, 1)
        XCTAssertEqual(
            Set(requests.flatMap { $0.values(for: "includeItemTypes") }),
            ["MusicArtist", "MusicAlbum", "Audio", "MusicGenre"]
        )
    }

    func testSearchSortsResultsIntoTheirSections() async throws {
        URLProtocolStub.handler = { request in
            let recorded = RecordedRequest(request)
            guard recorded.path != "/jellyfin/Genres" else {
                return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
            }
            let type = recorded.values(for: "includeItemTypes").first ?? "Audio"
            return (try emptyResponse(for: request, statusCode: 200), itemsPayload([(type + "-1", type)]))
        }

        let results = try await TestFixtures.stubbedRepository().search(term: "x")

        XCTAssertEqual(results.artists.compactMap(\.id), ["MusicArtist-1"])
        XCTAssertEqual(results.albums.compactMap(\.id), ["MusicAlbum-1"])
        XCTAssertEqual(results.songs.compactMap(\.id), ["Audio-1"])
        XCTAssertFalse(results.isEmpty)
    }

    /// Typing a genre name matches no track title, so the albums and songs
    /// tagged with the matched genre are folded into the results.
    func testSearchFoldsGenreTaggedAlbumsAndSongsIntoTheResults() async throws {
        URLProtocolStub.handler = { [recorder] request in
            recorder.record(request)
            let recorded = RecordedRequest(request)
            if recorded.path == "/jellyfin/Genres" {
                return (try emptyResponse(for: request, statusCode: 200), itemsPayload([("genre-1", "MusicGenre")]))
            }
            guard !recorded.values(for: "genreIds").isEmpty else {
                // Nothing in the library is *named* "shoegaze".
                return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
            }
            let type = recorded.values(for: "includeItemTypes").first ?? "Audio"
            return (try emptyResponse(for: request, statusCode: 200), itemsPayload([("tagged-" + type, type)]))
        }

        let results = try await TestFixtures.stubbedRepository().search(term: "shoegaze")

        XCTAssertEqual(results.genres.compactMap(\.id), ["genre-1"])
        XCTAssertEqual(results.albums.compactMap(\.id), ["tagged-MusicAlbum"])
        XCTAssertEqual(results.songs.compactMap(\.id), ["tagged-Audio"])

        let foldIn = recorder.all.filter { !$0.values(for: "genreIds").isEmpty }
        XCTAssertEqual(foldIn.count, 2, "Only albums and songs are folded in")
        XCTAssertEqual(Set(foldIn.flatMap { $0.values(for: "genreIds") }), ["genre-1"])
    }

    func testSearchSkipsTheFoldInWhenNoGenreMatches() async throws {
        URLProtocolStub.handler = { [recorder] request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await TestFixtures.stubbedRepository().search(term: "portishead")

        XCTAssertEqual(recorder.all.count, 4, "A term matching no genre costs one round trip")
    }

    /// An album matching both the term and the genre must appear once, and name
    /// matches lead — an exact title is what the user most likely meant.
    func testSearchKeepsNameMatchesFirstAndDropsDuplicateGenreMatches() async throws {
        URLProtocolStub.handler = { request in
            let recorded = RecordedRequest(request)
            if recorded.path == "/jellyfin/Genres" {
                return (try emptyResponse(for: request, statusCode: 200), itemsPayload([("genre-1", "MusicGenre")]))
            }
            guard recorded.values(for: "includeItemTypes") == ["MusicAlbum"] else {
                return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
            }
            let payload = recorded.values(for: "genreIds").isEmpty
                ? itemsPayload([("album-both", "MusicAlbum")])
                : itemsPayload([("album-genre", "MusicAlbum"), ("album-both", "MusicAlbum")])
            return (try emptyResponse(for: request, statusCode: 200), payload)
        }

        let results = try await TestFixtures.stubbedRepository().search(term: "x")

        XCTAssertEqual(results.albums.compactMap(\.id), ["album-both", "album-genre"])
    }

    /// A broad term like "rock" can match many genres; the fold-in is capped so
    /// the follow-up request stays a sensible length.
    func testSearchFoldsInAtMostFiveMatchedGenres() async throws {
        let genreIds = (1 ... 8).map { "genre-\($0)" }
        URLProtocolStub.handler = { [recorder] request in
            recorder.record(request)
            let payload = RecordedRequest(request).path == "/jellyfin/Genres"
                ? itemsPayload(genreIds.map { ($0, "MusicGenre") })
                : emptyItemsPayload
            return (try emptyResponse(for: request, statusCode: 200), payload)
        }

        _ = try await TestFixtures.stubbedRepository().search(term: "rock")

        let foldIn = recorder.all.filter { !$0.values(for: "genreIds").isEmpty }
        XCTAssertEqual(foldIn.count, 2)
        for request in foldIn {
            XCTAssertEqual(request.values(for: "genreIds"), Array(genreIds.prefix(5)))
        }
    }

    func testEmptySearchResultsReportThemselvesAsEmpty() {
        XCTAssertTrue(LibraryRepository.SearchResults().isEmpty)
        XCTAssertTrue(LibraryRepository.GenreContents().isEmpty)
    }

    /// A term that matches only a genre still has something to show.
    func testSearchResultsWithOnlyGenresAreNotEmpty() {
        let results = LibraryRepository.SearchResults(
            genres: [TestFixtures.item(id: "genre-1", type: .musicGenre)]
        )

        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - Genre contents

    /// One recursive request for both kinds, so the screen costs a single
    /// round trip.
    func testGenreContentsRequestsAlbumsAndArtistsInOneRecursiveRequest() async throws {
        URLProtocolStub.handler = { [recorder] request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await TestFixtures.stubbedRepository()
            .genreContents(GenreRef(id: "genre-id", name: "Shoegaze"))

        let requests = recorder.all
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "/jellyfin/Items")
        XCTAssertEqual(Set(request.values(for: "includeItemTypes")), ["MusicAlbum", "MusicArtist"])
        XCTAssertEqual(request.value(for: "recursive"), "true")
        XCTAssertEqual(request.values(for: "genreIds"), ["genre-id"])
        XCTAssertTrue(
            request.values(for: "genres").isEmpty,
            "Sending the name alongside the id would AND the two filters"
        )
    }

    /// Genres taken from an item's name-only metadata have no id, so they are
    /// matched by name instead.
    func testGenreContentsFiltersByNameWhenTheGenreHasNoIdentifier() async throws {
        URLProtocolStub.handler = { [recorder] request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await TestFixtures.stubbedRepository().genreContents(GenreRef(name: "Shoegaze"))

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(recorder.all.count, 1)
        XCTAssertEqual(request.values(for: "genres"), ["Shoegaze"])
        XCTAssertTrue(request.values(for: "genreIds").isEmpty)
    }

    /// Both kinds arrive interleaved in one response, so the split is done
    /// here rather than by the server.
    func testGenreContentsSplitsTheResponseByItemType() async throws {
        URLProtocolStub.handler = { request in
            let payload = itemsPayload([
                ("album-1", "MusicAlbum"),
                ("artist-1", "MusicArtist"),
                ("album-2", "MusicAlbum")
            ])
            return (try emptyResponse(for: request, statusCode: 200), payload)
        }

        let contents = try await TestFixtures.stubbedRepository()
            .genreContents(GenreRef(id: "genre-id", name: "Shoegaze"))

        XCTAssertEqual(contents.artists.compactMap(\.id), ["artist-1"])
        XCTAssertEqual(contents.albums.compactMap(\.id), ["album-1", "album-2"])
        XCTAssertFalse(contents.isEmpty)
    }

    // MARK: - Similar items

    /// Each kind must reach its own endpoint. Albums and artists are separate
    /// Jellyfin routes, and asking the wrong one returns other people's music.
    func testSimilarItemsRequestTheEndpointMatchingTheKind() async throws {
        let expected: [(LibraryRepository.SimilarKind, ItemType, String)] = [
            (.albums, .musicAlbum, "/jellyfin/Albums/item-id/Similar"),
            (.artists, .musicArtist, "/jellyfin/Artists/item-id/Similar")
        ]

        for (kind, type, path) in expected {
            let request = try await recordSimilar(kind, type: type, limit: 5)
            XCTAssertEqual(request.path, path)
        }
    }

    /// The limit is the server's job, not a trim applied afterwards: the screens
    /// ask for exactly what they can show, so a wider window must fetch more
    /// rather than the app fetching a fixed number and discarding the rest.
    func testSimilarItemsAskTheServerForExactlyTheNumberRequested() async throws {
        for limit in [3, 5] {
            let request = try await recordSimilar(.albums, type: .musicAlbum, limit: limit)
            XCTAssertEqual(request.value(for: "limit"), String(limit))
        }
    }

    /// A layout that has not measured itself yet has room for nothing, and
    /// `limit=0` asks Jellyfin for the whole list. Short-circuiting keeps that
    /// request off the wire entirely.
    func testSimilarItemsSendNoRequestWhenThereIsNoRoomToShowAny() async throws {
        URLProtocolStub.handler = { [recorder] request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        let similar = try await TestFixtures.stubbedRepository().similarItems(
            .albums,
            to: TestFixtures.item(id: "item-id", type: .musicAlbum),
            limit: 0
        )

        XCTAssertTrue(similar.isEmpty)
        XCTAssertTrue(recorder.all.isEmpty, "A zero limit must not reach the network")
    }

    func testSimilarItemsReturnWhatTheServerSuggests() async throws {
        URLProtocolStub.handler = { request in
            let payload = itemsPayload([("album-1", "MusicAlbum"), ("album-2", "MusicAlbum")])
            return (try emptyResponse(for: request, statusCode: 200), payload)
        }

        let similar = try await TestFixtures.stubbedRepository().similarItems(
            .albums,
            to: TestFixtures.item(id: "item-id", type: .musicAlbum),
            limit: 5
        )

        XCTAssertEqual(similar.compactMap(\.id), ["album-1", "album-2"])
    }

    // MARK: - Signed out

    /// Every read must fail loudly when signed out. Returning empty results
    /// instead is what used to leave screens stuck behind a spinner.
    func testEveryReadThrowsWhenSignedOut() async {
        let repository = TestFixtures.signedOutRepository()

        await assertNotAuthenticated {
            _ = try await repository.page(LibraryQuery(list: .albums), startIndex: 0, limit: 10)
        }
        await assertNotAuthenticated {
            _ = try await repository.tracks(for: TestFixtures.item(id: "album-id", type: .musicAlbum))
        }
        await assertNotAuthenticated {
            _ = try await repository.artistOverview(for: TestFixtures.item(id: "artist-id", type: .musicArtist))
        }
        await assertNotAuthenticated {
            _ = try await repository.search(term: "anything")
        }
        await assertNotAuthenticated {
            _ = try await repository.genreContents(GenreRef(id: "genre-id", name: "Shoegaze"))
        }
        await assertNotAuthenticated {
            _ = try await repository.similarItems(
                .albums,
                to: TestFixtures.item(id: "album-id", type: .musicAlbum),
                limit: 5
            )
        }
    }

    /// Artwork is the one read that returns `nil` rather than throwing, because
    /// it is consumed inline in view bodies where a missing image is a
    /// placeholder and not an error.
    func testArtworkURLIsNilWhenSignedOutAndResolvesWhenSignedIn() {
        let track = BaseItemDto(albumID: "album-id", albumPrimaryImageTag: "tag", id: "track-id", type: .audio)

        XCTAssertNil(TestFixtures.signedOutRepository().artworkURL(for: track, size: 96))
        XCTAssertNotNil(TestFixtures.stubbedRepository().artworkURL(for: track, size: 96))
    }

    // MARK: - Helpers

    /// Sends one page request for `query` and returns what reached the network.
    private func recordPage(
        for query: LibraryQuery,
        startIndex: Int = 0,
        limit: Int = 50
    ) async throws -> RecordedRequest {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await TestFixtures.stubbedRepository()
            .page(query, startIndex: startIndex, limit: limit)

        return try XCTUnwrap(recorder.all.first)
    }

    /// Sends one similar-items request and returns what reached the network.
    private func recordSimilar(
        _ kind: LibraryRepository.SimilarKind,
        type: ItemType,
        limit: Int
    ) async throws -> RecordedRequest {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await TestFixtures.stubbedRepository().similarItems(
            kind,
            to: TestFixtures.item(id: "item-id", type: type),
            limit: limit
        )

        return try XCTUnwrap(recorder.all.first)
    }

    private func assertNotAuthenticated(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected notAuthenticated", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? JellyfinError, .notAuthenticated, file: file, line: line)
        }
    }
}
