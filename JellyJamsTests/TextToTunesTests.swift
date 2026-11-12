import XCTest
@testable import JellyJams

/// ``TextToTunes`` is the shared pipeline behind the Home screen's sparkles
/// button and Siri's fallback: description out to `GET /text-to-tunes`,
/// resolved picks back. These tests drive both ends through
/// ``URLProtocolStub``, so the routing of the backend and the ordering rule
/// of `tracks(byIds:)` are exercised exactly as the app will.
final class TextToTunesTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    private func destination() -> TextToTunes.Destination {
        TextToTunes.Destination(backend: TestFixtures.stubbedBackend(), userID: "user-id")
    }

    func testDestinationNeedsABackendAddressAndASignedInUser() {
        let info = TestFixtures.deviceInfo
        XCTAssertNil(TextToTunes.destination(address: "", deviceInfo: info, userID: "user-id"))
        XCTAssertNil(TextToTunes.destination(address: "not a url", deviceInfo: info, userID: "user-id"))
        XCTAssertNil(TextToTunes.destination(address: "backend.example.com", deviceInfo: info, userID: nil))
        XCTAssertNotNil(TextToTunes.destination(address: "backend.example.com", deviceInfo: info, userID: "user-id"))
    }

    /// The description and limit ride the query string, and the picks come
    /// back as whole tracks in the order the backend chose them — even
    /// though the Jellyfin server answered its ids query in its own order.
    func testTracksSendsTheDescriptionAndReturnsThePicksInOrder() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            guard request.url?.path == "/text-to-tunes" else {
                return (try emptyResponse(for: request, statusCode: 200), itemsPayload([(id: "x1", type: "Audio"), (id: "x2", type: "Audio")]))
            }
            return (try emptyResponse(for: request, statusCode: 200), Data(#"{"NewTrackIDs":["x2","x1"],"Count":2}"#.utf8))
        }

        let tracks = try await TextToTunes.tracks(
            description: "Up tempo folk about Canada",
            limit: 30,
            destination: destination(),
            client: TestFixtures.stubbedClient()
        )

        let tunes = try XCTUnwrap(recorder.all.first { $0.path == "/text-to-tunes" })
        XCTAssertEqual(tunes.value(for: "userID"), "user-id")
        XCTAssertEqual(tunes.value(for: "query"), "Up tempo folk about Canada")
        XCTAssertEqual(tunes.value(for: "limit"), "30")
        XCTAssertEqual(tracks.map(\.id), ["x2", "x1"], "The backend's order is the playback order")
    }

    func testTracksReportsWhenTheBackendPicksNothing() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data(#"{"NewTrackIDs":[],"Count":0}"#.utf8))
        }

        do {
            _ = try await TextToTunes.tracks(
                description: "songs that do not exist",
                limit: 10,
                destination: destination(),
                client: TestFixtures.stubbedClient()
            )
            XCTFail("Expected no picks to be reported")
        } catch let error as TextToTunes.Failure {
            XCTAssertEqual(error, .noPicks)
        }
    }

    func testTracksReportsWhenNoneOfThePicksResolveOnTheServer() async throws {
        URLProtocolStub.handler = { request in
            guard request.url?.path == "/text-to-tunes" else {
                return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
            }
            return (try emptyResponse(for: request, statusCode: 200), Data(#"{"NewTrackIDs":["gone-1","gone-2"],"Count":2}"#.utf8))
        }

        do {
            _ = try await TextToTunes.tracks(
                description: "anything",
                limit: 10,
                destination: destination(),
                client: TestFixtures.stubbedClient()
            )
            XCTFail("Expected unresolvable picks to be reported")
        } catch let error as TextToTunes.Failure {
            XCTAssertEqual(error, .noneResolvable)
        }
    }

    /// A refusal keeps its own voice: `tracks` wraps only the empty-handed
    /// outcomes, and a backend `422` travels onward as the `BackendError`
    /// that explains it.
    func testTracksPropagatesABackendRefusalUnwrapped() async throws {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 422,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"detail":"query too long"}"#.utf8))
        }

        do {
            _ = try await TextToTunes.tracks(
                description: "whatever",
                limit: 10,
                destination: destination(),
                client: TestFixtures.stubbedClient()
            )
            XCTFail("Expected the refusal to surface")
        } catch let error as BackendError {
            XCTAssertEqual(error, .rejected(status: 422, detail: "query too long"))
        }
    }
}

// MARK: - The Siri sentinel

#if os(iOS)
/// The fallback hinges on the identifier: it is the only thing that survives
/// the system between resolution and playback, so the phrase has to ride in
/// it and come back out of it intact.
final class TextToTunesPlaylistTests: XCTestCase {
    func testThePhraseSurvivesTheRoundTripThroughAnIdentifier() {
        for phrase in [
            "high energy rock",
            "Up tempo folk about Canada",
            "80s metal & power ballads",
            "songs with a slash / in the words",
            "100% über-crust, mostly instrumental",
            // Another sentinel's id arriving as spoken words: encoded, it
            // can never be mistaken for the plain one.
            DefaultPlaybackPlaylist.id,
            TextToTunesPlaylist.idPrefix,
        ] {
            XCTAssertEqual(
                TextToTunesPlaylist.query(in: TextToTunesPlaylist.id(query: phrase)),
                phrase,
                "Round trip of '\(phrase)'"
            )
        }
    }

    func testOrdinaryIdentifiersCarryNoPhrase() {
        XCTAssertNil(TextToTunesPlaylist.query(in: "0f8fad5b-d9cb-469f-a165-70867728950e"))
        XCTAssertNil(TextToTunesPlaylist.query(in: DefaultPlaybackPlaylist.id))
        XCTAssertNil(TextToTunesPlaylist.query(in: FavouriteSongsPlaylist.id))
        XCTAssertNil(TextToTunesPlaylist.query(in: ""))
    }

    func testAMalformedEscapeStillYieldsItsWords() {
        // Only `id(query:)` mints these ids, but a hand-corrupted one should
        // lose its escapes, not the request.
        XCTAssertEqual(
            TextToTunesPlaylist.query(in: TextToTunesPlaylist.idPrefix + "50%zz rock"),
            "50%zz rock"
        )
    }

    func testTheSentinelIsAPlaylistNamedForItsPhraseAndNothingOnTheServer() {
        let entity = TextToTunesPlaylist.entity(query: "high energy rock")
        XCTAssertEqual(entity.id, TextToTunesPlaylist.id(query: "high energy rock"))
        XCTAssertEqual(entity.titleOverride, "high energy rock")
        XCTAssertNil(entity.item, "The fallback has no server counterpart until the backend answers")
    }

    /// The system rehydrates entities by id between resolution and play;
    /// the sentinel has to resolve without a server, exactly like the
    /// favourites shuffle and the default-playback sentinel do.
    func testRehydrationResolvesTheSentinelWithoutAServer() async throws {
        URLProtocolStub.handler = { request in
            XCTFail("The sentinel must not reach the network: \(request.url!)")
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        let sentinelID = TextToTunesPlaylist.id(query: "heavy metal break-up songs")
        let entities = try await PlaylistQuery().entities(for: [sentinelID])
        XCTAssertEqual(entities.map(\.id), [sentinelID])
        XCTAssertEqual(entities.first?.titleOverride, "heavy metal break-up songs")
    }
}
#endif
