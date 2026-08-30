import Foundation
import XCTest
@testable import JellyJams

final class JellyfinServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testItemQueryPreservesBasePathAndUsesCommaDelimitedGenreIDs() async throws {
        URLProtocolStub.handler = { request in
            let components = try XCTUnwrap(
                request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            )
            XCTAssertEqual(components.path, "/jellyfin/Items")
            let query = components.queryItems ?? []
            let genreIDs = query
                .filter { $0.name == "genreIds" }
                .compactMap(\.value)
                .flatMap { $0.split(separator: ",").map(String.init) }
            XCTAssertEqual(genreIDs, ["genre-one", "genre-two"])
            XCTAssertEqual(query.last(where: { $0.name == "recursive" })?.value, "true")
            XCTAssertEqual(query.last(where: { $0.name == "userId" })?.value, "user-id")

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: components.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let data = Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8)
            return (response, data)
        }

        let client = makeClient()
        _ = try await client.getItems(
            includeItemTypes: [.musicAlbum],
            recursive: true,
            genreIds: ["genre-one", "genre-two"]
        )
    }

    func testItemQueryRejectsItemsWithoutIdentifiers() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let data = Data(#"{"Items":[{"Name":"Missing ID"}],"TotalRecordCount":1,"StartIndex":0}"#.utf8)
            return (response, data)
        }

        do {
            _ = try await makeClient().getItems()
            XCTFail("Expected an incomplete SDK item to be rejected")
        } catch JellyfinError.missingItemIdentifier {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamURLIncludesPlaybackSessionAndCredentials() throws {
        let url = try makeClient().streamURL(
            itemId: "track-id",
            mediaSourceId: "source-id",
            playSessionId: "session-id"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = components.queryItems ?? []

        XCTAssertEqual(components.path, "/jellyfin/Audio/track-id/stream")
        XCTAssertEqual(query.last(where: { $0.name == "api_key" })?.value, "token")
        XCTAssertEqual(query.last(where: { $0.name == "deviceId" })?.value, "device-id")
        XCTAssertEqual(query.last(where: { $0.name == "mediaSourceId" })?.value, "source-id")
        XCTAssertEqual(query.last(where: { $0.name == "playSessionId" })?.value, "session-id")
    }

    func testLogoutReportsSessionEndedForRegularUsers() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Sessions/Logout")
            XCTAssertEqual(request.httpMethod, "POST")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data())
        }

        try await makeClient().logout()
    }

    // MARK: - Playlists & track resolution

    func testAddItemsToPlaylistSendsBatchedIdsForLargeSelections() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 204), Data())
        }

        let ids = (0 ..< 150).map { "track-\($0)" }
        try await makeClient().addItemsToPlaylist(playlistId: "playlist-id", itemIds: ids)

        let requests = recorder.all
        XCTAssertEqual(requests.count, 2, "150 items should be sent in two batches")
        XCTAssertEqual(Set(requests.map(\.path)), ["/jellyfin/Playlists/playlist-id/Items"])
        XCTAssertEqual(Set(requests.map(\.method)), ["POST"])
        XCTAssertEqual(requests.map { $0.values(for: "ids").count }, [100, 50])
        XCTAssertEqual(requests.flatMap { $0.values(for: "ids") }, ids)
        XCTAssertEqual(Set(requests.compactMap { $0.value(for: "userId") }), ["user-id"])
    }

    func testCreatePlaylistPostsAudioPlaylistThenAppendsRemainingItems() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            if request.url?.path == "/jellyfin/Playlists" {
                return (try emptyResponse(for: request, statusCode: 200), Data(#"{"Id":"new-playlist"}"#.utf8))
            }
            return (try emptyResponse(for: request, statusCode: 204), Data())
        }

        let ids = (0 ..< 120).map { "track-\($0)" }
        let playlistId = try await makeClient().createPlaylist(name: "  Road Trip  ", itemIds: ids)

        XCTAssertEqual(playlistId, "new-playlist")
        let requests = recorder.all
        XCTAssertEqual(requests.count, 2)

        let creation = try XCTUnwrap(requests.first)
        XCTAssertEqual(creation.path, "/jellyfin/Playlists")
        XCTAssertEqual(creation.method, "POST")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: creation.body) as? [String: Any]
        )
        XCTAssertEqual(body["Name"] as? String, "  Road Trip  ")
        XCTAssertEqual(body["MediaType"] as? String, "Audio")
        XCTAssertEqual(body["UserId"] as? String, "user-id")
        XCTAssertEqual(body["Ids"] as? [String], Array(ids.prefix(100)))

        let append = try XCTUnwrap(requests.last)
        XCTAssertEqual(append.path, "/jellyfin/Playlists/new-playlist/Items")
        XCTAssertEqual(append.values(for: "ids"), Array(ids.suffix(20)))
    }

    func testCreatePlaylistWithoutSeedItemsOmitsIdentifiers() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), Data(#"{"Id":"new-playlist"}"#.utf8))
        }

        _ = try await makeClient().createPlaylist(name: "Empty", itemIds: [])

        let requests = recorder.all
        XCTAssertEqual(requests.count, 1, "An empty playlist needs no follow-up append")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(requests.first).body) as? [String: Any]
        )
        XCTAssertNil(body["Ids"])
    }

    func testTracksForAlbumRequestsChildAudioInDiscAndTrackOrder() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await makeClient().tracks(for: TestFixtures.item(id: "album-id", type: .musicAlbum))

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.path, "/jellyfin/Items")
        XCTAssertEqual(request.value(for: "parentId"), "album-id")
        XCTAssertEqual(request.values(for: "includeItemTypes"), ["Audio"])
        XCTAssertEqual(request.values(for: "sortBy"), ["ParentIndexNumber", "IndexNumber", "SortName"])
    }

    func testTracksForArtistRequestsAudioByArtistIdentifier() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await makeClient().tracks(for: TestFixtures.item(id: "artist-id", type: .musicArtist))

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.path, "/jellyfin/Items")
        XCTAssertEqual(request.values(for: "artistIds"), ["artist-id"])
        XCTAssertEqual(request.values(for: "includeItemTypes"), ["Audio"])
        XCTAssertNil(request.value(for: "parentId"))
    }

    func testTracksForPlaylistUsesPlaylistItemsEndpoint() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await makeClient().tracks(for: TestFixtures.item(id: "playlist-id", type: .playlist))

        XCTAssertEqual(try XCTUnwrap(recorder.all.first).path, "/jellyfin/Playlists/playlist-id/Items")
    }

    func testTracksForSongResolvesToItselfWithoutARequest() async throws {
        URLProtocolStub.handler = { _ in
            XCTFail("A song should not need to be expanded")
            throw URLError(.badServerResponse)
        }

        let song = TestFixtures.item(id: "song-id", type: .audio)
        let tracks = try await makeClient().tracks(for: song)

        XCTAssertEqual(tracks.compactMap(\.id), ["song-id"])
    }

    // MARK: - Artwork URLs

    /// Artwork resolution walks a fallback chain: the item's own primary image,
    /// then its album's, then a tagless request for container types, then
    /// nothing. Getting this wrong shows blank tiles across the whole library.
    func testArtworkUsesTheItemsOwnPrimaryImageTagWhenPresent() throws {
        let track = BaseItemDto(
            albumID: "album-id",
            albumPrimaryImageTag: "album-tag",
            id: "track-id",
            imageTags: ["Primary": "track-tag"],
            type: .audio
        )

        let url = try XCTUnwrap(makeClient().artworkURL(for: track, size: 320))

        XCTAssertTrue(url.path.contains("/Items/track-id/Images/Primary"), url.path)
        XCTAssertEqual(queryValue(url, "tag"), "track-tag")
        XCTAssertEqual(queryValue(url, "maxWidth"), "320")
        XCTAssertEqual(queryValue(url, "maxHeight"), "320")
    }

    func testATrackWithoutItsOwnArtworkFallsBackToItsAlbum() throws {
        let track = BaseItemDto(
            albumID: "album-id",
            albumPrimaryImageTag: "album-tag",
            id: "track-id",
            type: .audio
        )

        let url = try XCTUnwrap(makeClient().artworkURL(for: track, size: 96))

        XCTAssertTrue(url.path.contains("/Items/album-id/Images/Primary"), url.path)
        XCTAssertEqual(queryValue(url, "tag"), "album-tag")
    }

    func testContainerTypesStillGetATaglessArtworkRequest() throws {
        for type in [ItemType.musicAlbum, .musicArtist, .playlist, .genre, .musicGenre] {
            let item = BaseItemDto(id: "container-id", type: type)

            let url = try XCTUnwrap(
                makeClient().artworkURL(for: item, size: 500),
                "\(type) should still request artwork"
            )

            XCTAssertTrue(url.path.contains("/Items/container-id/Images/Primary"), url.path)
            XCTAssertNil(queryValue(url, "tag"))
        }
    }

    /// A track with no artwork anywhere must resolve to nil so the view draws
    /// its placeholder instead of firing a request that 404s.
    func testATrackWithNoArtworkAnywhereResolvesToNil() {
        let track = BaseItemDto(id: "track-id", type: .audio)

        XCTAssertNil(makeClient().artworkURL(for: track, size: 96))
    }

    func testArtworkURLIsAuthenticatedSoTheImageLoaderCanFetchIt() throws {
        let album = BaseItemDto(id: "album-id", type: .musicAlbum)

        let url = try XCTUnwrap(makeClient().artworkURL(for: album, size: 320))

        XCTAssertEqual(queryValue(url, "api_key"), "token")
    }

    func testArtworkForAnItemWithoutAnIdentifierIsNil() {
        XCTAssertNil(makeClient().artworkURL(itemId: nil))
    }

    // MARK: - Failure paths

    func testStreamURLRequiresAnItemIdentifier() {
        XCTAssertThrowsError(
            try makeClient().streamURL(itemId: nil, mediaSourceId: "source-id")
        ) { error in
            XCTAssertEqual(error as? JellyfinError, .missingItemIdentifier)
        }
    }

    func testRequestsWithoutCredentialsFailBeforeReachingTheNetwork() async {
        URLProtocolStub.handler = { _ in
            XCTFail("An unauthenticated client must not send a request")
            throw URLError(.badServerResponse)
        }
        let anonymous = JellyfinService(
            baseURL: URL(string: "https://example.com/jellyfin")!,
            deviceInfo: TestFixtures.deviceInfo
        )

        do {
            _ = try await anonymous.getItems()
            XCTFail("Expected a not-authenticated error")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .notAuthenticated)
        }
    }

    func testAddingItemsToPlaylistRejectsAnEmptySelection() async {
        do {
            try await makeClient().addItemsToPlaylist(playlistId: "playlist-id", itemIds: [])
            XCTFail("Expected an empty selection to be rejected")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .missingItemIdentifier)
        }
    }

    func testPlaylistItemsRequiresAPlaylistIdentifier() async {
        do {
            _ = try await makeClient().getPlaylistItems(playlistId: nil)
            XCTFail("Expected a missing playlist id to be rejected")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .missingItemIdentifier)
        }
    }

    func testResolvingTracksForAnItemWithoutAnIdentifierFails() async {
        do {
            _ = try await makeClient().tracks(for: BaseItemDto(type: .musicAlbum))
            XCTFail("Expected a missing item id to be rejected")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .missingItemIdentifier)
        }
    }

    /// A batch that lands exactly on the limit must go out as one request, not
    /// two (one of them empty).
    func testAnExactlyFullBatchIsSentAsASingleRequest() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 204), Data())
        }

        let ids = (0 ..< 100).map { "track-\($0)" }
        try await makeClient().addItemsToPlaylist(playlistId: "playlist-id", itemIds: ids)

        XCTAssertEqual(recorder.all.count, 1)
        XCTAssertEqual(recorder.all.first?.values(for: "ids"), ids)
    }

    /// `/Genres` returns `Genre` while `/MusicGenres` returns `MusicGenre`, so
    /// both kinds have to take the genre branch rather than being browsed as
    /// a parent folder.
    func testTracksForAGenreRequestsAudioByGenreIdentifier() async throws {
        for type in [ItemType.genre, .musicGenre] {
            let recorder = RequestRecorder()
            URLProtocolStub.handler = { request in
                recorder.record(request)
                return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
            }

            _ = try await makeClient().tracks(for: TestFixtures.item(id: "genre-id", type: type))

            let request = try XCTUnwrap(recorder.all.first)
            XCTAssertEqual(request.values(for: "genreIds"), ["genre-id"], "\(type)")
            XCTAssertEqual(request.values(for: "includeItemTypes"), ["Audio"], "\(type)")
            XCTAssertNil(request.value(for: "parentId"), "\(type) is a filter, not a parent")
        }
    }

    func testGenreLookupPassesTheSearchTermToTheGenresEndpoint() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await makeClient().getGenres(searchTerm: "shoegaze", limit: 10)

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.path, "/jellyfin/Genres")
        XCTAssertEqual(request.value(for: "searchTerm"), "shoegaze")
        XCTAssertEqual(request.value(for: "limit"), "10")
    }

    /// The name-based genre filter is a separate parameter from `genreIds`;
    /// sending both would narrow to items matching each, not either.
    func testItemQueryPassesGenreNamesSeparatelyFromIdentifiers() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        _ = try await makeClient().getItems(
            includeItemTypes: [.musicAlbum],
            recursive: true,
            genres: ["Shoegaze"]
        )

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.values(for: "genres"), ["Shoegaze"])
        XCTAssertTrue(request.values(for: "genreIds").isEmpty)
    }

    func testMarkingAndUnmarkingAFavouriteUseTheMatchingVerbs() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            // The endpoint answers with the item's updated user data.
            return (try emptyResponse(for: request, statusCode: 200), Data(#"{"Key":"track-id","IsFavorite":true}"#.utf8))
        }

        try await makeClient().setFavourite(itemId: "track-id", isFavorite: true)
        try await makeClient().setFavourite(itemId: "track-id", isFavorite: false)

        XCTAssertEqual(recorder.all.map(\.method), ["POST", "DELETE"])
        XCTAssertEqual(
            Set(recorder.all.map(\.path)),
            ["/jellyfin/UserFavoriteItems/track-id"]
        )
    }

    func testSettingAFavouriteRequiresAnItemIdentifier() async {
        do {
            try await makeClient().setFavourite(itemId: nil, isFavorite: true)
            XCTFail("Expected a missing item id to be rejected")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .missingItemIdentifier)
        }
    }

    private func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .last { $0.name == name }?
            .value
    }

    private func makeClient() -> JellyfinService {
        TestFixtures.stubbedClient()
    }
}
