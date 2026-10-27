import Foundation
import XCTest
@testable import JellyJams

/// Covers the Jelly Jams Backend's `/register` — the one endpoint v1 speaks.
/// The payload shape matters most: the backend writes its fields capitalised,
/// and the app builds its whole Mixtapes split from one of them. A wrong key
/// decode does not crash, it silently never turns the feature on.
final class JellyJamsBackendTests: XCTestCase {
    override func setUp() {
        URLProtocolStub.handler = nil
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
    }

    private static let registrationPayload = Data(
        #"{"User":"pat","Created":true,"Saved":true,"PlaylistSuffix":"_automatic","KafkaIP":"10.0.0.2","KafkaPort":"9092"}"#.utf8
    )

    private func successResponse(statusCode: Int = 201) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        return { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Self.registrationPayload)
        }
    }

    private var account: JellyfinAccount {
        JellyfinAccount(
            userName: "pat",
            userID: "user-id",
            userToken: "access-token",
            jellyfinHost: URL(string: "http://192.168.0.10:8096")!
        )
    }

    // MARK: - The request

    /// `/register` is a POST with everything in the query string — the shape
    /// FastAPI defines. A drift here is a 422 nobody can see until settings
    /// quietly stops working.
    func testRegisterPostsCredentialsAsQueryParameters() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return try self.successResponse()(request)
        }

        _ = try await TestFixtures.stubbedBackend().register(account)

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/register")
        XCTAssertEqual(request.value(for: "userName"), "pat")
        XCTAssertEqual(request.value(for: "userID"), "user-id")
        XCTAssertEqual(request.value(for: "userToken"), "access-token")
        XCTAssertEqual(request.value(for: "jellyfinHost"), "http://192.168.0.10:8096")
    }

    // MARK: - The response

    func testRegistrationDecodesTheCapitalisedPayload() async throws {
        URLProtocolStub.handler = successResponse()

        let registration = try await TestFixtures.stubbedBackend().register(account)

        XCTAssertEqual(registration.user, "pat")
        XCTAssertTrue(registration.created)
        XCTAssertTrue(registration.saved)
        XCTAssertEqual(registration.playlistSuffix, "_automatic")
        XCTAssertEqual(registration.kafkaIP, "10.0.0.2")
        XCTAssertEqual(registration.kafkaPort, "9092")
    }

    /// A known user gets 200 ("already registered"), a new one 201. Both are
    /// success with the same body — treating 200 as an error would make every
    /// second Save in settings fail.
    func testAlreadyRegisteredAnswerOf200IsSuccess() async throws {
        URLProtocolStub.handler = successResponse(statusCode: 200)

        let registration = try await TestFixtures.stubbedBackend().register(account)

        XCTAssertEqual(registration.playlistSuffix, "_automatic")
    }

    /// The backend's `detail` is written for humans and says which part of
    /// the sign-in was refused — it has to survive into the thrown error
    /// rather than collapse into a bare status code.
    func testRejectionSurfacesTheBackendDetail() async throws {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let body = Data(#"{"detail":"User credentials submitted for pat could not be validated"}"#.utf8)
            return (response, body)
        }

        do {
            _ = try await TestFixtures.stubbedBackend().register(account)
            XCTFail("Expected a rejection")
        } catch let error as BackendError {
            XCTAssertEqual(error, .rejected(status: 401, detail: "User credentials submitted for pat could not be validated"))
            XCTAssertTrue(error.userFacingMessage.contains("could not be validated"))
        }
    }

    /// A failure body the app cannot parse must not hide the failure behind a
    /// decoding error — the status is the reliable part of the story.
    func testRejectionWithoutAParseableBodyStillReportsTheStatus() async throws {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )
            )
            return (response, Data("<html>boom</html>".utf8))
        }

        do {
            _ = try await TestFixtures.stubbedBackend().register(account)
            XCTFail("Expected a rejection")
        } catch let error as BackendError {
            XCTAssertEqual(error, .rejected(status: 500, detail: nil))
            XCTAssertTrue(error.userFacingMessage.contains("500"))
        }
    }

    // MARK: - Ping

    /// The settings sheet gates everything on a 200 from /ping. The body is
    /// decoration; the status is the answer.
    func testPingIsSatisfiedWithAPlain200() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 200),
                Data(#"{"message":"pong","now":1234}"#.utf8)
            )
        }

        try await TestFixtures.stubbedBackend().ping()

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/ping")
    }

    func testPingRefusesAnythingButSuccess() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 500), Data())
        }

        do {
            try await TestFixtures.stubbedBackend().ping()
            XCTFail("Expected a failure")
        } catch let error as BackendError {
            XCTAssertEqual(error, .rejected(status: 500, detail: nil))
        }
    }

    // MARK: - Family Blend

    /// The blend endpoints insist on an `itemID` they never read — copied
    /// from `/ban`'s signature — so the client sends the empty one FastAPI
    /// accepts, and this is where dropping it would show up.
    func testFamilyBlendStatusReadsTheLowerCasedAnswer() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            // The deployed backend answers this read with 201 (copied status
            // code); any 2xx has to do.
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"id":"user-id","inFamilyBlend":true}"#.utf8)
            )
        }

        let status = try await TestFixtures.stubbedBackend().familyBlendStatus(userID: "user-id")

        XCTAssertEqual(status.id, "user-id")
        XCTAssertTrue(status.inFamilyBlend)

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/family-blend")
        XCTAssertEqual(request.value(for: "userID"), "user-id")
        XCTAssertEqual(request.value(for: "itemID"), "")
    }

    func testJoiningTheBlendIsAPostTheBackendConfirms() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"id":"user-id","inFamilyBlend":true}"#.utf8)
            )
        }

        let status = try await TestFixtures.stubbedBackend().joinFamilyBlend(userID: "user-id")

        XCTAssertTrue(status.inFamilyBlend)
        XCTAssertEqual(recorder.all.first?.method, "POST")
    }

    func testLeavingTheBlendIsADeleteTheBackendConfirms() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 200),
                Data(#"{"id":"user-id","inFamilyBlend":false}"#.utf8)
            )
        }

        let status = try await TestFixtures.stubbedBackend().leaveFamilyBlend(userID: "user-id")

        XCTAssertFalse(status.inFamilyBlend)
        XCTAssertEqual(recorder.all.first?.method, "DELETE")
    }

    /// Blend endpoints only know registered users; the 401 they answer for
    /// everybody else has to read as the backend's refusal, not a mystery.
    func testBlendForAnUnknownUserSurfacesTheRefusal() async throws {
        URLProtocolStub.handler = { request in
            (
                try emptyResponse(for: request, statusCode: 401),
                Data(#"{"detail":"User user-id does not seem to exist"}"#.utf8)
            )
        }

        do {
            _ = try await TestFixtures.stubbedBackend().familyBlendStatus(userID: "user-id")
            XCTFail("Expected a rejection")
        } catch let error as BackendError {
            XCTAssertEqual(error, .rejected(status: 401, detail: "User user-id does not seem to exist"))
        }
    }

    // MARK: - Bans

    /// `/ban` is a POST keyed on `userID` and `itemID` alone — the kind of
    /// the banned item is the backend's business, not the app's, because
    /// stored bans are matched against the ids each candidate song carries.
    /// Drift here is a 422 nobody sees until banning silently does nothing.
    func testBanningPostsOneItemIDAndReadsTheAnswer() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"Items":{},"Success":true,"AlreadyBanned":false}"#.utf8)
            )
        }

        let answer = try await TestFixtures.stubbedBackend().ban(userID: "user-id", itemID: "song-id")

        XCTAssertTrue(answer.success)
        XCTAssertFalse(answer.alreadyBanned)

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/ban")
        XCTAssertEqual(request.value(for: "userID"), "user-id")
        XCTAssertEqual(request.value(for: "itemID"), "song-id")
    }

    /// Re-banning answers `Success: false, AlreadyBanned: true` with a 201
    /// — the state the user asked for holds either way, so the flags must
    /// decode as an accepted ban, not a failure. The item echo in `Items`
    /// arrives as whole Jellyfin DTOs in a shape `GET /bans` is still
    /// settling; it must not take the answer down with it.
    func testAnAlreadyBannedItemStillReadsAsASuccessfulBan() async throws {
        URLProtocolStub.handler = { request in
            (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"Items":{"Audio":[{"Id":"song-id","Name":"Ban Me","Type":"Audio"}]},"Success":false,"AlreadyBanned":true}"#.utf8)
            )
        }

        let answer = try await TestFixtures.stubbedBackend().ban(userID: "user-id", itemID: "song-id")

        XCTAssertFalse(answer.success)
        XCTAssertTrue(answer.alreadyBanned)
    }

    /// A backend that doesn't know this account answers 401 for bans just
    /// as it does for the blend — its `detail` has to reach the alert.
    func testBanningForAnUnknownUserSurfacesTheRefusal() async throws {
        URLProtocolStub.handler = { request in
            (
                try emptyResponse(for: request, statusCode: 401),
                Data(#"{"detail":"User user-id does not seem to exist"}"#.utf8)
            )
        }

        do {
            _ = try await TestFixtures.stubbedBackend().ban(userID: "user-id", itemID: "song-id")
            XCTFail("Expected a rejection")
        } catch let error as BackendError {
            XCTAssertEqual(error, .rejected(status: 401, detail: "User user-id does not seem to exist"))
        }
    }

    /// `GET /bans` answers with whole server DTOs under the type that was
    /// banned, and the screen needs them as real items — names to show, ids
    /// to navigate and unban by. The SDK's lenient date parser is part of
    /// this contract: Jellyfin timestamps carry fractional seconds that a
    /// plain `JSONDecoder` trips over, which would fail the entire read.
    func testTheBanListGroupsWholeServerItemsByKind() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), bansPayload)
        }

        let bans = try await TestFixtures.stubbedBackend().bans(userID: "user-id")

        XCTAssertEqual(bans.artists.map(\.id), ["artist-2", "artist-1"])
        XCTAssertEqual(bans.albums.map(\.displayName), ["Bad Songs"])
        XCTAssertEqual(bans.songs.map(\.displayName), ["Ban Me Too"])
        // The fields the rows read arrive with the items.
        XCTAssertEqual(bans.songs.first?.album, "Bad Songs")
        XCTAssertEqual(bans.songs.first?.albumID, "album-1")
        XCTAssertEqual(bans.songs.first?.artists, ["Bad Artist", "Worse Artist"])
        XCTAssertEqual(bans.albums.first?.albumArtist, "Bad Artist")
        // A kind the app neither shows nor bans from here is ignored, not fatal.
        XCTAssertFalse(bans.artists.contains { $0.id == "genre-1" })

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/bans")
        XCTAssertEqual(request.value(for: "userID"), "user-id")
    }

    /// A kind nobody has banned has no entry in `Items` at all — that reads
    /// as an empty section, not a failed decode.
    func testTheBanListToleratesMissingCategories() async throws {
        URLProtocolStub.handler = { request in
            (
                try emptyResponse(for: request, statusCode: 200),
                Data(#"{"Items":{"Audio":[{"Id":"song-1","Name":"Ban Me","Type":"Audio"}]},"Success":true,"AlreadyBanned":true}"#.utf8)
            )
        }

        let bans = try await TestFixtures.stubbedBackend().bans(userID: "user-id")

        XCTAssertEqual(bans.songs.map(\.id), ["song-1"])
        XCTAssertTrue(bans.artists.isEmpty)
        XCTAssertTrue(bans.albums.isEmpty)
    }

    /// Unbanning is `DELETE /ban` keyed on the same two parameters the ban
    /// was made with.
    func testUnbanningDeletesTheItemIDForTheUser() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 200),
                Data(#"{"Items":{},"Success":true,"AlreadyBanned":true}"#.utf8)
            )
        }

        let answer = try await TestFixtures.stubbedBackend().unban(userID: "user-id", itemID: "song-id")

        XCTAssertTrue(answer.success)
        XCTAssertTrue(answer.alreadyBanned)

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/ban")
        XCTAssertEqual(request.value(for: "userID"), "user-id")
        XCTAssertEqual(request.value(for: "itemID"), "song-id")
    }

    /// `DELETE /reset-bans` takes the user alone — the whole list is the
    /// unit, and the 201 the handler declares (copied status codes being
    /// this backend's style) is success like any other 2xx.
    func testResettingBansIsOneDeleteForTheWholeUser() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"Items":{},"Success":true,"AlreadyBanned":false}"#.utf8)
            )
        }

        try await TestFixtures.stubbedBackend().resetBans(userID: "user-id")

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/reset-bans")
        XCTAssertEqual(request.value(for: "userID"), "user-id")
    }

    // MARK: - Address normalisation

    /// The backend is an internet service by design, so a bare host gets
    /// `https` — the opposite default to Jellyfin's LAN-facing `http`.
    func testAddressWithoutASchemeDefaultsToHTTPS() throws {
        XCTAssertEqual(
            try JellyJamsBackend.normalizeAddress("jellyjams.example.net"),
            URL(string: "https://jellyjams.example.net")
        )
    }

    /// Someone running the backend on their LAN typed the scheme themselves;
    /// it must be kept, not upgraded.
    func testExplicitHTTPSchemeIsKept() throws {
        XCTAssertEqual(
            try JellyJamsBackend.normalizeAddress(" http://192.168.0.10:8000 "),
            URL(string: "http://192.168.0.10:8000")
        )
    }

    /// Endpoints are built by appending to the stored address, so a trailing
    /// slash left in place would double it (`/backend//register`).
    func testTrailingSlashesAreRemoved() throws {
        XCTAssertEqual(
            try JellyJamsBackend.normalizeAddress("https://jellyjams.example.net/api/"),
            URL(string: "https://jellyjams.example.net/api")
        )
    }

    func testNonsenseAddressesAreRefused() {
        for raw in ["", "   ", "not a url", "ftp://example.net", "https://user:pass@example.net"] {
            XCTAssertThrowsError(
                try JellyJamsBackend.normalizeAddress(raw),
                raw
            ) { error in
                XCTAssertEqual(error as? BackendError, .invalidServerURL)
            }
        }
    }
}
