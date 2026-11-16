import Foundation
import XCTest
@testable import JellyJams

/// The Quick Connect endpoints as the sign-in flow uses them: the enabled
/// gate, the initiation that hands out the code, the approval polls, and
/// the secret-for-session exchange.
final class QuickConnectServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    // MARK: - Enabled

    func testQuickConnectEnabledReadsTheBareBoolean() async throws {
        for (body, expected) in [("true", true), ("false", false)] {
            URLProtocolStub.handler = { request in
                XCTAssertEqual(request.url?.path, "/jellyfin/QuickConnect/Enabled")
                XCTAssertEqual(request.httpMethod, "GET")
                return (try emptyResponse(for: request, statusCode: 200), Data(body.utf8))
            }

            let enabled = await TestFixtures.stubbedClient().isQuickConnectEnabled()

            XCTAssertEqual(enabled, expected, body)
        }
    }

    /// A server too old to know the endpoint — or one that answers anything
    /// but a boolean — reads as disabled, the same as a server that says so.
    func testQuickConnectIsDisabledWhenTheEndpointIsMissingOrUnreadable() async throws {
        for statusCode in [404, 500] {
            URLProtocolStub.handler = { request in
                (try emptyResponse(for: request, statusCode: statusCode), Data())
            }

            let enabled = await TestFixtures.stubbedClient().isQuickConnectEnabled()

            XCTAssertFalse(enabled, "\(statusCode)")
        }

        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data(#"{"Available":true}"#.utf8))
        }

        let enabled = await TestFixtures.stubbedClient().isQuickConnectEnabled()

        XCTAssertFalse(enabled)
    }

    // MARK: - Initiate

    func testInitiateQuickConnectPostsAndReturnsTheSecretAndCode() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 200),
                Data(#"{"Secret":"qc-secret","Code":"123456","Authenticated":false}"#.utf8)
            )
        }

        let (secret, code) = try await TestFixtures.stubbedClient().initiateQuickConnect()

        XCTAssertEqual(secret, "qc-secret")
        XCTAssertEqual(code, "123456")
        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.path, "/jellyfin/QuickConnect/Initiate")
        XCTAssertEqual(request.method, "POST")
    }

    func testInitiateQuickConnectRejectsAnIncompleteAnswer() async {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data(#"{"Secret":"qc-secret"}"#.utf8))
        }

        do {
            _ = try await TestFixtures.stubbedClient().initiateQuickConnect()
            XCTFail("Expected a codeless initiation to be rejected")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .incompleteQuickConnectResponse)
        }
    }

    /// A server with Quick Connect turned off refuses the initiation itself
    /// with a 401 — the same answer the enabled gate gives, so the flow can
    /// fall back to the password form either way.
    func testInitiateQuickConnectReadsARefusalAsNotEnabled() async {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 401), Data())
        }

        do {
            _ = try await TestFixtures.stubbedClient().initiateQuickConnect()
            XCTFail("Expected a refused initiation to be rejected")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .quickConnectNotEnabled)
        }
    }

    // MARK: - Approval state

    func testQuickConnectStatePollsWithTheSecretAndReadsApproval() async throws {
        for (authenticated, expected) in [(true, true), (false, false)] {
            let recorder = RequestRecorder()
            URLProtocolStub.handler = { request in
                recorder.record(request)
                return (
                    try emptyResponse(for: request, statusCode: 200),
                    Data(#"{"Authenticated":\#(authenticated),"Secret":"qc-secret"}"#.utf8)
                )
            }

            let approved = try await TestFixtures.stubbedClient().isQuickConnectAuthenticated(secret: "qc-secret")

            XCTAssertEqual(approved, expected)
            let request = try XCTUnwrap(recorder.all.first)
            XCTAssertEqual(request.path, "/jellyfin/QuickConnect/Connect")
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.value(for: "secret"), "qc-secret")
        }
    }

    /// A secret the server no longer knows answers 404: the code is dead,
    /// and the flow must read that as expiry rather than a transient blip
    /// to be tolerated and polled again.
    func testQuickConnectStateReadsAnUnknownSecretAsExpired() async {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 404), Data())
        }

        do {
            _ = try await TestFixtures.stubbedClient().isQuickConnectAuthenticated(secret: "gone")
            XCTFail("Expected an unknown secret to read as expired")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .quickConnectExpired)
        }
    }

    // MARK: - Exchange

    func testAuthenticateWithQuickConnectPostsTheSecret() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 200),
                Data(#"{"AccessToken":"qc-token","User":{"Id":"qc-user","Name":"QC User"}}"#.utf8)
            )
        }

        let auth = try await TestFixtures.stubbedClient().authenticateWithQuickConnect(secret: "qc-secret")

        XCTAssertEqual(auth.accessToken, "qc-token")
        XCTAssertEqual(auth.user?.id, "qc-user")
        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.path, "/jellyfin/Users/AuthenticateWithQuickConnect")
        XCTAssertEqual(request.method, "POST")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["Secret"] as? String, "qc-secret")
    }
}

/// The whole Quick Connect sign-in as the session runs it: probe, gate,
/// code, approval polls, exchange, and the persisted session — against
/// canned server answers, with the poll wait shrunk to nothing.
@MainActor
final class QuickConnectSignInTests: XCTestCase {
    private let serverAddress = "https://example.com/jellyfin"
    private let currentUserKey = "jellyjams.currentUser"
    private var savedUser: Data?

    override func setUp() async throws {
        // The flows below sign in for real, Keychain and UserDefaults and
        // all; the host app's own session must be left as it was found.
        savedUser = UserDefaults.standard.data(forKey: currentUserKey)
    }

    override func tearDown() async throws {
        URLProtocolStub.handler = nil
        if let savedUser {
            UserDefaults.standard.set(savedUser, forKey: currentUserKey)
        } else {
            UserDefaults.standard.removeObject(forKey: currentUserKey)
        }
        try? Keychain.delete(account: "qc-user")
        try? Keychain.delete(account: "pw-user")
    }

    func testQuickConnectSignInLandsTheSessionAndPersistsIt() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = signInHandler(recorder: recorder)
        let store = makeStore()

        var codes: [String] = []
        for try await code in store.quickConnectSignIn(serverURLString: serverAddress) {
            codes.append(code)
        }

        XCTAssertEqual(codes, ["123456"], "The code is yielded once, for the sheet to show")
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(
            store.currentUser,
            SessionStore.StoredUser(
                id: "qc-user",
                name: "QC User",
                serverURL: URL(string: serverAddress)!,
                serverName: "Test Server"
            )
        )
        XCTAssertEqual(try Keychain.get(account: "qc-user"), "qc-token")
        XCTAssertEqual(store.client?.credentials?.token, "qc-token")

        // The exchange carries the initiation's secret, not the code.
        let exchange = try XCTUnwrap(recorder.all.first { $0.path == "/jellyfin/Users/AuthenticateWithQuickConnect" })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: exchange.body) as? [String: Any])
        XCTAssertEqual(body["Secret"] as? String, "qc-secret")
    }

    /// Approval rarely lands on the first poll: the flow keeps asking,
    /// without re-initiating, until the user has typed the code.
    func testQuickConnectSignInWaitsForApprovalAcrossPolls() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = signInHandler(approvedOnPoll: 3, recorder: recorder)
        let store = makeStore()

        for try await _ in store.quickConnectSignIn(serverURLString: serverAddress) {}

        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(recorder.count(forPath: "/jellyfin/QuickConnect/Connect"), 3)
        XCTAssertEqual(recorder.count(forPath: "/jellyfin/QuickConnect/Initiate"), 1)
    }

    func testQuickConnectSignInRefusesAServerWithoutQuickConnect() async throws {
        URLProtocolStub.handler = signInHandler(enabled: false, recorder: RequestRecorder())
        let store = makeStore()

        do {
            for try await _ in store.quickConnectSignIn(serverURLString: serverAddress) {
                XCTFail("No code should be issued for a server without Quick Connect")
            }
            XCTFail("Expected the disabled server to refuse the flow")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .quickConnectNotEnabled)
        }
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.currentUser)
    }

    /// The code was shown, then went stale before it was typed: the flow
    /// ends with the expiry the sheet answers with a Try Again, and no
    /// exchange is attempted with the dead secret.
    func testQuickConnectSignInReadsAnExpiredSecretAsExpiry() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = signInHandler(expirePolls: true, recorder: recorder)
        let store = makeStore()

        var codes: [String] = []
        do {
            for try await code in store.quickConnectSignIn(serverURLString: serverAddress) {
                codes.append(code)
            }
            XCTFail("Expected the expired code to end the flow")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .quickConnectExpired)
        }
        XCTAssertEqual(codes, ["123456"], "The code was shown before it went stale")
        XCTAssertFalse(store.isSignedIn)
        XCTAssertEqual(recorder.count(forPath: "/jellyfin/Users/AuthenticateWithQuickConnect"), 0)
    }

    /// Dismissing the sheet cancels the consuming task: the polling stops
    /// and the session stays signed out.
    func testCancellingTheFlowLeavesTheSessionSignedOut() async throws {
        URLProtocolStub.handler = signInHandler(approvedOnPoll: .max, recorder: RequestRecorder())
        let store = makeStore()

        let codeShown = AsyncStream<Void>.makeStream()
        let consumer = Task { @MainActor in
            do {
                for try await _ in store.quickConnectSignIn(serverURLString: serverAddress) {
                    codeShown.continuation.yield(())
                }
            } catch {}
        }
        var signal = codeShown.stream.makeAsyncIterator()
        _ = await signal.next()

        consumer.cancel()
        await consumer.value

        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.currentUser)
    }

    func testQuickConnectSignInRejectsAnInvalidAddressBeforeAnyRequest() async {
        URLProtocolStub.handler = { _ in
            XCTFail("An invalid address must not reach the network")
            throw URLError(.badServerResponse)
        }
        let store = makeStore()

        do {
            for try await _ in store.quickConnectSignIn(serverURLString: "ftp://example.com") {}
            XCTFail("Expected an invalid address to be rejected")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .invalidServerURL)
        }
        XCTAssertFalse(store.isSignedIn)
    }

    /// The password sign-in shares its persistence tail with Quick Connect;
    /// it must still land a session exactly as before.
    func testPasswordSignInStillLandsTheSession() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = signInHandler(recorder: recorder)
        let store = makeStore()

        try await store.signIn(serverURLString: serverAddress, username: "pw-user", password: "hunter2")

        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.currentUser?.id, "pw-user")
        XCTAssertEqual(store.currentUser?.name, "Password User")
        XCTAssertEqual(try Keychain.get(account: "pw-user"), "pw-token")
        let auth = try XCTUnwrap(recorder.all.first { $0.path == "/jellyfin/Users/AuthenticateByName" })
        XCTAssertEqual(auth.method, "POST")
    }

    // MARK: - Fixtures

    private func makeStore() -> SessionStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return SessionStore(
            sessionConfiguration: configuration,
            quickConnectPollInterval: .milliseconds(1)
        )
    }

    /// Routes the whole sign-in conversation the way a cooperative server
    /// would: system info, the enabled gate, an initiation, approval polls,
    /// and the final exchange. `approvedOnPoll` says which Connect call
    /// answers approved; `expirePolls` answers every poll with the 404 of a
    /// secret the server has dropped.
    private func signInHandler(
        enabled: Bool = true,
        approvedOnPoll: Int = 1,
        expirePolls: Bool = false,
        recorder: RequestRecorder
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            recorder.record(request)
            let path = request.url?.path ?? ""
            switch path {
            case "/jellyfin/System/Info/Public":
                return (
                    try emptyResponse(for: request, statusCode: 200),
                    Data(#"{"Id":"server-id","ServerName":"Test Server"}"#.utf8)
                )
            case "/jellyfin/QuickConnect/Enabled":
                return (try emptyResponse(for: request, statusCode: 200), Data((enabled ? "true" : "false").utf8))
            case "/jellyfin/QuickConnect/Initiate":
                return (
                    try emptyResponse(for: request, statusCode: 200),
                    Data(#"{"Secret":"qc-secret","Code":"123456","Authenticated":false}"#.utf8)
                )
            case "/jellyfin/QuickConnect/Connect":
                if expirePolls {
                    return (try emptyResponse(for: request, statusCode: 404), Data())
                }
                let poll = recorder.count(forPath: "/jellyfin/QuickConnect/Connect")
                let approved = poll >= approvedOnPoll
                return (
                    try emptyResponse(for: request, statusCode: 200),
                    Data(#"{"Authenticated":\#(approved),"Secret":"qc-secret"}"#.utf8)
                )
            case "/jellyfin/Users/AuthenticateWithQuickConnect":
                return (
                    try emptyResponse(for: request, statusCode: 200),
                    Data(#"{"AccessToken":"qc-token","User":{"Id":"qc-user","Name":"QC User"}}"#.utf8)
                )
            case "/jellyfin/Users/AuthenticateByName":
                return (
                    try emptyResponse(for: request, statusCode: 200),
                    Data(#"{"AccessToken":"pw-token","User":{"Id":"pw-user","Name":"Password User"}}"#.utf8)
                )
            case "/jellyfin/Sessions/Logout":
                return (try emptyResponse(for: request, statusCode: 204), Data())
            default:
                XCTFail("Unexpected request in the sign-in flow: \(path)")
                return (try emptyResponse(for: request, statusCode: 500), Data())
            }
        }
    }
}
