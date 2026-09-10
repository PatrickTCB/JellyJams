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

    /// Serves the collections the download paths ask for: an artist's albums
    /// (via `artistAlbums`, artist id → album ids), each collection's track
    /// listing (via `collections`, id → track ids, keyed by the request's
    /// parentId / artistIds / playlist path), and audio bytes for anything
    /// else. `albumArtists` maps an album id to the artist its payload carries.
    private func stubCollections(
        _ collections: [String: [String]],
        artistAlbums: [String: [String]] = [:],
        albumArtists: [String: String] = [:]
    ) {
        URLProtocolStub.handler = Self.itemsHandler(
            collections: collections,
            artistAlbums: artistAlbums,
            albumArtists: albumArtists
        )
    }

    /// Nonisolated so the handler closure it builds carries no MainActor
    /// isolation — `startLoading` calls it off the main thread.
    nonisolated private static func itemsHandler(
        collections: [String: [String]],
        artistAlbums: [String: [String]],
        albumArtists: [String: String]
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = try emptyResponse(for: request, statusCode: 200)
            guard let url = request.url else { return (response, Data()) }
            let items = RecordedRequest(request)

            // An artist's albums: `/Items?includeItemTypes=MusicAlbum&albumArtistIds=…`
            if items.values(for: "includeItemTypes").contains("MusicAlbum") {
                let artistId = items.values(for: "albumArtistIds").first ?? ""
                let albums = (artistAlbums[artistId] ?? []).map { id in
                    (id: id, type: "MusicAlbum", artist: albumArtists[id] ?? artistId)
                }
                return (response, itemsPayload(albums))
            }

            // A playlist's tracks: `/Playlists/{id}/Items`.
            if url.path.contains("/Playlists/") {
                let id = url.path.split(separator: "/")[2].description
                return (response, itemsPayload((collections[id] ?? []).map { ($0, "Audio") }))
            }

            // A collection's tracks: `/Items?parentId=…` or `…&artistIds=…`.
            if url.path.contains("/Items") {
                let id = items.value(for: "parentId")
                    ?? items.values(for: "artistIds").first
                    ?? ""
                return (response, itemsPayload((collections[id] ?? []).map { ($0, "Audio") }))
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
        XCTAssertEqual(store.downloadedSongs().map(\.id), ["t1"])
    }

    /// Downloading an artist saves each of their albums as a normal album
    /// download: album collections, tracks referenced by album, and the
    /// artist derivable from the albums' metadata — never stored itself.
    func testDownloadingAnArtistDownloadsTheirAlbums() async throws {
        stubCollections(
            ["al1": ["a1", "a2"], "al2": ["a3"]],
            artistAlbums: ["artist": ["al1", "al2"]],
            albumArtists: ["al1": "artist", "al2": "artist"]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let artist = TestFixtures.item(id: "artist", type: .musicArtist)

        store.download(artist)
        try await waitForBatch(store, id: "artist")

        XCTAssertEqual(store.downloadedCollections(ofType: .musicAlbum).compactMap(\.id).sorted(), ["al1", "al2"])
        XCTAssertEqual(store.entries["a1"]?.requiredBy, ["al1"])
        XCTAssertEqual(store.entries["a3"]?.requiredBy, ["al2"])
        XCTAssertEqual(store.downloadedArtists().compactMap(\.id), ["artist"])
        XCTAssertTrue(store.isDownloaded(artist))
        XCTAssertEqual(store.downloadedAlbums(forArtistId: "artist").compactMap(\.id).sorted(), ["al1", "al2"])
        XCTAssertNil(store.collections["artist"], "The artist itself is never stored")
    }

    /// The other half of the feature: a manually downloaded album surfaces
    /// its artist in the Artists tab, with no artist download involved.
    func testDownloadingAnAlbumSurfacesItsArtist() async throws {
        stubCollections(["al1": ["a1"]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumItem(id: "al1", tracks: ["a1"], artistId: "art-1"))
        try await waitForBatch(store, id: "al1")

        XCTAssertEqual(store.downloadedArtists().compactMap(\.id), ["art-1"])
        XCTAssertEqual(store.downloadedAlbums(forArtistId: "art-1").compactMap(\.id), ["al1"])
        XCTAssertTrue(store.isDownloaded(TestFixtures.item(id: "art-1", type: .musicArtist)))
    }

    /// An album the server didn't attribute (no `AlbumArtists`) still counts
    /// for its name-only `albumArtist` string.
    func testUnattributedAlbumSurfacesItsNamedArtist() async throws {
        stubCollections(["al1": ["a1"]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let album = BaseItemDto(albumArtist: "Named", id: "al1", name: "al1", type: .musicAlbum)
        store.download(album)
        try await waitForBatch(store, id: "al1")

        XCTAssertEqual(store.downloadedArtists().compactMap(\.id), ["Named"])
    }

    /// Removing an artist cascades through their albums; a playlist that also
    /// required a track keeps its file.
    func testRemovingAnArtistCascadesButRespectsOtherReferences() async throws {
        stubCollections(
            ["al1": ["a1", "a2"], "al2": ["a3"], "playlist": ["a1"]],
            artistAlbums: ["artist": ["al1", "al2"]],
            albumArtists: ["al1": "artist", "al2": "artist"]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(TestFixtures.item(id: "artist", type: .musicArtist))
        try await waitForBatch(store, id: "artist")
        store.download(playlistItem(id: "playlist", tracks: ["a1"]))
        try await waitForBatch(store, id: "playlist")

        store.remove(TestFixtures.item(id: "artist", type: .musicArtist))

        XCTAssertTrue(store.downloadedArtists().isEmpty)
        XCTAssertTrue(store.downloadedCollections(ofType: .musicAlbum).isEmpty)
        XCTAssertEqual(store.entries["a1"]?.requiredBy, ["playlist"], "The playlist still requires its file")
        XCTAssertNil(store.entries["a2"])
        XCTAssertNil(store.entries["a3"])
        XCTAssertNotNil(store.localURL(forItemId: "a1"))
    }

    /// Removing one of an artist's albums drops the artist only once the last
    /// one goes.
    func testArtistDisappearsWithTheirLastAlbum() async throws {
        stubCollections(["al1": ["a1"], "al2": ["a3"]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumItem(id: "al1", tracks: ["a1"], artistId: "art-1"))
        try await waitForBatch(store, id: "al1")
        store.download(albumItem(id: "al2", tracks: ["a3"], artistId: "art-1"))
        try await waitForBatch(store, id: "al2")

        store.remove(albumItem(id: "al1", tracks: ["a1"], artistId: "art-1"))
        XCTAssertEqual(store.downloadedArtists().compactMap(\.id), ["art-1"])

        store.remove(albumItem(id: "al2", tracks: ["a3"]))
        XCTAssertTrue(store.downloadedArtists().isEmpty)
    }

    /// Delete All removes every file, entry and collection, and persists the
    /// empty state.
    func testRemoveAllDeletesEverything() async throws {
        stubCollections(["album": ["t1"]])
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DownloadStoreTests-\(UUID().uuidString)")
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumItem(id: "album", tracks: ["t1"]))
        try await waitForBatch(store, id: "album")
        store.download(TestFixtures.item(id: "song", type: .audio))
        try await waitForBatch(store, id: "song")

        store.removeAll()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertNil(store.localURL(forItemId: "t1"))
        XCTAssertNil(store.localURL(forItemId: "song"))
        let reopened = DownloadStore(directory: directory, session: try stubbedSession())
        XCTAssertTrue(reopened.entries.isEmpty, "The empty state persists across relaunch")
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

    /// An album whose `tracks(for:)` stub resolves to the given track ids, and
    /// whose metadata attributes it to `artistId` — as a server fetch does.
    private func albumItem(id: String, tracks: [String], artistId: String? = nil) -> BaseItemDto {
        BaseItemDto(
            albumArtists: artistId.map { [NameIDPair(id: $0, name: $0)] },
            id: id,
            name: id,
            type: .musicAlbum
        )
    }

    private func playlistItem(id: String, tracks: [String]) -> BaseItemDto {
        BaseItemDto(id: id, name: id, type: .playlist)
    }
}