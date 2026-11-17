#if os(iOS) || os(tvOS)
import XCTest
@testable import JellyJams

/// ``SiriAudioSearch`` turns a spoken or typed phrase into ranked library
/// matches. These tests exercise the "Title by Artist" splitting and its
/// fallbacks purely through the stubbed network layer — no SiriKit
/// invocation is involved, so they run fine on the iOS and tvOS Simulators
/// (and therefore via Command+U in Xcode, or `xcodebuild test` with a
/// Simulator destination).
final class SiriAudioSearchTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    /// Extracts a stable "kind:id" summary from the results.
    private func summarize(_ candidates: [SiriCandidate]) -> [String] {
        candidates.map { "\($0.kind.rawValue):\($0.id)" }
    }

    /// Routes `/Items` (and `/Items` via `getAlbumArtists`) requests to
    /// `responses`, which inspects the recorded query to decide what to
    /// return.
    private func installStub(responses: @escaping (RecordedRequest) -> Data) {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), responses(RecordedRequest(request)))
        }
    }

    func testSearchWithEmptyQueryReturnsNoResultsAndMakesNoRequests() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        let results = try await SiriAudioSearch.search(matching: "   ", client: TestFixtures.stubbedClient())

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(recorder.all.isEmpty, "A blank query should short-circuit before any request is made")
    }

    func testSearchWithoutASeparatorPerformsAGeneralSearchAcrossAllKinds() async throws {
        installStub { request in
            guard request.value(for: "searchTerm") == "Whiplash" else { return emptyItemsPayload }
            switch request.values(for: "includeItemTypes").first {
            case "Audio": return itemsPayload([(id: "song-1", type: "Audio")])
            case "MusicAlbum": return itemsPayload([(id: "album-1", type: "MusicAlbum")])
            case "MusicArtist": return itemsPayload([(id: "artist-1", type: "MusicArtist")])
            case "Playlist": return itemsPayload([(id: "playlist-1", type: "Playlist")])
            default: return emptyItemsPayload
            }
        }

        let results = try await SiriAudioSearch.search(matching: "Whiplash", client: TestFixtures.stubbedClient())

        XCTAssertEqual(
            summarize(results),
            ["song:song-1", "album:album-1", "artist:artist-1", "playlist:playlist-1"],
            "A plain query searches every kind, songs first"
        )
    }

    func testSearchWithTitleByArtistUsesATargetedSearchWhenTheArtistResolves() async throws {
        installStub { request in
            if request.values(for: "includeItemTypes").first == "MusicArtist" {
                XCTAssertEqual(request.value(for: "searchTerm"), "Architects")
                return itemsPayload([(id: "architects-id", type: "MusicArtist")])
            }
            if request.values(for: "includeItemTypes").first == "Audio" {
                XCTAssertEqual(request.values(for: "artistIds"), ["architects-id"])
                XCTAssertEqual(request.value(for: "searchTerm"), "Whiplash")
                return itemsPayload([(id: "whiplash-song", type: "Audio")])
            }
            if request.values(for: "includeItemTypes").first == "MusicAlbum" {
                XCTAssertEqual(request.values(for: "albumArtistIds"), ["architects-id"])
                return itemsPayload([(id: "whiplash-album", type: "MusicAlbum")])
            }
            return emptyItemsPayload
        }

        let results = try await SiriAudioSearch.search(matching: "Whiplash by Architects", client: TestFixtures.stubbedClient())

        XCTAssertEqual(
            summarize(results),
            ["song:whiplash-song", "album:whiplash-album", "artist:architects-id"],
            "A resolved artist narrows songs and albums to their catalogue, with the artist itself trailing"
        )
    }

    func testSearchUsesTheLastByOccurrenceSoTitlesContainingByStillSplitCorrectly() async throws {
        installStub { request in
            if request.values(for: "includeItemTypes").first == "MusicArtist" {
                XCTAssertEqual(request.value(for: "searchTerm"), "Ben E. King")
                return itemsPayload([(id: "ben-e-king", type: "MusicArtist")])
            }
            if request.values(for: "includeItemTypes").first == "Audio" {
                XCTAssertEqual(request.value(for: "searchTerm"), "Stand By Me")
                return itemsPayload([(id: "stand-by-me", type: "Audio")])
            }
            return emptyItemsPayload
        }

        let results = try await SiriAudioSearch.search(
            matching: "Stand By Me by Ben E. King",
            client: TestFixtures.stubbedClient()
        )

        XCTAssertEqual(summarize(results), ["song:stand-by-me", "artist:ben-e-king"])
    }

    func testSearchFallsBackToAGeneralSearchWhenTheArtistDoesNotResolve() async throws {
        installStub { request in
            guard request.values(for: "includeItemTypes").first != "MusicArtist" else { return emptyItemsPayload }
            // The fallback searches the whole phrase first; only the song
            // kind is stocked, so the other kinds correctly return nothing.
            guard request.value(for: "searchTerm") == "Whiplash by Architects",
                  request.values(for: "includeItemTypes").first == "Audio" else {
                return emptyItemsPayload
            }
            return itemsPayload([(id: "literal-match", type: "Audio")])
        }

        let results = try await SiriAudioSearch.search(matching: "Whiplash by Architects", client: TestFixtures.stubbedClient())

        XCTAssertEqual(
            summarize(results),
            ["song:literal-match"],
            "When no artist matches, the full phrase is tried as a literal search before anything else"
        )
    }

    func testSearchFallsBackToATitleOnlySearchWhenNothingElseMatches() async throws {
        installStub { request in
            guard request.values(for: "includeItemTypes").first != "MusicArtist" else { return emptyItemsPayload }
            // Neither the artist nor the full phrase matches anything;
            // only a search for the title alone turns up a result.
            guard request.value(for: "searchTerm") == "Whiplash",
                  request.values(for: "includeItemTypes").first == "Audio" else {
                return emptyItemsPayload
            }
            return itemsPayload([(id: "title-only-match", type: "Audio")])
        }

        let results = try await SiriAudioSearch.search(matching: "Whiplash by Architects", client: TestFixtures.stubbedClient())

        XCTAssertEqual(summarize(results), ["song:title-only-match"])
    }

    // MARK: Typed searches

    func testTypedSongSearchKeepsTheTitleByArtistSplitAndOnlySongs() async throws {
        installStub { request in
            if request.values(for: "includeItemTypes").first == "MusicArtist" {
                return itemsPayload([(id: "architects-id", type: "MusicArtist")])
            }
            if request.values(for: "includeItemTypes").first == "Audio" {
                XCTAssertEqual(request.values(for: "artistIds"), ["architects-id"])
                XCTAssertEqual(request.value(for: "searchTerm"), "Whiplash")
                return itemsPayload([(id: "whiplash-song", type: "Audio")])
            }
            if request.values(for: "includeItemTypes").first == "MusicAlbum" {
                return itemsPayload([(id: "whiplash-album", type: "MusicAlbum")])
            }
            return emptyItemsPayload
        }

        let results = try await SiriAudioSearch.search(
            kind: .song,
            matching: "Whiplash by Architects",
            client: TestFixtures.stubbedClient()
        )

        XCTAssertEqual(
            summarize(results),
            ["song:whiplash-song"],
            "A typed song request keeps the split but drops the other kinds"
        )
    }

    func testTypedAlbumSearchQueriesAlbumsDirectly() async throws {
        installStub { request in
            guard request.values(for: "includeItemTypes").first == "MusicAlbum",
                  request.value(for: "searchTerm") == "For All Kings" else {
                return emptyItemsPayload
            }
            return itemsPayload([(id: "album-1", type: "MusicAlbum")])
        }

        let results = try await SiriAudioSearch.search(
            kind: .album,
            matching: "For All Kings",
            client: TestFixtures.stubbedClient()
        )

        XCTAssertEqual(summarize(results), ["album:album-1"])
    }

    func testTypedArtistSearchQueriesArtistsDirectly() async throws {
        installStub { request in
            guard request.values(for: "includeItemTypes").first == "MusicArtist",
                  request.value(for: "searchTerm") == "Architects" else {
                return emptyItemsPayload
            }
            return itemsPayload([(id: "artist-1", type: "MusicArtist")])
        }

        let results = try await SiriAudioSearch.search(
            kind: .artist,
            matching: "Architects",
            client: TestFixtures.stubbedClient()
        )

        XCTAssertEqual(summarize(results), ["artist:artist-1"])
    }

    func testTypedPlaylistSearchQueriesAudioPlaylistsDirectly() async throws {
        installStub { request in
            guard request.values(for: "includeItemTypes").first == "Playlist",
                  request.values(for: "mediaTypes").first == "Audio",
                  request.value(for: "searchTerm") == "Top 40" else {
                return emptyItemsPayload
            }
            return itemsPayload([(id: "playlist-1", type: "Playlist")])
        }

        let results = try await SiriAudioSearch.search(
            kind: .playlist,
            matching: "Top 40",
            client: TestFixtures.stubbedClient()
        )

        XCTAssertEqual(summarize(results), ["playlist:playlist-1"])
    }

    func testTypedSearchWithAnEmptyQueryReturnsNoResultsAndMakesNoRequests() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        let results = try await SiriAudioSearch.search(kind: .album, matching: "   ", client: TestFixtures.stubbedClient())

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(recorder.all.isEmpty, "A blank query should short-circuit before any request is made")
    }
}

#if os(iOS)
/// The artists a song or album entity carries are entities Shortcuts can pass
/// on — to "Play Artist", say — so they must name real library artists.
final class SiriEntityArtistTests: XCTestCase {
    /// The bug this guards: these artists were built from names alone, with
    /// the name doubling as the id, so passing one on resolved nothing.
    func testASongsArtistsCarryTheirServerIds() {
        let song = SongEntity(
            item: BaseItemDto(
                artistItems: [NameIDPair(id: "artist-1", name: "Architects")],
                artists: ["Architects"],
                id: "song-1",
                name: "Whiplash",
                type: .audio
            ),
            artworkURL: nil
        )

        XCTAssertEqual(song.artists.map(\.id), ["artist-1"])
        XCTAssertEqual(song.artists.map(\.name), ["Architects"])
    }

    func testAnAlbumsArtistsCarryTheirServerIds() {
        let album = AlbumEntity(
            item: BaseItemDto(
                albumArtist: "Architects",
                albumArtists: [NameIDPair(id: "artist-1", name: "Architects")],
                id: "album-1",
                name: "Lost Forever // Lost Together",
                type: .musicAlbum
            ),
            artworkURL: nil
        )

        XCTAssertEqual(album.artists.map(\.id), ["artist-1"])
    }
}
#endif // os(iOS)
#endif // os(iOS) || os(tvOS)
