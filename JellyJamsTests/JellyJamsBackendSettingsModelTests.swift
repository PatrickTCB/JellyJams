import Foundation
import XCTest
@testable import JellyJams

/// Covers the pattern every Jelly Jams Backend setting follows: opening the
/// sheet pings the backend, only a 200 lets the settings take input, and an
/// unreachable backend falls back to showing what the app stored last —
/// because "at home on the LAN" is a permanent fact of this service's life.
@MainActor
final class JellyJamsBackendSettingsModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "JellyJamsBackendSettingsModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        URLProtocolStub.handler = nil
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        URLProtocolStub.handler = nil
    }

    /// A backend that lives: pong for `/ping`, the supplied membership
    /// answer for every `/family-blend` method, and the supplied pair for
    /// every `/limits` one.
    private func stubAwakeBackend(
        joined: Bool,
        albumLimit: Int = 3,
        artistLimit: Int = 5
    ) {
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/ping" {
                return (
                    try emptyResponse(for: request, statusCode: 200),
                    Data(#"{"message":"pong","now":1}"#.utf8)
                )
            }
            if path == "/limits" {
                return (
                    try emptyResponse(for: request, statusCode: 201),
                    Data(#"{"id":"user-id","sameAlbumLimit":\#(albumLimit),"sameArtistLimit":\#(artistLimit)}"#.utf8)
                )
            }
            let answer = joined ? "true" : "false"
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"id":"user-id","inFamilyBlend":\#(answer)}"#.utf8)
            )
        }
    }

    // MARK: - Unreachable

    func testAnAbsentAddressLeavesTheSavedStateStandingAndNothingEditable() async {
        let preferences = PreferencesStore(defaults: defaults)
        preferences.familyBlendJoined = true

        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: nil,
            addressText: "",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )

        if case .unreachable = model.connection {} else {
            XCTFail("Expected unreachable, got \(model.connection)")
        }
        XCTAssertTrue(preferences.familyBlendJoined, "The remembered state stands until the backend corrects it")
        XCTAssertFalse(model.canEditFamilyBlend)
    }

    /// No request can be made — the handler is not installed and the stub
    /// fails every load — so the memory must survive untouched.
    func testADeadBackendLeavesTheSavedStateStandingAndNothingEditable() async {
        let preferences = PreferencesStore(defaults: defaults)
        preferences.familyBlendJoined = true

        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: TestFixtures.stubbedBackend(),
            addressText: "https://backend.example.com",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )

        if case .unreachable = model.connection {} else {
            XCTFail("Expected unreachable, got \(model.connection)")
        }
        XCTAssertTrue(preferences.familyBlendJoined)
        XCTAssertFalse(model.canEditFamilyBlend)
    }

    /// A change must not be written to the memory when the backend cannot be
    /// reached to confirm it — even if a caller hands the model a client
    /// out of order, the gate holds.
    func testSetFamilyBlendRefusesWhileUnreachable() async {
        let preferences = PreferencesStore(defaults: defaults)
        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: nil,
            addressText: "",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )

        await model.setFamilyBlend(
            joined: true,
            backend: TestFixtures.stubbedBackend(),
            userID: "user-id",
            preferences: preferences
        )

        XCTAssertFalse(preferences.familyBlendJoined)
    }

    // MARK: - Online

    func testTheAnswerFromTheBackendReplacesTheRememberedState() async {
        stubAwakeBackend(joined: true)
        let preferences = PreferencesStore(defaults: defaults)
        preferences.familyBlendJoined = false

        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: TestFixtures.stubbedBackend(),
            addressText: "https://backend.example.com",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )

        XCTAssertEqual(model.connection, .online)
        XCTAssertTrue(preferences.familyBlendJoined, "The server's answer wins over the app's memory")
        XCTAssertTrue(model.canEditFamilyBlend)
    }

    /// Online is the gate; registered is the *content* behind it. Before a
    /// registration the backend has no account to ask about, so the blend is
    /// not fetched at all and the switch waits for the Save above.
    func testOnlineButUnregisteredAsksNothingAboutTheBlend() async {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 200),
                Data(#"{"message":"pong","now":1}"#.utf8)
            )
        }

        let preferences = PreferencesStore(defaults: defaults)
        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: TestFixtures.stubbedBackend(),
            addressText: "https://backend.example.com",
            userID: "user-id",
            registered: false,
            preferences: preferences
        )

        XCTAssertEqual(model.connection, .needsRegistration)
        XCTAssertFalse(model.canEditFamilyBlend)
        XCTAssertEqual(recorder.count(forPath: "/family-blend"), 0)
        XCTAssertEqual(recorder.count(forPath: "/limits"), 0)
    }

    // MARK: - Writing the membership

    func testJoiningKeepsWhateverTheBackendConfirms() async {
        stubJoinableBackend()
        let preferences = PreferencesStore(defaults: defaults)

        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: TestFixtures.stubbedBackend(),
            addressText: "https://backend.example.com",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )
        await model.setFamilyBlend(
            joined: true,
            backend: TestFixtures.stubbedBackend(),
            userID: "user-id",
            preferences: preferences
        )

        XCTAssertTrue(preferences.familyBlendJoined)
        XCTAssertNil(model.familyBlendError)
        XCTAssertFalse(model.isApplyingFamilyBlendChange)
    }

    func testLeavingKeepsWhateverTheBackendConfirms() async {
        // Starts from membership, so the DELETE is the thing that changes it.
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/ping" {
                return (try emptyResponse(for: request, statusCode: 200), Data(#"{"message":"pong","now":1}"#.utf8))
            }
            if path == "/limits" {
                return (
                    try emptyResponse(for: request, statusCode: 201),
                    Data(#"{"id":"user-id","sameAlbumLimit":3,"sameArtistLimit":5}"#.utf8)
                )
            }
            switch request.httpMethod {
            case "DELETE":
                return (
                    try emptyResponse(for: request, statusCode: 200),
                    Data(#"{"id":"user-id","inFamilyBlend":false}"#.utf8)
                )
            default:
                return (
                    try emptyResponse(for: request, statusCode: 201),
                    Data(#"{"id":"user-id","inFamilyBlend":true}"#.utf8)
                )
            }
        }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.familyBlendJoined = false

        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: TestFixtures.stubbedBackend(),
            addressText: "https://backend.example.com",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )
        XCTAssertTrue(preferences.familyBlendJoined, "The refresh synced the membership the backend reports")

        await model.setFamilyBlend(
            joined: false,
            backend: TestFixtures.stubbedBackend(),
            userID: "user-id",
            preferences: preferences
        )

        XCTAssertFalse(preferences.familyBlendJoined)
        XCTAssertNil(model.familyBlendError)
    }

    /// The optimistic write the switch shows must be withdrawn when the
    /// backend refuses, and its reason shown — a toggle that lies about the
    /// server's state is worse than one stuck at the old value.
    func testADeniedJoinRevertsTheSwitchAndReportsWhy() async {
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/ping" {
                return (try emptyResponse(for: request, statusCode: 200), Data(#"{"message":"pong","now":1}"#.utf8))
            }
            if request.httpMethod == "POST" {
                return (
                    try emptyResponse(for: request, statusCode: 401),
                    Data(#"{"detail":"User user-id does not seem to exist"}"#.utf8)
                )
            }
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"id":"user-id","inFamilyBlend":false}"#.utf8)
            )
        }

        let preferences = PreferencesStore(defaults: defaults)
        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: TestFixtures.stubbedBackend(),
            addressText: "https://backend.example.com",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )
        await model.setFamilyBlend(
            joined: true,
            backend: TestFixtures.stubbedBackend(),
            userID: "user-id",
            preferences: preferences
        )

        XCTAssertFalse(preferences.familyBlendJoined, "The refused join is taken back off the switch")
        XCTAssertNotNil(model.familyBlendError)
        XCTAssertTrue(model.familyBlendError?.contains("does not seem to exist") == true)
    }

    // MARK: - Mixtape limits

    /// The limits join the ritual the sheet runs when it opens: while the
    /// backend is speaking it is asked for its pair, and what it answers
    /// replaces what the app remembered.
    func testTheAnswerFromTheBackendReplacesTheRememberedLimits() async {
        stubAwakeBackend(joined: false, albumLimit: 7, artistLimit: 2)
        let preferences = PreferencesStore(defaults: defaults)
        preferences.sameAlbumLimit = 3
        preferences.sameArtistLimit = 5

        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: TestFixtures.stubbedBackend(),
            addressText: "https://backend.example.com",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )

        XCTAssertEqual(model.connection, .online)
        XCTAssertEqual(preferences.sameAlbumLimit, 7, "The server's answer wins over the app's memory")
        XCTAssertEqual(preferences.sameArtistLimit, 2)
        XCTAssertTrue(model.canEditLimits)
        XCTAssertNil(model.limitsError)
    }

    /// The pair is one setting: Save sends both numbers — the touched one
    /// and the one that rode along — and the answer the backend echoes
    /// back is what the memory keeps, draft notwithstanding.
    func testSavingLimitsSendsTheWholePairAndKeepsTheAnswer() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            let path = request.url?.path ?? ""
            if path == "/ping" {
                return (try emptyResponse(for: request, statusCode: 200), Data(#"{"message":"pong","now":1}"#.utf8))
            }
            if path == "/family-blend" {
                return (
                    try emptyResponse(for: request, statusCode: 201),
                    Data(#"{"id":"user-id","inFamilyBlend":false}"#.utf8)
                )
            }
            if request.httpMethod == "POST" {
                return (
                    try emptyResponse(for: request, statusCode: 201),
                    Data(#"{"id":"user-id","sameAlbumLimit":4,"sameArtistLimit":6}"#.utf8)
                )
            }
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"id":"user-id","sameAlbumLimit":3,"sameArtistLimit":5}"#.utf8)
            )
        }

        let preferences = PreferencesStore(defaults: defaults)

        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: TestFixtures.stubbedBackend(),
            addressText: "https://backend.example.com",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )
        XCTAssertEqual(preferences.sameAlbumLimit, 3)

        // The draft the steppers settle writes straight into the memory:
        // (4, 5) — only the album number was touched.
        preferences.sameAlbumLimit = 4
        await model.setLimits(
            backend: TestFixtures.stubbedBackend(),
            userID: "user-id",
            preferences: preferences
        )

        let post = try XCTUnwrap(
            recorder.all.first { $0.method == "POST" && $0.path == "/limits" }
        )
        XCTAssertEqual(post.value(for: "userID"), "user-id")
        XCTAssertEqual(post.value(for: "sameAlbumLimit"), "4")
        XCTAssertEqual(post.value(for: "sameArtistLimit"), "5")
        XCTAssertEqual(preferences.sameAlbumLimit, 4)
        XCTAssertEqual(preferences.sameArtistLimit, 6, "The echoed answer settles over the draft")
        XCTAssertNil(model.limitsError)
        XCTAssertFalse(model.isApplyingLimitsChange)
    }

    /// A refused save keeps the numbers where they can be fixed and
    /// retried — the grace the address field gives a typed value — and
    /// says its reason beside the steppers.
    func testADeniedSaveKeepsTheNumbersAndReportsWhy() async {
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/ping" {
                return (try emptyResponse(for: request, statusCode: 200), Data(#"{"message":"pong","now":1}"#.utf8))
            }
            if path == "/family-blend" {
                return (
                    try emptyResponse(for: request, statusCode: 201),
                    Data(#"{"id":"user-id","inFamilyBlend":false}"#.utf8)
                )
            }
            if request.httpMethod == "POST" {
                return (
                    try emptyResponse(for: request, statusCode: 401),
                    Data(#"{"detail":"User user-id not valid"}"#.utf8)
                )
            }
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"id":"user-id","sameAlbumLimit":3,"sameArtistLimit":5}"#.utf8)
            )
        }

        let preferences = PreferencesStore(defaults: defaults)

        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: TestFixtures.stubbedBackend(),
            addressText: "https://backend.example.com",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )

        preferences.sameArtistLimit = 8
        await model.setLimits(
            backend: TestFixtures.stubbedBackend(),
            userID: "user-id",
            preferences: preferences
        )

        XCTAssertEqual(preferences.sameArtistLimit, 8, "The refused draft stays where it can be fixed")
        XCTAssertEqual(preferences.sameAlbumLimit, 3)
        XCTAssertNotNil(model.limitsError)
        XCTAssertTrue(model.limitsError?.contains("not valid") == true)
    }

    /// Offline is offline: the remembered numbers stand, and the gate
    /// refuses the write whatever client a caller hands over.
    func testSetLimitsRefusesWhileUnreachable() async {
        let preferences = PreferencesStore(defaults: defaults)
        preferences.sameAlbumLimit = 9

        let model = JellyJamsBackendSettingsModel()
        await model.refresh(
            backend: nil,
            addressText: "",
            userID: "user-id",
            registered: true,
            preferences: preferences
        )

        await model.setLimits(
            backend: TestFixtures.stubbedBackend(),
            userID: "user-id",
            preferences: preferences
        )

        XCTAssertEqual(preferences.sameAlbumLimit, 9, "The remembered numbers stand until the backend corrects them")
        XCTAssertEqual(preferences.sameArtistLimit, 5)
        XCTAssertFalse(model.canEditLimits)
    }

    /// A ping that answers, a `/family-blend` that answers by method: POST
    /// says the account is in, DELETE says it is out, reads say not yet.
    private func stubJoinableBackend() {
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/ping" {
                return (try emptyResponse(for: request, statusCode: 200), Data(#"{"message":"pong","now":1}"#.utf8))
            }
            if path == "/limits" {
                return (
                    try emptyResponse(for: request, statusCode: 201),
                    Data(#"{"id":"user-id","sameAlbumLimit":3,"sameArtistLimit":5}"#.utf8)
                )
            }
            switch request.httpMethod {
            case "POST":
                return (
                    try emptyResponse(for: request, statusCode: 201),
                    Data(#"{"id":"user-id","inFamilyBlend":true}"#.utf8)
                )
            default:
                return (
                    try emptyResponse(for: request, statusCode: 200),
                    Data(#"{"id":"user-id","inFamilyBlend":false}"#.utf8)
                )
            }
        }
    }
}
