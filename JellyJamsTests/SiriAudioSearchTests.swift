#if os(iOS)
import XCTest
@testable import JellyJams

/// ``SiriAudioSearch`` turns a spoken or typed phrase into ranked library
/// matches. These tests exercise the "Title by Artist" splitting and its
/// fallbacks purely through the stubbed network layer — no SiriKit
/// invocation is involved, so they run fine on the iOS Simulator (and
/// therefore via Command+U in Xcode, or `xcodebuild test` with an iOS
/// Simulator destination).
final class SiriAudioSearchTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    /// Extracts a stable "kind:id" summary from the results, since
    /// ``AudioEntity`` has no synthesized `Equatable` conformance of its own.
    private func summarize(_ entities: [AudioEntity]) -> [String] {
        entities.map { entity in
            switch entity {
            case .song(let song): "song:\(song.id)"
            case .album(let album): "album:\(album.id)"
            case .artist(let artist): "artist:\(artist.id)"
            case .playlist(let playlist): "playlist:\(playlist.id)"
            }
        }
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
}
#endif
