import Foundation
import XCTest
@testable import JellyJams

@MainActor
final class DownloadStoreTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        URLProtocolStub.responseDelay = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A track as a server payload: an id plus the album attribution a real
    /// `/Items` response carries with audio, which is what album and artist
    /// grouping is derived from.
    struct TrackStub {
        let id: String
        var albumID: String?
        var album: String?
        var artistID: String?
        var artist: String?
        var imageTag: String?
        /// The song's own `ImageTags["Primary"]` — what a file with embedded art
        /// carries, and which differs from song to song on the same album.
        var ownTag: String?

        var json: String {
            var fields = [
                "\"Id\":\"\(id)\"",
                "\"Name\":\"\(id)\"",
                "\"Type\":\"Audio\"",
            ]
            if let albumID { fields.append("\"AlbumId\":\"\(albumID)\"") }
            if let album { fields.append("\"Album\":\"\(album)\"") }
            if let artist { fields.append("\"AlbumArtist\":\"\(artist)\"") }
            if let artistID, let artist {
                fields.append("\"AlbumArtists\":[{\"Id\":\"\(artistID)\",\"Name\":\"\(artist)\"}]")
            }
            if let imageTag { fields.append("\"AlbumPrimaryImageTag\":\"\(imageTag)\"") }
            if let ownTag { fields.append("\"ImageTags\":{\"Primary\":\"\(ownTag)\"}") }
            return "{" + fields.joined(separator: ",") + "}"
        }
    }

    /// An album as a server payload, attributed to one artist.
    struct AlbumStub {
        let id: String
        var artistID: String?
        var artist: String?

        var json: String {
            var fields = [
                "\"Id\":\"\(id)\"",
                "\"Name\":\"\(id)\"",
                "\"Type\":\"MusicAlbum\"",
            ]
            if let artist { fields.append("\"AlbumArtist\":\"\(artist)\"") }
            if let artistID, let artist {
                fields.append("\"AlbumArtists\":[{\"Id\":\"\(artistID)\",\"Name\":\"\(artist)\"}]")
            }
            return "{" + fields.joined(separator: ",") + "}"
        }
    }

    private func makeStore() throws -> DownloadStore {
        DownloadStore(directory: newTestDirectory(), session: try stubbedSession())
    }

    /// A fresh temporary directory, for tests that check the files themselves.
    private func newTestDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "DownloadStoreTests-\(UUID().uuidString)")
    }

    private func artworkFiles(in directory: URL) -> [String] {
        let artwork = directory.appending(path: "Artwork")
        return (try? FileManager.default.contentsOfDirectory(atPath: artwork.path)) ?? []
    }

    private func stubbedSession() throws -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    nonisolated private static func itemsData(_ items: [String]) -> Data {
        Data(#"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(items.count),"StartIndex":0}"#.utf8)
    }

    /// Serves the collection lookups the download paths make — an artist's
    /// albums, and each collection's track listing, keyed by the request's
    /// parentId / artistIds / playlist path — and audio or artwork bytes for
    /// everything else.
    private func stubCollections(
        _ collections: [String: [TrackStub]],
        artistAlbums: [String: [AlbumStub]] = [:]
    ) {
        URLProtocolStub.handler = Self.itemsHandler(
            collections: collections,
            artistAlbums: artistAlbums
        )
    }

    /// Nonisolated so the handler closure it builds carries no MainActor
    /// isolation — `startLoading` calls it off the main thread.
    nonisolated private static func itemsHandler(
        collections: [String: [TrackStub]],
        artistAlbums: [String: [AlbumStub]]
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = try emptyResponse(for: request, statusCode: 200)
            guard let url = request.url else { return (response, Data()) }
            let items = RecordedRequest(request)

            // An artist's albums: `/Items?IncludeItemTypes=MusicAlbum&AlbumArtistIds=…`
            if items.values(for: "includeItemTypes").contains("MusicAlbum") {
                let artistId = items.value(for: "albumArtistIds") ?? ""
                return (response, itemsData((artistAlbums[artistId] ?? []).map(\.json)))
            }

            // A playlist's tracks: `/Playlists/{id}/Items`.
            if url.path.contains("/Playlists/") {
                let id = url.path.split(separator: "/")[2].description
                return (response, itemsData((collections[id] ?? []).map(\.json)))
            }

            // A collection's tracks: `/Items?ParentId=…` or `…&ArtistIds=…`.
            if url.path.contains("/Items") {
                let id = items.value(for: "parentId") ?? items.values(for: "artistIds").first ?? ""
                return (response, itemsData((collections[id] ?? []).map(\.json)))
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

    private func albumStub(id: String, artistID: String? = nil, artist: String? = nil) -> BaseItemDto {
        BaseItemDto(
            albumArtist: artist,
            albumArtists: artistID.map { [NameIDPair(id: $0, name: artist ?? $0)] },
            id: id,
            name: id,
            type: .musicAlbum
        )
    }

    /// The track payload for one song of one album, as the server returns it.
    private func trackInAlbum(_ id: String, albumID: String, album: String, artistID: String? = nil, artist: String? = nil, imageTag: String? = nil, ownTag: String? = nil) -> TrackStub {
        TrackStub(id: id, albumID: albumID, album: album, artistID: artistID, artist: artist, imageTag: imageTag, ownTag: ownTag)
    }

    // MARK: - Downloading songs

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
        XCTAssertEqual(store.tracks(for: track).map(\.id), ["a"])
        XCTAssertEqual(store.entries["a"]?.sources, ["a"])
    }

    func testOverlappingCollectionsDoNotDuplicateFiles() async throws {
        stubCollections([
            "album": [trackInAlbum("t1", albumID: "album", album: "Album"), TrackStub(id: "t2")],
            "playlist": [trackInAlbum("t1", albumID: "album", album: "Album")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(albumStub(id: "album", artist: "Artist"))
        try await waitForBatch(store, id: "album")
        store.download(BaseItemDto(id: "playlist", name: "playlist", type: .playlist))
        try await waitForBatch(store, id: "playlist")

        // The playlist's overlap with the album only gained a reference.
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries["t1"]?.sources, ["album", "playlist"])
        XCTAssertEqual(store.entries["t2"]?.sources, ["album"])
        XCTAssertFalse(store.batches.contains { $0.failed > 0 })
    }

    /// Removal deletes the songs the item stands for, whatever else required
    /// them: removing the album takes the playlist's copy of the shared song
    /// too, and the playlist stays listed — incomplete, its record naming a
    /// song with no file — until it is removed or refreshed.
    func testRemovingACollectionDeletesItsSongsWhateverElseRequiredThem() async throws {
        stubCollections([
            "album": [trackInAlbum("t1", albumID: "album", album: "Album"), TrackStub(id: "t2")],
            "playlist": [trackInAlbum("t1", albumID: "album", album: "Album")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let album = albumStub(id: "album", artist: "Artist")
        let playlist = BaseItemDto(id: "playlist", name: "playlist", type: .playlist)
        store.download(album)
        try await waitForBatch(store, id: "album")
        store.download(playlist)
        try await waitForBatch(store, id: "playlist")

        store.remove(album)

        XCTAssertTrue(store.entries.isEmpty, "Both songs went with the album, shared or not")
        XCTAssertNil(store.localURL(forItemId: "t1"))
        XCTAssertNil(store.localURL(forItemId: "t2"))
        XCTAssertEqual(store.playlists["playlist"]?.trackIDs, ["t1"], "The membership record keeps its place")
        XCTAssertTrue(store.isPlaylistIncomplete(playlist))
        XCTAssertEqual(store.downloadedPlaylists().first?.downloadedSongs, 0)

        store.remove(playlist)

        XCTAssertNil(store.playlists["playlist"], "Removing the playlist takes the record with it")
        XCTAssertFalse(store.isDownloaded(playlist))
    }

    /// Deleting a song is deliberate and global: the file goes wherever it
    /// appeared. The playlist's membership keeps naming it — that missing
    /// entry is the incompleteness the offline detail warns about, and the
    /// refresh is what fills it back in.
    func testRemovingASongDeletesItsFileButKeepsThePlaylistMembership() async throws {
        stubCollections([
            "album": [trackInAlbum("t1", albumID: "album", album: "Album")],
            "playlist": [trackInAlbum("t1", albumID: "album", album: "Album")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "album", artist: "Artist"))
        try await waitForBatch(store, id: "album")
        let playlist = BaseItemDto(id: "playlist", name: "playlist", type: .playlist)
        store.download(playlist)
        try await waitForBatch(store, id: "playlist")

        store.remove(TestFixtures.item(id: "t1"))

        XCTAssertNil(store.entries["t1"])
        XCTAssertNil(store.localURL(forItemId: "t1"))
        XCTAssertEqual(store.playlists["playlist"]?.trackIDs, ["t1"], "The record still names the song")
        XCTAssertTrue(store.isPlaylistIncomplete(playlist))
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

    // MARK: - Derived groups

    /// One downloaded song surfaces its album and its artist, even though
    /// neither was downloaded as such — the grouping is derived from the song.
    func testASingleSongSurfacesItsAlbumAndArtist() async throws {
        stubCollections([
            "al1": [trackInAlbum("a1", albumID: "al1", album: "Album One", artistID: "art-1", artist: "Artist")],
            "playlist": [trackInAlbum("a1", albumID: "al1", album: "Album One", artistID: "art-1", artist: "Artist")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        // The song arrives through a playlist, never as an album download.
        store.download(BaseItemDto(id: "playlist", name: "playlist", type: .playlist))
        try await waitForBatch(store, id: "playlist")

        let albums = store.downloadedAlbums()
        XCTAssertEqual(albums.map(\.id), ["al1"])
        XCTAssertEqual(albums.first?.title, "Album One")
        XCTAssertEqual(albums.first?.downloadedSongs, 1)
        XCTAssertNil(albums.first?.totalSongs, "Nothing fetched the album's own track list")
        XCTAssertFalse(albums.first?.isExplicit ?? true, "The album was borrowed from a playlist, not downloaded")
        // An unknown total cannot be claimed complete, which is what lets the
        // Downloads "complete albums only" filter hide this album.
        XCTAssertFalse(albums.first?.isFullyDownloaded ?? true)

        let artists = store.downloadedArtists()
        XCTAssertEqual(artists.map(\.id), ["art-1"])
        XCTAssertEqual(artists.first?.title, "Artist")
        XCTAssertEqual(store.downloadedAlbums(forArtistID: "art-1").map(\.id), ["al1"])

        // A borrowed album is not "downloaded": the toggle still offers to fill it.
        XCTAssertFalse(store.isDownloaded(albumStub(id: "al1", artist: "Artist")))
    }

    /// Downloading an album records how many songs it had, so the derived view
    /// can report a partial album after some of its songs are deleted.
    func testADownloadedAlbumReportsItsServerTotal() async throws {
        stubCollections([
            "al1": [
                trackInAlbum("a1", albumID: "al1", album: "Album One", artistID: "art-1", artist: "Artist"),
                trackInAlbum("a2", albumID: "al1", album: "Album One", artistID: "art-1", artist: "Artist"),
                trackInAlbum("a3", albumID: "al1", album: "Album One", artistID: "art-1", artist: "Artist"),
            ],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")

        XCTAssertEqual(store.downloadedAlbums().first?.downloadedSongs, 3)
        XCTAssertEqual(store.downloadedAlbums().first?.totalSongs, 3)
        XCTAssertTrue(store.downloadedAlbums().first?.isExplicit ?? false)
        XCTAssertTrue(store.downloadedAlbums().first?.isFullyDownloaded ?? false)

        store.remove(TestFixtures.item(id: "a2"))

        XCTAssertEqual(store.downloadedAlbums().first?.downloadedSongs, 2)
        XCTAssertEqual(store.downloadedAlbums().first?.totalSongs, 3)
        XCTAssertFalse(store.downloadedAlbums().first?.isFullyDownloaded ?? true)
    }

    /// Downloading an artist saves each of their albums as a normal album
    /// download; the artist is derived from the songs' attribution and never
    /// stored as its own record.
    func testDownloadingAnArtistDownloadsTheirAlbums() async throws {
        stubCollections(
            [
                "al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "artist", artist: "Artist")],
                "al2": [trackInAlbum("a3", albumID: "al2", album: "Two", artistID: "artist", artist: "Artist")],
            ],
            artistAlbums: ["artist": [AlbumStub(id: "al1", artistID: "artist", artist: "Artist"), AlbumStub(id: "al2", artistID: "artist", artist: "Artist")]]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let artist = TestFixtures.item(id: "artist", type: .musicArtist)

        store.download(artist)
        try await waitForBatch(store, id: "artist")

        XCTAssertEqual(store.downloadedAlbums().map(\.id).sorted(), ["al1", "al2"])
        XCTAssertEqual(store.entries["a1"]?.sources, ["al1"])
        XCTAssertEqual(store.entries["a3"]?.sources, ["al2"])
        XCTAssertEqual(store.downloadedArtists().map(\.id), ["artist"])
        XCTAssertTrue(store.isDownloaded(artist))
        XCTAssertEqual(store.downloadedAlbums(forArtistID: "artist").map(\.id).sorted(), ["al1", "al2"])
        XCTAssertNil(store.playlists["artist"], "An artist is never stored as a record")
    }

    /// An album the server attributed by name only still surfaces its artist.
    func testUnattributedSongSurfacesItsNamedArtist() async throws {
        stubCollections(["al1": [trackInAlbum("a1", albumID: "al1", album: "One", artist: "Named")]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Named"))
        try await waitForBatch(store, id: "al1")

        XCTAssertEqual(store.downloadedArtists().map(\.id), ["Named"])
        XCTAssertEqual(store.downloadedArtists().first?.title, "Named")
    }

    /// Removing an artist deletes their songs, shared or not: the playlist
    /// that also required one stays listed with a hole in its membership, and
    /// the artist — derived from the songs — goes with them.
    func testRemovingAnArtistDeletesTheirSongsAndLeavesAPlaylistIncomplete() async throws {
        stubCollections(
            [
                "al1": [
                    trackInAlbum("a1", albumID: "al1", album: "One", artistID: "artist", artist: "Artist"),
                    trackInAlbum("a2", albumID: "al1", album: "One", artistID: "artist", artist: "Artist"),
                ],
                "al2": [trackInAlbum("a3", albumID: "al2", album: "Two", artistID: "artist", artist: "Artist")],
                "playlist": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "artist", artist: "Artist")],
            ],
            artistAlbums: ["artist": [
                AlbumStub(id: "al1", artistID: "artist", artist: "Artist"),
                AlbumStub(id: "al2", artistID: "artist", artist: "Artist"),
            ]]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let artist = TestFixtures.item(id: "artist", type: .musicArtist)
        store.download(artist)
        try await waitForBatch(store, id: "artist")
        let playlist = BaseItemDto(id: "playlist", name: "playlist", type: .playlist)
        store.download(playlist)
        try await waitForBatch(store, id: "playlist")

        store.remove(artist)

        XCTAssertTrue(store.entries.isEmpty, "Every song of the artist's albums went, shared or not")
        XCTAssertTrue(store.downloadedArtists().isEmpty)
        XCTAssertTrue(store.downloadedAlbums().isEmpty)
        XCTAssertEqual(store.playlists["playlist"]?.trackIDs, ["a1"], "The membership record keeps its place")
        XCTAssertTrue(store.isPlaylistIncomplete(playlist))
        XCTAssertTrue(store.isDownloaded(playlist), "The record is the download; it stays")
    }

    /// The artist list is derived, so removing the last song of an artist's last
    /// album drops the artist.
    func testArtistDisappearsWithTheirLastSong() async throws {
        stubCollections([
            "al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist")],
            "al2": [trackInAlbum("a3", albumID: "al2", album: "Two", artistID: "art-1", artist: "Artist")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")
        store.download(albumStub(id: "al2", artist: "Artist"))
        try await waitForBatch(store, id: "al2")

        store.remove(albumStub(id: "al1", artist: "Artist"))
        XCTAssertEqual(store.downloadedArtists().map(\.id), ["art-1"])

        store.remove(albumStub(id: "al2", artist: "Artist"))
        XCTAssertTrue(store.downloadedArtists().isEmpty)
        XCTAssertTrue(store.downloadedAlbums().isEmpty)
    }

    /// A server that leaves `AlbumId` out of a track payload doesn't break the
    /// derived view: the songs saved with an album inherit its id, so the album
    /// group they surface is the one that was downloaded — toggleable and
    /// removable.
    func testASongWithoutAnAlbumIdInheritsItsAlbumsIdentity() async throws {
        stubCollections(["al1": [TrackStub(id: "a1", artist: "Artist")]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")

        XCTAssertEqual(store.entries["a1"]?.track.albumID, "al1")
        XCTAssertEqual(store.downloadedAlbums().map(\.id), ["al1"])
        XCTAssertTrue(store.downloadedAlbums().first?.isExplicit ?? false)

        store.remove(albumStub(id: "al1", artist: "Artist"))
        XCTAssertTrue(store.entries.isEmpty, "Removing the album removes the song it downloaded")
    }

    // MARK: - Playlists

    /// A downloaded playlist saves its membership and order, which is what makes
    /// it readable with nothing but the songs' metadata.
    func testDownloadedPlaylistSavesItsMembershipInOrder() async throws {
        stubCollections([
            "pl1": [trackInAlbum("b", albumID: "al1", album: "One"), trackInAlbum("a", albumID: "al2", album: "Two")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(BaseItemDto(id: "pl1", name: "My Mix", type: .playlist))
        try await waitForBatch(store, id: "pl1")

        XCTAssertEqual(store.playlists["pl1"]?.trackIDs, ["b", "a"], "Playlist order is the user's, not the server's sort")
        XCTAssertEqual(store.playlists["pl1"]?.title, "My Mix")
        XCTAssertEqual(store.playlists["pl1"]?.totalSongs, 2)
        let group = store.downloadedPlaylists().first
        XCTAssertEqual(group?.downloadedSongs, 2)
        XCTAssertEqual(store.tracks(in: group!).map(\.id), ["b", "a"])
        XCTAssertTrue(store.isDownloaded(BaseItemDto(id: "pl1", name: "My Mix", type: .playlist)))
    }

    /// A playlist that repeats a song lists it once, because the file is stored
    /// once.
    func testDownloadedPlaylistDeduplicatesItsMembership() async throws {
        stubCollections(["pl1": [TrackStub(id: "x"), TrackStub(id: "x"), TrackStub(id: "y")]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(BaseItemDto(id: "pl1", name: "pl1", type: .playlist))
        try await waitForBatch(store, id: "pl1")

        XCTAssertEqual(store.playlists["pl1"]?.trackIDs, ["x", "y"])
        XCTAssertEqual(store.entries.count, 2)
    }

    /// A borrowed album — one that surfaced because its songs arrived through a
    /// playlist — is removable like any other item: its songs go, and the
    /// playlist that brought them keeps its membership and warns it is
    /// incomplete until refreshed.
    func testRemovingABorrowedAlbumLeavesItsPlaylistIncomplete() async throws {
        stubCollections([
            "pl1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let playlist = BaseItemDto(id: "pl1", name: "pl1", type: .playlist)
        store.download(playlist)
        try await waitForBatch(store, id: "pl1")
        let album = try XCTUnwrap(store.downloadedAlbums().first)

        store.remove(album.item)

        XCTAssertNil(store.entries["a1"])
        XCTAssertTrue(store.downloadedAlbums().isEmpty)
        XCTAssertEqual(store.playlists["pl1"]?.trackIDs, ["a1"], "The membership record keeps its place")
        XCTAssertTrue(store.isPlaylistIncomplete(playlist))
    }

    /// Removing a playlist deletes the songs its membership required along
    /// with the record and cover: the membership was the download.
    func testRemovingAPlaylistDeletesItsSongsRecordAndCover() async throws {
        stubCollections(["pl1": [TrackStub(id: "x")]])
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())
        let playlist = BaseItemDto(
            id: "pl1",
            imageTags: ["Primary": "cover-tag"],
            name: "pl1",
            type: .playlist
        )
        store.download(playlist)
        try await waitForBatch(store, id: "pl1")
        XCTAssertNotNil(store.artworkEntries["pl1|cover-tag"])

        store.remove(playlist)

        XCTAssertNil(store.entries["x"])
        XCTAssertNil(store.localURL(forItemId: "x"))
        XCTAssertNil(store.playlists["pl1"])
        XCTAssertNil(store.artworkEntries["pl1|cover-tag"])
        XCTAssertTrue(artworkFiles(in: directory).isEmpty)
        XCTAssertFalse(store.isDownloaded(playlist))
    }

    /// A playlist left incomplete by a removal is made whole again by its
    /// refresh: the membership is re-pulled and the missing song re-downloaded.
    func testRefreshingAPlaylistReDownloadsRemovedSongs() async throws {
        stubCollections([
            "pl1": [trackInAlbum("a1", albumID: "al1", album: "One"), TrackStub(id: "a2")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let playlist = BaseItemDto(id: "pl1", name: "pl1", type: .playlist)
        store.download(playlist)
        try await waitForBatch(store, id: "pl1")

        store.remove(TestFixtures.item(id: "a1"))
        XCTAssertTrue(store.isPlaylistIncomplete(playlist))

        store.refreshPlaylist("pl1")
        try await waitForBatch(store, id: "pl1")

        XCTAssertNotNil(store.entries["a1"])
        XCTAssertEqual(store.tracks(for: playlist).compactMap(\.id).sorted(), ["a1", "a2"])
        XCTAssertFalse(store.isPlaylistIncomplete(playlist))
    }

    func testRemoveAllDeletesEverything() async throws {
        stubCollections([
            "album": [trackInAlbum("t1", albumID: "album", album: "Album")],
            "pl": [TrackStub(id: "t1")],
        ])
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "album", artist: "Artist"))
        try await waitForBatch(store, id: "album")
        store.download(BaseItemDto(id: "pl", name: "pl", type: .playlist))
        try await waitForBatch(store, id: "pl")
        store.download(TestFixtures.item(id: "song", type: .audio))
        try await waitForBatch(store, id: "song")

        store.removeAll()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertTrue(store.artworkEntries.isEmpty)
        XCTAssertNil(store.localURL(forItemId: "t1"))
        XCTAssertNil(store.localURL(forItemId: "song"))
        let reopened = DownloadStore(directory: directory, session: try stubbedSession())
        XCTAssertTrue(reopened.entries.isEmpty, "The empty state persists across relaunch")
    }

    // MARK: - Artwork

    /// Album art is deduplicated per album, and two albums whose images share a
    /// tag keep separate entries and separate files.
    func testArtworkIsKeyedByItsOwningItemAndTag() async throws {
        stubCollections([
            "al1": [trackInAlbum("a1", albumID: "al1", album: "One", imageTag: "shared")],
            "al2": [trackInAlbum("a2", albumID: "al2", album: "Two", imageTag: "shared")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")
        store.download(albumStub(id: "al2", artist: "Artist"))
        try await waitForBatch(store, id: "al2")

        XCTAssertEqual(Set(store.artworkEntries.keys), ["al1|shared", "al2|shared"])
        // A song finds its album's saved cover through its own attribution.
        let storedSong = try XCTUnwrap(store.entries["a1"]?.track)
        XCTAssertNotNil(store.localArtworkURL(for: storedSong))
        // Every song of an album resolves to that album's saved cover.
        let albumGroup = store.downloadedAlbums().first { $0.id == "al1" }
        XCTAssertNotNil(store.localArtworkURL(for: albumGroup!))
    }

    /// A playlist's own cover is saved with it, so its offline header needs no
    /// server.
    func testDownloadedPlaylistSavesItsCover() async throws {
        stubCollections(["pl1": [TrackStub(id: "x")]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(BaseItemDto(
            id: "pl1",
            imageTags: ["Primary": "cover-tag"],
            name: "pl1",
            type: .playlist
        ))
        try await waitForBatch(store, id: "pl1")

        XCTAssertEqual(store.playlists["pl1"]?.coverTag, "cover-tag")
        XCTAssertNotNil(store.artworkEntries["pl1|cover-tag"])
        let group = store.downloadedPlaylists().first
        XCTAssertNotNil(store.localArtworkURL(for: group!))
    }

    /// An artist has no image of its own saved; its row borrows the cover of one
    /// of its downloaded albums rather than asking the server.
    func testArtistArtworkIsBorrowedFromItsDownloadedAlbum() async throws {
        stubCollections([
            "al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover-1")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")

        let artist = try XCTUnwrap(store.downloadedArtists().first)
        XCTAssertEqual(artist.artworkKeys.first, "al1|cover-1")
        XCTAssertNotNil(store.localArtworkURL(for: artist))
    }

    /// Songs carrying their own embedded art — the common case for lossless
    /// files — still share one cover file per album. The album's image pair is
    /// what gets requested, keyed and stored, never a song's own tag.
    func testAlbumArtworkIsSavedOncePerAlbumNotPerSong() async throws {
        stubCollections([
            "al1": [
                trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "album-cover", ownTag: "own-1"),
                trackInAlbum("a2", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "album-cover", ownTag: "own-2"),
                trackInAlbum("a3", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "album-cover", ownTag: "own-3"),
            ],
        ])
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())

        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")

        XCTAssertEqual(store.artworkEntries.keys.sorted(), ["al1|album-cover"])
        XCTAssertEqual(store.artworkEntries["al1|album-cover"]?.requiredBy, ["a1", "a2", "a3"])
        XCTAssertEqual(artworkFiles(in: directory).count, 1, "One file per album, not per song")
    }

    /// The bug this guards: album and artist rows showed a placeholder while the
    /// songs' rows resolved fine, because each cover had been filed under the
    /// song's own image tag rather than the album's. Both views must find the
    /// saved file.
    func testAlbumAndArtistRowsResolveTheirCoverFromDisk() async throws {
        stubCollections([
            "al1": [
                trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "album-cover", ownTag: "own-1"),
                trackInAlbum("a2", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "album-cover", ownTag: "own-2"),
            ],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")

        let album = try XCTUnwrap(store.downloadedAlbums().first { $0.id == "al1" })
        XCTAssertNotNil(store.localArtworkURL(for: album))
        let artist = try XCTUnwrap(store.downloadedArtists().first)
        XCTAssertNotNil(store.localArtworkURL(for: artist))
        for id in ["a1", "a2"] {
            XCTAssertNotNil(store.localArtworkURL(for: store.entries[id]!.track), "Song \(id)")
        }
    }

    /// A v2 manifest saved one file per song, keyed by the album with each song's
    /// own tag. Loading it folds those onto the album's image pair, keeps one
    /// file, deletes the rest, and re-persists — no re-download, so the album and
    /// artist views work on the next launch for installs that already downloaded.
    func testPerTrackArtworkMigratesToTheAlbumPair() throws {
        let directory = newTestDirectory()
        let artwork = directory.appending(path: "Artwork", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        for tag in ["own-1", "own-2", "own-3"] {
            try Data("jpeg".utf8).write(to: artwork.appending(path: "al1-\(tag).jpg"))
        }

        let songs = [("a1", "own-1"), ("a2", "own-2"), ("a3", "own-3")]

        func trackEntryJSON(id: String, ownTag: String, order: Int) -> String {
            let fields = [
                #""Id":"\#(id)""#,
                #""Name":"\#(id)""#,
                #""Type":"Audio""#,
                #""AlbumId":"al1""#,
                #""Album":"One""#,
                #""AlbumArtist":"Artist""#,
                #""AlbumArtists":[{"Id":"art-1","Name":"Artist"}]"#,
                #""AlbumPrimaryImageTag":"album-cover""#,
                #""ImageTags":{"Primary":"\#(ownTag)"}"#,
            ]
            let track = "{" + fields.joined(separator: ",") + "}"
            return #""\#(id)":{"track":\#(track),"filename":"\#(id).flac","order":\#(order),"requiredBy":["al1"]}"#
        }

        func artworkEntryJSON(id: String, ownTag: String) -> String {
            #""al1|\#(ownTag)":{"filename":"al1-\#(ownTag).jpg","ownerItemID":"al1","imageTag":"\#(ownTag)","requiredBy":["\#(id)"]}"#
        }

        let tracks = songs.enumerated()
            .map { trackEntryJSON(id: $0.element.0, ownTag: $0.element.1, order: $0.offset) }
            .joined(separator: ",")
        let entries = songs.map { artworkEntryJSON(id: $0.0, ownTag: $0.1) }.joined(separator: ",")
        let manifest = #"""
        {"version":2,"tracks":{\#(tracks)},"playlists":{},"artwork":{\#(entries)}}
        """#
        try Data(manifest.utf8).write(to: directory.appending(path: "manifest.json"))

        let store = DownloadStore(directory: directory, session: try stubbedSession())

        XCTAssertEqual(store.entries.count, 3, "The migrated manifest still reads its songs")
        XCTAssertEqual(store.artworkEntries.keys.sorted(), ["al1|album-cover"])
        let surviving = try XCTUnwrap(store.artworkEntries["al1|album-cover"])
        XCTAssertEqual(surviving.requiredBy, Set(songs.map(\.0)))
        XCTAssertTrue(artworkFiles(in: directory).contains(surviving.filename), "The first saved cover is kept")
        XCTAssertEqual(artworkFiles(in: directory).count, 1, "The duplicate files are reclaimed")

        // And the rewritten manifest means the next launch needs no migration.
        let rewritten = try String(contentsOf: directory.appending(path: "manifest.json"), encoding: .utf8)
        XCTAssertTrue(rewritten.contains(#""version":3"#))
        XCTAssertTrue(rewritten.contains("al1|album-cover"))
    }

    // MARK: - Persistence

    func testTheManifestSurvivesRelaunch() async throws {
        stubCollections([
            "album": [trackInAlbum("t1", albumID: "album", album: "Album", artistID: "art-1", artist: "Artist")],
            "pl1": [trackInAlbum("t1", albumID: "album", album: "Album", artistID: "art-1", artist: "Artist")],
        ])
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "album", artist: "Artist"))
        try await waitForBatch(store, id: "album")
        store.download(BaseItemDto(id: "pl1", name: "Mix", type: .playlist))
        try await waitForBatch(store, id: "pl1")

        // The manifest write is async; give it a beat before reopening.
        try await Task.sleep(for: .milliseconds(100))
        let reopened = DownloadStore(directory: directory, session: try stubbedSession())

        XCTAssertEqual(reopened.entries["t1"]?.sources, ["album", "pl1"])
        XCTAssertEqual(reopened.downloadedAlbums().map(\.id), ["album"])
        XCTAssertEqual(reopened.downloadedAlbums().first?.title, "Album")
        XCTAssertEqual(reopened.downloadedArtists().map(\.id), ["art-1"])
        XCTAssertEqual(reopened.playlists["pl1"]?.trackIDs, ["t1"])
        XCTAssertNotNil(reopened.localURL(forItemId: "t1"))
    }

    /// An installed v1 manifest — collection snapshots, `requiredBy`, artwork
    /// keyed by bare tag — still opens: playlists become membership records,
    /// albums and artists derive from the songs, and saved covers keep
    /// resolving without being re-fetched.
    func testAV1ManifestMigratesWithoutReDownloading() throws {
        let directory = newTestDirectory()
        let artworkDirectory = directory.appending(path: "Artwork", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appending(path: "t1.mp3"))
        try Data("jpeg".utf8).write(to: artworkDirectory.appending(path: "legacy-tag.jpg"))

        let legacy = """
        {
          "tracks": {
            "t1": {
              "track": {"Id":"t1","Name":"t1","Type":"Audio","AlbumId":"al1","Album":"Old Album","AlbumArtist":"Old Artist","AlbumPrimaryImageTag":"legacy-tag"},
              "filename": "t1.mp3",
              "order": 0,
              "requiredBy": ["al1", "pl1"]
            }
          },
          "collections": {
            "al1": {"Id":"al1","Name":"Old Album","Type":"MusicAlbum"},
            "pl1": {"Id":"pl1","Name":"Old Mix","Type":"Playlist","ChildCount":1,"ImageTags":{"Primary":"cover-legacy"}}
          },
          "artwork": {
            "legacy-tag": {"filename":"legacy-tag.jpg","imageTag":"legacy-tag","requiredBy":["t1"]}
          }
        }
        """
        try Data(legacy.utf8).write(to: directory.appending(path: "manifest.json"))

        let store = DownloadStore(directory: directory, session: try stubbedSession())

        XCTAssertEqual(store.entries["t1"]?.sources, ["al1", "pl1"], "requiredBy carries over as sources")
        XCTAssertEqual(store.downloadedAlbums().map(\.id), ["al1"], "The album derives from the song")
        XCTAssertEqual(store.downloadedAlbums().first?.title, "Old Album")
        XCTAssertEqual(store.downloadedArtists().map(\.id), ["Old Artist"])
        XCTAssertEqual(store.playlists["pl1"]?.title, "Old Mix")
        XCTAssertEqual(store.playlists["pl1"]?.trackIDs, ["t1"], "Membership comes from the files that required it")
        XCTAssertEqual(store.playlists["pl1"]?.coverTag, "cover-legacy")
        let migratedSong = try XCTUnwrap(store.entries["t1"]?.track)
        XCTAssertNotNil(store.localArtworkURL(for: migratedSong), "A tag-only artwork entry still resolves")
    }

    // MARK: - Download progress

    /// The bar's counts: present from the moment a download starts, and gone
    /// once it finishes.
    func testActiveProgressReportsWhileABatchRunsAndDisappearsAfter() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data("audio-a".utf8))
        }
        URLProtocolStub.responseDelay = { _ in 0.2 }
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(TestFixtures.item(id: "a"))

        var seen: DownloadStore.DownloadProgress?
        for _ in 0 ..< 200 {
            if let progress = store.activeDownloadProgress { seen = progress; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(seen?.total, 1, "The batch expects its one song")
        XCTAssertEqual(seen?.completed, 0, "The song has not resolved yet")
        XCTAssertEqual(seen?.fraction, 0)

        try await waitForBatch(store, id: "a")
        XCTAssertNil(store.activeDownloadProgress)
    }

    /// With more than one download running the counts aggregate.
    func testActiveProgressAggregatesAcrossBatches() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data("audio".utf8))
        }
        URLProtocolStub.responseDelay = { _ in 0.2 }
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(TestFixtures.item(id: "a"))
        store.download(TestFixtures.item(id: "b"))

        var seen: DownloadStore.DownloadProgress?
        for _ in 0 ..< 200 {
            if let progress = store.activeDownloadProgress, progress.total == 2 { seen = progress; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(seen?.total, 2, "Both batches' songs are expected")

        try await waitForBatch(store, id: "a")
        try await waitForBatch(store, id: "b")
        XCTAssertNil(store.activeDownloadProgress)
    }

    /// A failed song still counts as resolved, so the bar keeps filling past
    /// failures instead of stalling short of the end.
    func testActiveProgressCountsFailuresAsResolved() async throws {
        // The first song of the playlist fails; the second is slow, so the
        // batch is observably mid-flight with one song resolved.
        URLProtocolStub.handler = { request in
            guard let url = request.url else {
                return (try emptyResponse(for: request, statusCode: 200), Data("audio".utf8))
            }
            if url.path.contains("/Playlists/") {
                return (try emptyResponse(for: request, statusCode: 200), Self.itemsData([
                    TrackStub(id: "a1").json, TrackStub(id: "a2").json
                ]))
            }
            if url.path.contains("a1") {
                return (try emptyResponse(for: request, statusCode: 500), Data())
            }
            return (try emptyResponse(for: request, statusCode: 200), Data("audio".utf8))
        }
        URLProtocolStub.responseDelay = { request in
            request.url?.path.contains("a2") == true ? 0.3 : 0
        }
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(BaseItemDto(id: "pl1", name: "pl1", type: .playlist))

        var seen: DownloadStore.DownloadProgress?
        for _ in 0 ..< 200 {
            if let progress = store.activeDownloadProgress, progress.completed == 1, progress.total == 2 {
                seen = progress
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(seen?.completed, 1, "The failed song resolved, unsuccessfully")
        XCTAssertEqual(seen?.fraction, 0.5)

        try await waitForBatch(store, id: "pl1")
        XCTAssertNil(store.activeDownloadProgress)
    }

    // MARK: - Download speed

    func testTheSpeedTrackerAveragesBytesOverItsWindow() {
        let tracker = DownloadSpeedTracker(window: 10)
        let start = Date(timeIntervalSince1970: 1_000)

        tracker.record(bytes: 300, at: start)
        tracker.record(bytes: 300, at: start.addingTimeInterval(3))

        // 600 bytes over the 3 seconds since the first sample landed.
        XCTAssertEqual(tracker.bytesPerSecond(asOf: start.addingTimeInterval(3)) ?? 0, 200, accuracy: 0.01)
    }

    func testSpeedSamplesFallOutOfTheWindow() {
        let tracker = DownloadSpeedTracker(window: 10)
        let start = Date(timeIntervalSince1970: 1_000)

        tracker.record(bytes: 100, at: start)
        XCTAssertNil(tracker.bytesPerSecond(asOf: start.addingTimeInterval(11)), "The sample has aged out")

        // A fresh sample restarts the estimate; the elapsed floor of one
        // second keeps a just-landed chunk from reading as a spike.
        tracker.record(bytes: 50, at: start.addingTimeInterval(11))
        XCTAssertEqual(tracker.bytesPerSecond(asOf: start.addingTimeInterval(11)) ?? 0, 50, accuracy: 0.01)
    }

    /// The wiring the tracker exists for: bytes a download task writes reach
    /// it through the per-task delegate, without the store owning the
    /// session's delegate.
    func testADownloadFeedsTheSpeedTrackerThroughItsTaskDelegate() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data(repeating: 0x61, count: 50_000))
        }
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(TestFixtures.item(id: "a"))
        try await waitForBatch(store, id: "a")

        // The byte counts arrive on the session's queue, after the download
        // call has returned; give them a beat to land.
        for _ in 0 ..< 200 {
            if store.downloadBytesPerSecond() != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The download never reported throughput")
    }

    // MARK: - Browsing issues no requests

    /// The downloads section's promise, enforced on the store: every query a
    /// downloads screen makes resolves from the manifest, with a client
    /// configured and with none, and issues no request either way.
    func testBrowsingDownloadsIssuesNoRequests() async throws {
        stubCollections([
            "album": [
                trackInAlbum("a1", albumID: "album", album: "Album", artistID: "art-1", artist: "Artist", imageTag: "cover"),
                trackInAlbum("a2", albumID: "album", album: "Album", artistID: "art-1", artist: "Artist", imageTag: "cover"),
            ],
            "pl1": [trackInAlbum("a1", albumID: "album", album: "Album", artistID: "art-1", artist: "Artist", imageTag: "cover")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "album", artist: "Artist"))
        try await waitForBatch(store, id: "album")
        store.download(BaseItemDto(id: "pl1", name: "Mix", type: .playlist))
        try await waitForBatch(store, id: "pl1")

        // Nothing but a recorder now: any request the browse path makes is
        // captured and fails.
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            throw URLError(.cannotConnectToHost)
        }

        let albums = store.downloadedAlbums()
        let artists = store.downloadedArtists()
        let playlists = store.downloadedPlaylists()
        let songs = store.downloadedSongs()
        for group in albums + artists + playlists {
            XCTAssertFalse(store.tracks(in: group).isEmpty, "\(group.kind) listing is empty")
            XCTAssertNotNil(store.group(id: group.id, kind: group.kind))
            _ = store.localArtworkURL(for: group)
            _ = store.localArtworkURL(for: group.item)
        }
        for song in songs {
            XCTAssertNotNil(store.localURL(forItemId: song.id ?? ""))
            _ = store.localArtworkURL(for: song)
            _ = store.isDownloaded(song)
        }
        _ = store.downloadedAlbums(forArtistID: artists.first?.id ?? "")

        XCTAssertEqual(recorder.all.map(\.path), [], "Browsing downloads must never reach the network")

        // Signed out, the same reads still answer — offline listening is the point.
        store.configure(client: nil)
        XCTAssertEqual(store.downloadedSongs().count, songs.count)
        XCTAssertEqual(store.downloadedAlbums().count, albums.count)
        XCTAssertEqual(store.downloadedPlaylists().count, playlists.count)
        XCTAssertNotNil(store.localURL(forItemId: "a1"))
    }
}
