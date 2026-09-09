import Foundation
import XCTest
@testable import JellyJams

@MainActor
final class DownloadStoreTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    private func makeStore() throws -> DownloadStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DownloadStoreTests-\(UUID().uuidString)")
        return DownloadStore(directory: directory, session: try stubbedSession())
    }

    private func stubbedSession() throws -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    /// Serves track listings for collections and file bytes for streams: a
    /// request for `/Items` returns the ids the collection maps to; anything
    /// else is audio data.
    private func stubCollections(_ collections: [String: [String]]) {
        URLProtocolStub.handler = { request in
            let response = try emptyResponse(for: request, statusCode: 200)
            if let url = request.url, url.path.contains("/Items") {
                let tracks = collections.values.flatMap { $0 }
                return (response, itemsPayload(tracks.map { ($0, "Audio") }))
            }
            return (response, Data("audio".utf8))
        }
    }

    private func waitForBatch(_ store: DownloadStore, id: String) async throws {
        for _ in 0 ..< 500 {
            if !store.batches.contains(where: { $0.id == id }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Download batch never finished")
    }

    func testDownloadingASongSavesTheFileReferencingItself() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data("audio-a".utf8))
        }
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = TestFixtures.item(id: "a")

        store.download(track)
        try await waitForBatch(store, id: "a")

        XCTAssertTrue(store.isDownloaded(track))
        XCTAssertNotNil(store.localURL(forItemId: "a"))
        XCTAssertEqual(store.downloadedSongs().map(\.id), ["a"])
        XCTAssertEqual(store.tracks(forItemId: "a").map(\.id), ["a"])
    }

    func testOverlappingCollectionsDoNotDuplicateFiles() async throws {
        stubCollections(["album": ["t1", "t2"], "playlist": ["t1"]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let album = albumItem(id: "album", tracks: ["t1", "t2"])
        let playlist = playlistItem(id: "playlist", tracks: ["t1"])

        store.download(album)
        try await waitForBatch(store, id: "album")
        store.download(playlist)
        try await waitForBatch(store, id: "playlist")

        // The playlist's overlap with the album only gained a reference.
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries["t1"]?.requiredBy, ["album", "playlist"])
        XCTAssertEqual(store.entries["t2"]?.requiredBy, ["album"])
        XCTAssertFalse(store.batches.contains { $0.failed > 0 })
    }

    /// The core reference-counting promise: deleting the album leaves the
    /// playlist's files alone, and a second deletion actually removes them.
    func testRemovingACollectionKeepsTracksAnotherStillRequires() async throws {
        stubCollections(["album": ["t1", "t2"], "playlist": ["t1"]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let album = albumItem(id: "album", tracks: ["t1", "t2"])
        let playlist = playlistItem(id: "playlist", tracks: ["t1"])
        store.download(album)
        try await waitForBatch(store, id: "album")
        store.download(playlist)
        try await waitForBatch(store, id: "playlist")

        store.remove(album)

        XCTAssertEqual(store.entries["t1"]?.requiredBy, ["playlist"])
        XCTAssertNil(store.entries["t2"], "t2 was album-only and must be deleted")
        XCTAssertNil(store.localURL(forItemId: "t2"))
        XCTAssertNotNil(store.localURL(forItemId: "t1"))

        store.remove(playlist)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.localURL(forItemId: "t1"))
        XCTAssertFalse(store.isDownloaded(TestFixtures.item(id: "t1")))
    }

    func testRemovingASongOnlyUnreferencesItself() async throws {
        stubCollections(["album": ["t1"]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let album = albumItem(id: "album", tracks: ["t1"])
        store.download(album)
        try await waitForBatch(store, id: "album")
        let song = TestFixtures.item(id: "t1")
        store.download(song)
        try await waitForBatch(store, id: "t1")

        store.remove(song)

        XCTAssertEqual(store.entries["t1"]?.requiredBy, ["album"], "The album still requires the file")
        XCTAssertNotNil(store.localURL(forItemId: "t1"))
    }

    func testDownloadedCollectionsAreGroupedByType() async throws {
        stubCollections(["album": ["t1"]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumItem(id: "album", tracks: ["t1"]))
        try await waitForBatch(store, id: "album")
        store.download(playlistItem(id: "playlist", tracks: ["t1"]))
        try await waitForBatch(store, id: "playlist")
        store.download(TestFixtures.item(id: "t1"))
        try await waitForBatch(store, id: "t1")

        XCTAssertEqual(store.downloadedCollections(ofType: .musicAlbum).map(\.id), ["album"])
        XCTAssertEqual(store.downloadedCollections(ofType: .playlist).map(\.id), ["playlist"])
        XCTAssertEqual(store.downloadedCollections(ofType: .musicArtist).map(\.id), [])
        XCTAssertEqual(store.downloadedSongs().map(\.id), ["t1"])
    }

    func testTheManifestSurvivesRelaunch() async throws {
        stubCollections(["album": ["t1"]])
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DownloadStoreTests-\(UUID().uuidString)")
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumItem(id: "album", tracks: ["t1"]))
        try await waitForBatch(store, id: "album")

        // The manifest write is async; give it a beat before reopening.
        try await Task.sleep(for: .milliseconds(100))
        let reopened = DownloadStore(directory: directory, session: try stubbedSession())

        XCTAssertEqual(reopened.entries["t1"]?.requiredBy, ["album"])
        XCTAssertEqual(reopened.downloadedCollections(ofType: .musicAlbum).map(\.id), ["album"])
        XCTAssertNotNil(reopened.localURL(forItemId: "t1"))
    }

    func testAFailedDownloadReportsAnErrorAndLeavesNothingBehind() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 500), Data())
        }
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = TestFixtures.item(id: "a")

        store.download(track)
        try await waitForBatch(store, id: "a")

        XCTAssertFalse(store.isDownloaded(track))
        XCTAssertNotNil(store.errorMessage)
    }

    func testDownloadingWhileSignedOutReportsInsteadOfFailingSilently() throws {
        let store = try makeStore()

        store.download(TestFixtures.item(id: "a"))

        XCTAssertEqual(store.errorMessage, JellyfinError.notAuthenticated.errorDescription)
    }

    // MARK: - Helpers

    /// A collection whose `tracks(for:)` stub resolves to the given track ids.
    private func albumItem(id: String, tracks: [String]) -> BaseItemDto {
        BaseItemDto(id: id, name: id, type: .musicAlbum)
    }

    private func playlistItem(id: String, tracks: [String]) -> BaseItemDto {
        BaseItemDto(id: id, name: id, type: .playlist)
    }
}