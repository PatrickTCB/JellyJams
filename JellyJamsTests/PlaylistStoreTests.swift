import Foundation
import XCTest
@testable import JellyJams

@MainActor
final class PlaylistStoreTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        URLProtocolStub.responseDelay = nil
        super.tearDown()
    }

    func testConfiguringASessionLoadsPlaylists() async throws {
        stubPlaylists(["party", "chill"])
        let store = PlaylistStore()

        store.configure(client: TestFixtures.stubbedClient())
        try await waitForLoad(store)

        XCTAssertEqual(store.playlists.compactMap(\.id), ["party", "chill"])
        XCTAssertNil(store.errorMessage)
    }

    /// A user with no playlists yet must not re-request on every grid cell that
    /// scrolls into view: an empty result is still a completed load.
    func testEmptyResultIsCachedAndNotRefetchedByEveryMenu() async throws {
        let recorder = stubPlaylists([])
        let store = PlaylistStore()

        store.configure(client: TestFixtures.stubbedClient())
        try await waitForLoad(store)
        for _ in 0 ..< 25 { store.refreshIfNeeded() }
        try await waitForLoad(store)

        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertEqual(recorder.count(forPath: "/jellyfin/Items"), 1)
    }

    func testFailedLoadIsNotRetriedByEveryMenu() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 500), Data())
        }
        let store = PlaylistStore()

        store.configure(client: TestFixtures.stubbedClient())
        try await waitForLoad(store)
        for _ in 0 ..< 25 { store.refreshIfNeeded() }
        try await waitForLoad(store)

        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(recorder.count(forPath: "/jellyfin/Items"), 1)
    }

    func testCreatingAPlaylistReloadsTheCache() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            if request.url?.path == "/jellyfin/Playlists" {
                return (try emptyResponse(for: request, statusCode: 200), Data(#"{"Id":"road-trip"}"#.utf8))
            }
            let existing = recorder.count(forPath: "/jellyfin/Items")
            let ids = existing <= 1 ? ["party"] : ["party", "road-trip"]
            return (try emptyResponse(for: request, statusCode: 200), playlistsPayload(ids: ids))
        }
        let store = PlaylistStore()
        store.configure(client: TestFixtures.stubbedClient())
        try await waitForLoad(store)
        XCTAssertEqual(store.playlists.compactMap(\.id), ["party"])

        try await store.createPlaylist(named: "Road Trip", itemIds: ["track-1"])
        try await waitForLoad(store)

        XCTAssertEqual(store.playlists.compactMap(\.id), ["party", "road-trip"])
    }

    /// The reload triggered by creating a playlist must supersede a list load
    /// that was already in flight, otherwise the older response lands last and
    /// hides the new playlist until the cache goes stale.
    func testCreatingAPlaylistSupersedesAnInFlightLoad() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.responseDelay = { request in
            request.url?.path == "/jellyfin/Items" ? 0.4 : 0
        }
        URLProtocolStub.handler = { request in
            recorder.record(request)
            if request.url?.path == "/jellyfin/Playlists" {
                return (try emptyResponse(for: request, statusCode: 200), Data(#"{"Id":"road-trip"}"#.utf8))
            }
            let ids = recorder.count(forPath: "/jellyfin/Items") <= 1
                ? ["party"]
                : ["party", "road-trip"]
            return (try emptyResponse(for: request, statusCode: 200), playlistsPayload(ids: ids))
        }
        let store = PlaylistStore()

        store.configure(client: TestFixtures.stubbedClient())
        XCTAssertTrue(store.isLoading, "The initial load should still be in flight")
        try await store.createPlaylist(named: "Road Trip", itemIds: ["track-1"])
        try await waitForLoad(store)

        XCTAssertEqual(store.playlists.compactMap(\.id), ["party", "road-trip"])
        XCTAssertEqual(recorder.count(forPath: "/jellyfin/Items"), 2)
    }

    /// The server creates the playlist before the response can fail to parse,
    /// so a thrown error must still reconcile the cache.
    func testAFailedPlaylistCreationStillReconcilesTheCache() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            if request.url?.path == "/jellyfin/Playlists" {
                return (try emptyResponse(for: request, statusCode: 200), Data("{}".utf8))
            }
            let ids = recorder.count(forPath: "/jellyfin/Items") <= 1
                ? ["party"]
                : ["party", "road-trip"]
            return (try emptyResponse(for: request, statusCode: 200), playlistsPayload(ids: ids))
        }
        let store = PlaylistStore()
        store.configure(client: TestFixtures.stubbedClient())
        try await waitForLoad(store)

        do {
            try await store.createPlaylist(named: "Road Trip", itemIds: ["track-1"])
            XCTFail("A creation response without an identifier should throw")
        } catch JellyfinError.missingItemIdentifier {
            // Expected.
        }
        try await waitForLoad(store)

        XCTAssertEqual(store.playlists.compactMap(\.id), ["party", "road-trip"])
    }

    func testCreatingAPlaylistRejectsABlankName() async throws {        stubPlaylists(["party"])
        let store = PlaylistStore()
        store.configure(client: TestFixtures.stubbedClient())
        try await waitForLoad(store)

        do {
            try await store.createPlaylist(named: "   ", itemIds: ["track-1"])
            XCTFail("A blank playlist name should be rejected")
        } catch JellyfinError.emptyPlaylistName {
            // Expected.
        }
    }

    func testSigningOutClearsCachedPlaylistsWithoutSurfacingACancellation() async throws {
        stubPlaylists(["party"])
        let store = PlaylistStore()
        store.configure(client: TestFixtures.stubbedClient())
        try await waitForLoad(store)

        store.configure(client: nil)

        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    /// A response belonging to a signed-out session must never repopulate the
    /// cache once a new session has taken over.
    func testALoadCancelledBySignOutCannotRepopulateTheCache() async throws {
        stubPlaylists(["party"])
        let store = PlaylistStore()

        store.configure(client: TestFixtures.stubbedClient())
        store.configure(client: nil)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    // MARK: - Helpers

    @discardableResult
    private func stubPlaylists(_ ids: [String]) -> RequestRecorder {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), playlistsPayload(ids: ids))
        }
        return recorder
    }

    private func waitForLoad(_ store: PlaylistStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 400 {
            if !store.isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Playlist load never finished", file: file, line: line)
    }
}
