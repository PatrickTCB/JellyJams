import Foundation
import XCTest
@testable import JellyJams

/// Covers what the "Ban" menus ask before they show themselves — signed in,
/// an address, a registration — and what a send turns into on the wire: one
/// `POST /ban` per item id, built through the same stubbed loader the
/// backend's own tests use.
@MainActor
final class BanStoreTests: XCTestCase {
    override func setUp() {
        URLProtocolStub.handler = nil
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
    }

    private var stubbedConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return configuration
    }

    /// A store pointed at the stubbed backend for a signed-in, registered
    /// account — the state every happy-path test starts from.
    private func configuredStore() -> BanStore {
        let store = BanStore()
        store.configure(
            userID: "user-id",
            address: "https://backend.example.com",
            registered: true,
            deviceInfo: TestFixtures.deviceInfo,
            sessionConfiguration: stubbedConfiguration
        )
        return store
    }

    // MARK: - Gating

    func testABackendAndAnAccountMakeBansOfferable() {
        XCTAssertTrue(configuredStore().canBan)
    }

    /// Every input the menu needs can be missing on its own: nobody signed
    /// in, no address typed yet, or an address that has never registered —
    /// a backend that doesn't know the account refuses bans with a 401, so
    /// the menu stands down rather than offering a guaranteed failure.
    func testAnythingTheBanNeedsMissingTakesTheMenuAway() {
        let store = BanStore()

        store.configure(
            userID: nil,
            address: "https://backend.example.com",
            registered: true,
            deviceInfo: TestFixtures.deviceInfo
        )
        XCTAssertFalse(store.canBan)

        store.configure(
            userID: "user-id",
            address: "",
            registered: true,
            deviceInfo: TestFixtures.deviceInfo
        )
        XCTAssertFalse(store.canBan)

        store.configure(
            userID: "user-id",
            address: "https://backend.example.com",
            registered: false,
            deviceInfo: TestFixtures.deviceInfo
        )
        XCTAssertFalse(store.canBan)
    }

    /// A half-typed address in the settings field must not flip the menus
    /// on: it only counts once it parses. Reconfiguring with a good address
    /// brings them back.
    func testAnUnparsableAddressTakesTheMenuAwayUntilFixed() {
        let store = BanStore()
        store.configure(
            userID: "user-id",
            address: "https://",
            registered: true,
            deviceInfo: TestFixtures.deviceInfo
        )
        XCTAssertFalse(store.canBan)

        store.configure(
            userID: "user-id",
            address: "backend.example.com",
            registered: true,
            deviceInfo: TestFixtures.deviceInfo
        )
        XCTAssertTrue(store.canBan)
    }

    // MARK: - Sending

    /// The endpoint takes one item per request, so a multi-selection is a
    /// batch: one `POST /ban` per id, same user, in order.
    func testBanningSendsOnePostPerItemID() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"Items":{},"Success":true,"AlreadyBanned":false}"#.utf8)
            )
        }

        try await configuredStore().ban(itemIds: ["song-1", "album-2", "artist-3"])

        let requests = recorder.all
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/ban")
            XCTAssertEqual(request.value(for: "userID"), "user-id")
        }
        XCTAssertEqual(requests.map { $0.value(for: "itemID") }, ["song-1", "album-2", "artist-3"])
    }

    /// Reconfiguring with a different address must not keep sending to the
    /// old one — the store is pointed at whatever settings last said.
    func testTheSendFollowsTheAddressTheSettingsLastSaid() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (
                try emptyResponse(for: request, statusCode: 201),
                Data(#"{"Items":{},"Success":true,"AlreadyBanned":false}"#.utf8)
            )
        }

        let store = BanStore()
        store.configure(
            userID: "user-id",
            address: "http://192.168.0.10:8000",
            registered: true,
            deviceInfo: TestFixtures.deviceInfo,
            sessionConfiguration: stubbedConfiguration
        )
        try await store.ban(itemIds: ["song-1"])

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.url?.host, "192.168.0.10")
        XCTAssertEqual(request.url?.port, 8000)
    }

    /// A batch stops at the first refusal and reports it — half a
    /// multi-selection banned with the rest quietly lost is the failure
    /// mode this guards against.
    func testARefusedBanStopsTheBatchAndCarriesTheDetail() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            let statusCode = recorder.all.count == 2 ? 401 : 201
            let body = statusCode == 401
                ? Data(#"{"detail":"User user-id does not seem to exist"}"#.utf8)
                : Data(#"{"Items":{},"Success":true,"AlreadyBanned":false}"#.utf8)
            return (try emptyResponse(for: request, statusCode: statusCode), body)
        }

        do {
            try await configuredStore().ban(itemIds: ["song-1", "song-2", "song-3"])
            XCTFail("Expected a rejection")
        } catch let error as BackendError {
            XCTAssertEqual(error, .rejected(status: 401, detail: "User user-id does not seem to exist"))
        }
        XCTAssertEqual(recorder.all.count, 2)
    }

    /// The menu hides itself when the store cannot ban, so a send from an
    /// unconfigured store is a bug rather than a user path — it must say so
    /// instead of firing at nowhere.
    func testSendingWithoutABackendSaysSo() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 201), Data())
        }

        let store = BanStore()
        do {
            try await store.ban(itemIds: ["song-1"])
            XCTFail("Expected a failure")
        } catch let error as BackendError {
            XCTAssertEqual(error, .notSignedIn)
        }
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testBanningNothingReportsTheMissingIdentifier() async throws {
        do {
            try await configuredStore().ban(itemIds: [])
            XCTFail("Expected a failure")
        } catch let error as JellyfinError {
            XCTAssertEqual(error, .missingItemIdentifier)
        }
    }

    // MARK: - The banned-items list

    /// The bans screen's opener: the backend's grouped DTOs become the
    /// screen's three sections, each in name order (`SortName` where the
    /// server gave one — the payload's artists arrive out of order).
    func testARefreshFillsTheSectionsInOrder() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), bansPayload)
        }

        let store = configuredStore()
        await store.refreshBans()

        XCTAssertEqual(store.bannedArtists.map(\.item.displayName), ["alpha", "Zara"])
        XCTAssertEqual(store.bannedAlbums.map(\.id), ["album-1"])
        XCTAssertEqual(store.bannedSongs.map(\.id), ["song-1"])
        XCTAssertTrue(store.hasBans)
        XCTAssertNil(store.listErrorMessage)
        XCTAssertFalse(store.isLoading)
    }

    /// A refused read keeps whatever the screen is showing — bans that
    /// vanish because the backend had a bad day would undo the user's own
    /// reading of the list — and keeps the backend's words about why.
    func testARefusedRefreshKeepsTheListsAndSaysWhy() async throws {
        var refuse = false
        URLProtocolStub.handler = { request in
            if refuse {
                return (
                    try emptyResponse(for: request, statusCode: 401),
                    Data(#"{"detail":"User user-id does not seem to exist"}"#.utf8)
                )
            }
            return (try emptyResponse(for: request, statusCode: 200), bansPayload)
        }

        let store = configuredStore()
        await store.refreshBans()
        refuse = true
        await store.refreshBans()

        XCTAssertTrue(store.hasBans)
        XCTAssertNotNil(store.listErrorMessage)
        XCTAssertTrue(store.listErrorMessage?.contains("does not seem to exist") == true)
    }

    /// Unbanning leaves the list immediately — a deleted row should be
    /// gone the moment it is deleted, the way the queue's rows are — while
    /// `DELETE /ban` tells the backend, per id.
    func testUnbanningRemovesTheRowsAndTellsTheBackend() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), bansPayload)
        }

        let store = configuredStore()
        await store.refreshBans()
        await store.unban(itemIds: ["song-1", "artist-2"])

        XCTAssertEqual(store.bannedSongs, [])
        XCTAssertEqual(store.bannedArtists.map(\.id), ["artist-1"])
        let requests = recorder.all.filter { $0.path == "/ban" && $0.method == "DELETE" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.value(for: "itemID") }, ["song-1", "artist-2"])
    }

    /// A refused unban puts the rows back: they are still banned on the
    /// server whatever the screen guessed, and leaving a swiped-away row
    /// gone would be the lie.
    func testARefusedUnbanPutsTheRowsBack() async throws {
        var refuse = false
        URLProtocolStub.handler = { request in
            if refuse, request.url?.path == "/ban" {
                return (
                    try emptyResponse(for: request, statusCode: 401),
                    Data(#"{"detail":"User user-id does not seem to exist"}"#.utf8)
                )
            }
            return (try emptyResponse(for: request, statusCode: 200), bansPayload)
        }

        let store = configuredStore()
        await store.refreshBans()
        let before = store.bannedSongs
        refuse = true
        await store.unban(itemIds: ["song-1"])

        XCTAssertEqual(store.bannedSongs, before)
        XCTAssertNotNil(store.listErrorMessage)
    }

    /// Reset empties everything in one sweep and asks the backend for the
    /// one call that does the same.
    func testResetEmptiesTheListsAndDeletesAtTheBackend() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            // The read answers the full list; only the reset's own answer
            // is the emptied one.
            let body = request.url?.path == "/reset-bans"
                ? Data(#"{"Items":{},"Success":true,"AlreadyBanned":false}"#.utf8)
                : bansPayload
            return (try emptyResponse(for: request, statusCode: 201), body)
        }

        let store = configuredStore()
        await store.refreshBans()
        await store.resetBans()

        XCTAssertFalse(store.hasBans)
        XCTAssertNil(store.listErrorMessage)
        let request = recorder.all.first { $0.path == "/reset-bans" }
        XCTAssertEqual(request?.method, "DELETE")
        XCTAssertEqual(request?.value(for: "userID"), "user-id")
    }

    /// A refused reset puts the whole set back — the server kept every ban,
    /// so the screen keeps showing every ban.
    func testARefusedResetPutsTheBansBack() async throws {
        var refuse = false
        URLProtocolStub.handler = { request in
            if refuse, request.url?.path == "/reset-bans" {
                return (
                    try emptyResponse(for: request, statusCode: 401),
                    Data(#"{"detail":"User user-id does not seem to exist"}"#.utf8)
                )
            }
            return (try emptyResponse(for: request, statusCode: 201), bansPayload)
        }

        let store = configuredStore()
        await store.refreshBans()
        refuse = true
        await store.resetBans()

        XCTAssertTrue(store.hasBans)
        XCTAssertNotNil(store.listErrorMessage)
    }

    /// Another account is another set of bans. Signing in somewhere else
    /// must not let the old list answer for the new one; the same
    /// account's address being edited keeps it.
    func testSwitchingAccountsDropsThePreviousBans() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), bansPayload)
        }

        let store = configuredStore()
        await store.refreshBans()
        XCTAssertTrue(store.hasBans)

        store.configure(
            userID: "other-user",
            address: "https://backend.example.com",
            registered: true,
            deviceInfo: TestFixtures.deviceInfo,
            sessionConfiguration: stubbedConfiguration
        )
        XCTAssertFalse(store.hasBans)
        XCTAssertTrue(store.canBan)
    }

    /// List writes from an unconfigured store say so rather than reaching
    /// at nothing.
    func testListWritesFromAnUnconfiguredStoreSaySo() async throws {
        let store = BanStore()
        await store.unban(itemIds: ["song-1"])
        XCTAssertEqual(store.listErrorMessage, BackendError.notSignedIn.errorDescription)

        await store.resetBans()
        XCTAssertEqual(store.listErrorMessage, BackendError.notSignedIn.errorDescription)
    }
}

/// How a banned item names itself on the bans screen, and where opening it
/// leads — the row's whole contract, spelled on the shape of a song off an
/// album by two artists: `"Ban Me Too" by "Bad Artist" on "Bad Songs"`.
@MainActor
final class BannedItemPresentationTests: XCTestCase {
    private func song() -> BannedItem {
        BannedItem(kind: .song, item: BaseItemDto(
            album: "Bad Songs",
            albumID: "album-1",
            artistItems: [
                NameIDPair(id: "artist-1", name: "Bad Artist"),
                NameIDPair(id: "artist-2", name: "Worse Artist"),
            ],
            id: "song-1",
            name: "Ban Me Too",
            type: .audio
        ))
    }

    func testTheSongRowNamesTheSongItsArtistAndItsAlbum() {
        XCTAssertEqual(
            song().label,
            "“Ban Me Too” by “Bad Artist, Worse Artist” on “Bad Songs”"
        )
    }

    /// Servers omit; the label drops the clause that has no name to show
    /// rather than leaving a dangling "by" or "on".
    func testTheSongLabelDropsClausesWithoutTheirNames() {
        let noAlbum = BannedItem(kind: .song, item: BaseItemDto(
            artistItems: [NameIDPair(id: "artist-1", name: "Bad Artist")],
            id: "song-1",
            name: "Ban Me",
            type: .audio
        ))
        XCTAssertEqual(noAlbum.label, "“Ban Me” by “Bad Artist”")

        let bare = BannedItem(kind: .song, item: BaseItemDto(id: "song-1", name: "Ban Me", type: .audio))
        XCTAssertEqual(bare.label, "“Ban Me”")
    }

    func testTheAlbumRowCarriesItsArtistAndTheArtistRowJustItself() {
        let album = BannedItem(kind: .album, item: BaseItemDto(
            albumArtist: "Bad Artist",
            id: "album-1",
            name: "Bad Songs",
            type: .musicAlbum
        ))
        XCTAssertEqual(album.label, "Bad Songs by Bad Artist")

        let noArtist = BannedItem(kind: .album, item: BaseItemDto(id: "album-1", name: "Bad Songs", type: .musicAlbum))
        XCTAssertEqual(noArtist.label, "Bad Songs")

        let artist = BannedItem(kind: .artist, item: BaseItemDto(id: "artist-1", name: "Bad Artist", type: .musicArtist))
        XCTAssertEqual(artist.label, "Bad Artist")
    }

    /// Opening means the page the ban belongs to: the artist for an artist,
    /// the album for an album, and the album a banned song was taken from —
    /// a song has no page of its own outside it. No route without the ids
    /// to load the page with.
    func testOpeningLeadsToThePageTheBanBelongsTo() {
        let song = song()
        XCTAssertEqual(song.navigationTarget?.id, "album-1")
        XCTAssertEqual(song.navigationTarget?.itemType, .musicAlbum)

        let album = BannedItem(kind: .album, item: BaseItemDto(id: "album-1", name: "Bad Songs", type: .musicAlbum))
        XCTAssertEqual(album.navigationTarget?.id, "album-1")

        let artist = BannedItem(kind: .artist, item: BaseItemDto(id: "artist-1", name: "Bad Artist", type: .musicArtist))
        XCTAssertEqual(artist.navigationTarget?.id, "artist-1")

        let orphan = BannedItem(kind: .song, item: BaseItemDto(id: "song-1", name: "Ban Me", type: .audio))
        XCTAssertNil(orphan.navigationTarget)
    }

    /// Sections sort by the name Jellyfin sorts by, case-insensitively,
    /// falling back to the display name when the server gave no sort name.
    func testTheSortKeyPrefersTheServerSortName() {
        let sorted = [
            BannedItem(kind: .artist, item: BaseItemDto(id: "2", name: "Zebra", sortName: "apple", type: .musicArtist)),
            BannedItem(kind: .artist, item: BaseItemDto(id: "1", name: "Banana", type: .musicArtist)),
        ].sorted { $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending }
        XCTAssertEqual(sorted.map(\.id), ["2", "1"])
    }
}
