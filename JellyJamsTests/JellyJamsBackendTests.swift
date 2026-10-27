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
