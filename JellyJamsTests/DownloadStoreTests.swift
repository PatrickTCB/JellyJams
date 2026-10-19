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
        /// The server's `DateCreated`, as an `/Items` payload carries it — what
        /// the Downloads grids' Date Added sort reads off the saved snapshots.
        var dateCreated: String?

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
            if let dateCreated { fields.append("\"DateCreated\":\"\(dateCreated)\"") }
            return "{" + fields.joined(separator: ",") + "}"
        }
    }

    /// An album as a server payload, attributed to one artist.
    struct AlbumStub {
        let id: String
        var artistID: String?
        var artist: String?
        /// The album's display name when it differs from its id — the name a
        /// playlist-borrowed song's album group is titled with.
        var name: String?
        /// The server's `ChildCount`: how many songs the album has.
        var childCount: Int?

        var json: String {
            var fields = [
                "\"Id\":\"\(id)\"",
                "\"Name\":\"\(name ?? id)\"",
                "\"Type\":\"MusicAlbum\"",
            ]
            if let artist { fields.append("\"AlbumArtist\":\"\(artist)\"") }
            if let artistID, let artist {
                fields.append("\"AlbumArtists\":[{\"Id\":\"\(artistID)\",\"Name\":\"\(artist)\"}]")
            }
            if let childCount { fields.append("\"ChildCount\":\(childCount)") }
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
    /// parentId / artistIds / playlist path — the by-ids lookups (the
    /// artist-picture sync's and a playlist download's album attribution
    /// fetch) — and audio or artwork bytes for everything else.
    private func stubCollections(
        _ collections: [String: [TrackStub]],
        artistAlbums: [String: [AlbumStub]] = [:],
        artists: [String: String] = [:],
        albumsById: [String: AlbumStub] = [:]
    ) {
        URLProtocolStub.handler = Self.itemsHandler(
            collections: collections,
            artistAlbums: artistAlbums,
            artists: artists,
            albumsById: albumsById
        )
    }

    /// Nonisolated so the handler closure it builds carries no MainActor
    /// isolation — `startLoading` calls it off the main thread.
    nonisolated private static func itemsHandler(
        collections: [String: [TrackStub]],
        artistAlbums: [String: [AlbumStub]],
        artists: [String: String] = [:],
        albumsById: [String: AlbumStub] = [:]
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = try emptyResponse(for: request, statusCode: 200)
            guard let url = request.url else { return (response, Data()) }
            let items = RecordedRequest(request)

            // By-ids lookups: `/Items?ids=…`, answered from the album stubs for
            // a playlist download's attribution fetch
            // (`…&IncludeItemTypes=MusicAlbum`) or with each artist's payload
            // carrying their image tag for the artist-picture sync.
            let requestedIDs = items.values(for: "ids")
            if !requestedIDs.isEmpty {
                if items.values(for: "includeItemTypes").contains("MusicAlbum") {
                    let found = requestedIDs.compactMap { albumsById[$0]?.json }
                    return (response, itemsData(found))
                }
                let found = requestedIDs.compactMap { id in artists[id].map { tag in
                    #"{"Id":"\#(id)","Name":"\#(id)","Type":"MusicArtist","ImageTags":{"Primary":"\#(tag)"}}"#
                } }
                return (response, itemsData(found))
            }

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

    private func waitForArtistArtworkSync(_ store: DownloadStore) async throws {
        for _ in 0 ..< 500 {
            if !store.isSyncingArtistArtwork { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Artist-artwork sync never finished")
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
    private func trackInAlbum(_ id: String, albumID: String, album: String, artistID: String? = nil, artist: String? = nil, imageTag: String? = nil, ownTag: String? = nil, dateCreated: String? = nil) -> TrackStub {
        TrackStub(id: id, albumID: albumID, album: album, artistID: artistID, artist: artist, imageTag: imageTag, ownTag: ownTag, dateCreated: dateCreated)
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

    func testFileExtensionPicksTheAudioSpellingOfAContainerFamily() {
        XCTAssertEqual(DownloadStore.fileExtension(forContainer: "mov,mp4,m4a,3gp,3g2,mj2"), "m4a")
        XCTAssertEqual(DownloadStore.fileExtension(forContainer: "matroska,webm"), "webm")
        XCTAssertEqual(DownloadStore.fileExtension(forContainer: "FLAC"), "flac")
        XCTAssertEqual(DownloadStore.fileExtension(forContainer: ".mp3"), "mp3")
        XCTAssertEqual(DownloadStore.fileExtension(forContainer: ""), "mp3")
        XCTAssertEqual(DownloadStore.fileExtension(forContainer: nil), "mp3")
    }

    /// The bug this guards: the server reports an Apple Lossless song's
    /// container as ffprobe's whole family — `mov,mp4,m4a,3gp,3g2,mj2` — and
    /// using that verbatim as the file extension made the saved file
    /// unplayable, because `AVURLAsset` refuses an extension it cannot map to
    /// a known format. The family's audio spelling is what gets saved.
    func testAMultiValueContainerIsSavedUnderItsAudioExtension() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data("audio".utf8))
        }
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = BaseItemDto(
            container: "mov,mp4,m4a,3gp,3g2,mj2",
            id: "a",
            name: "a",
            type: .audio
        )

        store.download(track)
        try await waitForBatch(store, id: "a")

        XCTAssertEqual(store.entries["a"]?.filename, "a.m4a")
        XCTAssertEqual(store.localURL(forItemId: "a")?.lastPathComponent, "a.m4a")
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
        XCTAssertNil(albums.first?.totalSongs, "The album lookup served nothing to resolve the total from")
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

    /// The derived album carries the sort keys the Downloads grids' menus
    /// read: each song's Date Added is all the manifest holds, so the album
    /// reports the earliest of them, and the newest song on disk decides the
    /// group's Recently Downloaded place.
    func testDerivedAlbumsCarrySortKeysFromTheirSongs() async throws {
        stubCollections([
            "al1": [
                trackInAlbum("a1", albumID: "al1", album: "Album One", artistID: "art-1", artist: "Artist", dateCreated: "2026-01-02T00:00:00Z"),
                trackInAlbum("a2", albumID: "al1", album: "Album One", artistID: "art-1", artist: "Artist", dateCreated: "2026-01-01T00:00:00Z"),
            ],
            "al2": [
                trackInAlbum("b1", albumID: "al2", album: "Album Two", artistID: "art-1", artist: "Artist", dateCreated: "2026-01-03T00:00:00Z"),
            ],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")
        store.download(albumStub(id: "al2", artist: "Artist"))
        try await waitForBatch(store, id: "al2")

        let albums = store.downloadedAlbums()
        let one = try XCTUnwrap(albums.first { $0.id == "al1" })
        let two = try XCTUnwrap(albums.first { $0.id == "al2" })

        // The album entered the library when its first song did.
        XCTAssertEqual(one.item.dateCreated, Date(timeIntervalSince1970: 1_767_225_600), "Earliest song date wins") // 2026-01-01T00:00:00Z
        XCTAssertEqual(two.item.dateCreated, Date(timeIntervalSince1970: 1_767_398_400)) // 2026-01-03T00:00:00Z
        // Recency: each album is as new as its newest song, and Album Two's
        // arrived after everything of Album One's.
        XCTAssertEqual(one.mostRecentOrder, 2)
        XCTAssertEqual(two.mostRecentOrder, 3)
        let artist = try XCTUnwrap(store.downloadedArtists().first)
        XCTAssertEqual(artist.mostRecentOrder, 3, "An artist is as recent as their newest album")
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

    /// A playlist song whose payload lacks its album's name — a single whose
    /// file carries no album tag, so the server reports the album's identity
    /// but not its title — still surfaces its album under that name: the
    /// download resolves the album items behind its songs and saves each song
    /// with the album's attribution completed, the way an album download does.
    func testPlaylistSongsGainTheirAlbumsNameFromTheAlbumItem() async throws {
        stubCollections(
            ["pl1": [TrackStub(id: "a1", albumID: "al1")]],
            albumsById: ["al1": AlbumStub(id: "al1", name: "Album One")]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(BaseItemDto(id: "pl1", name: "pl1", type: .playlist))
        try await waitForBatch(store, id: "pl1")

        XCTAssertEqual(store.downloadedAlbums().map(\.id), ["al1"])
        XCTAssertEqual(store.downloadedAlbums().first?.title, "Album One")
        XCTAssertEqual(store.entries["a1"]?.track.album, "Album One")
    }

    /// A playlist holding every song of an album reports it complete: the
    /// download learns each album's server-side total from the album item, so
    /// a fully covered album is not stuck "incomplete" — while one the
    /// playlist borrows a song from honestly stays partial.
    func testPlaylistCoveringAWholeAlbumReportsItComplete() async throws {
        stubCollections(
            ["pl1": [
                TrackStub(id: "a1", albumID: "al1", album: "One"),
                TrackStub(id: "a2", albumID: "al1", album: "One"),
                TrackStub(id: "b1", albumID: "al2", album: "Two"),
            ]],
            albumsById: [
                "al1": AlbumStub(id: "al1", childCount: 2),
                "al2": AlbumStub(id: "al2", childCount: 5),
            ]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        store.download(BaseItemDto(id: "pl1", name: "pl1", type: .playlist))
        try await waitForBatch(store, id: "pl1")

        let albums = store.downloadedAlbums()
        let one = try XCTUnwrap(albums.first { $0.id == "al1" })
        let two = try XCTUnwrap(albums.first { $0.id == "al2" })
        XCTAssertEqual(one.totalSongs, 2)
        XCTAssertTrue(one.isFullyDownloaded)
        XCTAssertEqual(two.totalSongs, 5)
        XCTAssertFalse(two.isFullyDownloaded, "The playlist borrows one song of five")
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

    /// A song saved from a bare playlist payload — one that landed while the
    /// album lookup failed — is healed by the playlist's refresh: the stored
    /// snapshot gains its album's name and total, without its file being
    /// downloaded again. This is the repair path for albums an older download
    /// left titled by their id and stuck incomplete.
    func testRefreshingAPlaylistRepairsAlbumsSavedWithoutTheirMetadata() async throws {
        stubCollections(
            ["pl1": [TrackStub(id: "a1", albumID: "al1")]],
            albumsById: ["al1": AlbumStub(id: "al1", name: "Album One", childCount: 1)]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        let playlist = BaseItemDto(id: "pl1", name: "pl1", type: .playlist)

        // The album lookup fails on the first pass, so the song is saved with
        // the bare payload the playlist sent.
        let serving = try XCTUnwrap(URLProtocolStub.handler)
        URLProtocolStub.handler = { request in
            let items = RecordedRequest(request)
            if !items.values(for: "ids").isEmpty {
                return (try emptyResponse(for: request, statusCode: 500), Data())
            }
            return try serving(request)
        }
        store.download(playlist)
        try await waitForBatch(store, id: "pl1")

        XCTAssertEqual(store.downloadedAlbums().first?.title, "al1", "The bare payload names no album")
        XCTAssertFalse(store.downloadedAlbums().first?.isFullyDownloaded ?? true)
        let savedOrder = try XCTUnwrap(store.entries["a1"]).order
        let savedFilename = try XCTUnwrap(store.entries["a1"]).filename

        URLProtocolStub.handler = serving
        store.refreshPlaylist("pl1")
        try await waitForBatch(store, id: "pl1")

        let album = try XCTUnwrap(store.downloadedAlbums().first)
        XCTAssertEqual(album.title, "Album One")
        XCTAssertEqual(album.totalSongs, 1)
        XCTAssertTrue(album.isFullyDownloaded)
        XCTAssertEqual(store.entries["a1"]?.track.album, "Album One", "The stored snapshot was healed")
        XCTAssertEqual(store.entries["a1"]?.order, savedOrder, "The file was not re-downloaded")
        XCTAssertEqual(store.entries["a1"]?.filename, savedFilename)
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

    /// An artist surfaced by an album download has no picture of their own
    /// saved; the row borrows the cover of one of the artist's downloaded
    /// albums rather than asking the server. (A picture arrives with an
    /// artist download or the sign-in sync.)
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

    /// A downloaded artist's artwork is *their* picture — the image Jellyfin
    /// holds on the artist item — with the album cover only ever a fallback:
    /// used when the artist has no picture of their own on disk.
    func testArtistArtworkIsTheirOwnPictureWithAnAlbumCoverAsFallback() async throws {
        stubCollections(
            ["al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover-1")]],
            artistAlbums: ["art-1": [AlbumStub(id: "al1", artistID: "art-1", artist: "Artist")]]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        // The artist item as the Library grid passes it: carrying their picture's tag.
        let artist = BaseItemDto(
            id: "art-1",
            imageTags: ["Primary": "artist-image"],
            name: "Artist",
            type: .musicArtist
        )
        store.download(artist)
        try await waitForBatch(store, id: "art-1")

        // The artist's own picture was saved with them, under their own id.
        XCTAssertNotNil(store.artworkEntries["art-1|artist-image"])

        // And it is what the artist group resolves — not an album cover.
        let group = try XCTUnwrap(store.downloadedArtists().first)
        let url = try XCTUnwrap(store.localArtworkURL(for: group))
        XCTAssertEqual(url.lastPathComponent, "art-1-artist-image.jpg")
    }

    /// Artists surfaced by songs alone — downloads saved before artist
    /// pictures came with artist downloads — still gain their picture: the
    /// sign-in sync resolves every downloaded artist missing one and saves
    /// each picture under the artist's own id.
    func testSurfacedArtistsGainTheirPictureAtSignIn() async throws {
        stubCollections(
            ["al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover-1")]],
            artists: ["art-1": "artist-image"]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")

        // Surfaced by the album's songs: no picture of the artist's own yet,
        // so the album cover is what the group resolves.
        XCTAssertNil(store.artworkEntries.values.first { $0.ownerItemID == "art-1" })
        let surfaced = try XCTUnwrap(store.downloadedArtists().first)
        XCTAssertEqual(surfaced.artworkKeys.first, "al1|cover-1")

        await store.syncArtistArtwork()

        // The sync saved the artist's own picture, and it takes priority over
        // the album cover.
        XCTAssertNotNil(store.artworkEntries["art-1|artist-image"])
        let synced = try XCTUnwrap(store.downloadedArtists().first)
        XCTAssertEqual(store.localArtworkURL(for: synced)?.lastPathComponent, "art-1-artist-image.jpg")
    }

    /// The Downloads artist tab's refresh button drives the same pass sign-in
    /// does: the busy flag flips with the press so the button can spin, and
    /// the run ends with the surfaced artist's picture saved under their own
    /// id.
    func testRefreshArtistArtworkRunsTheSyncOnDemand() async throws {
        stubCollections(
            ["al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover-1")]],
            artists: ["art-1": "artist-image"]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")

        // The sign-in pass ran before the album landed, so the surfaced
        // artist still borrows the album cover.
        XCTAssertNil(store.artworkEntries.values.first { $0.ownerItemID == "art-1" })

        store.refreshArtistArtwork()
        XCTAssertTrue(store.isSyncingArtistArtwork, "The flag flips with the press, not when its task starts")
        try await waitForArtistArtworkSync(store)

        XCTAssertFalse(store.isSyncingArtistArtwork)
        XCTAssertNotNil(store.artworkEntries["art-1|artist-image"])
    }

    /// An artist's picture is claimed by the artist's own id, so it outlives
    /// the songs that showed it: removing the artist's albums one by one drops
    /// the group without dropping the picture. The sign-in sync reclaims it —
    /// while keeping the picture of an artist who is still downloaded.
    func testTheSyncPassReclaimsAPictureForAnArtistWhoNoLongerLists() async throws {
        stubCollections(
            ["al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist")]],
            artistAlbums: ["art-1": [AlbumStub(id: "al1", artistID: "art-1", artist: "Artist")]],
            artists: ["art-1": "artist-image"]
        )
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())
        store.download(BaseItemDto(id: "art-1", imageTags: ["Primary": "artist-image"], name: "Artist", type: .musicArtist))
        try await waitForBatch(store, id: "art-1")

        // While the artist is still downloaded, the pass keeps their picture.
        await store.syncArtistArtwork()
        XCTAssertNotNil(store.artworkEntries["art-1|artist-image"])

        // Removing the album directly — rather than the artist — takes the
        // songs, and with them the group, but leaves the picture claimed.
        store.remove(albumStub(id: "al1", artistID: "art-1", artist: "Artist"))
        XCTAssertTrue(store.downloadedArtists().isEmpty)
        XCTAssertNotNil(store.artworkEntries["art-1|artist-image"], "The picture outlived the group")

        await store.syncArtistArtwork()

        XCTAssertNil(store.artworkEntries["art-1|artist-image"])
        XCTAssertTrue(artworkFiles(in: directory).isEmpty)
    }

    /// The reclaim half of the sync pass only takes pictures whose artist is
    /// gone: an album's cover, a playlist's cover and a song's own embedded
    /// art all survive a pass over a fully populated download set.
    func testTheSyncPassKeepsArtworkEverythingStillUses() async throws {
        stubCollections(
            [
                "al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover-1")],
                "pl1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover-1")],
            ],
            artistAlbums: ["art-1": [AlbumStub(id: "al1", artistID: "art-1", artist: "Artist")]],
            artists: ["art-1": "artist-image"]
        )
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(BaseItemDto(id: "art-1", imageTags: ["Primary": "artist-image"], name: "Artist", type: .musicArtist))
        try await waitForBatch(store, id: "art-1")
        store.download(BaseItemDto(id: "pl1", imageTags: ["Primary": "pl-cover"], name: "pl1", type: .playlist))
        try await waitForBatch(store, id: "pl1")
        // A song with no album attribution saves its own embedded art under
        // its own id — self-claimed, like an artist's picture.
        store.download(BaseItemDto(id: "s1", imageTags: ["Primary": "own-1"], name: "s1", type: .audio))
        try await waitForBatch(store, id: "s1")

        await store.syncArtistArtwork()

        XCTAssertEqual(
            Set(store.artworkEntries.keys),
            ["al1|cover-1", "pl1|pl-cover", "art-1|artist-image", "s1|own-1"]
        )
    }

    /// Removing an artist's download takes their picture with it: the claim
    /// the artist id held goes, and the sweep reclaims the file — the same
    /// way a playlist's cover goes with the playlist.
    func testRemovingAnArtistTakesTheirPictureWithIt() async throws {
        stubCollections(
            ["al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist")]],
            artistAlbums: ["art-1": [AlbumStub(id: "al1", artistID: "art-1", artist: "Artist")]]
        )
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())
        let artist = BaseItemDto(id: "art-1", imageTags: ["Primary": "artist-image"], name: "Artist", type: .musicArtist)
        store.download(artist)
        try await waitForBatch(store, id: "art-1")
        XCTAssertNotNil(store.artworkEntries["art-1|artist-image"])

        store.remove(artist)

        XCTAssertNil(store.artworkEntries["art-1|artist-image"])
        XCTAssertTrue(artworkFiles(in: directory).isEmpty)
    }

    /// A picture whose tag the server replaced is superseded, not accumulated
    /// beside: re-downloading the artist claims the new one, and the sweep
    /// reclaims the old file.
    func testARedownloadedArtistPictureSupersedesTheEarlierOne() async throws {
        stubCollections(
            ["al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist")]],
            artistAlbums: ["art-1": [AlbumStub(id: "al1", artistID: "art-1", artist: "Artist")]]
        )
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())

        store.download(BaseItemDto(id: "art-1", imageTags: ["Primary": "old-tag"], name: "Artist", type: .musicArtist))
        try await waitForBatch(store, id: "art-1")
        store.download(BaseItemDto(id: "art-1", imageTags: ["Primary": "new-tag"], name: "Artist", type: .musicArtist))
        try await waitForBatch(store, id: "art-1")

        XCTAssertEqual(Set(store.artworkEntries.keys), ["art-1|new-tag"])
        XCTAssertEqual(artworkFiles(in: directory), ["art-1-new-tag.jpg"])
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
        XCTAssertTrue(rewritten.contains(#""version":4"#))
        XCTAssertTrue(rewritten.contains("al1|album-cover"))
    }

    // MARK: - Sizes

    /// The stub answers artwork requests — their path contains `/Items` —
    /// with an empty collection payload, so a saved cover is this many bytes.
    private var stubbedCoverSize: Int64 { Int64(Self.itemsData([]).count) }

    /// The header total: every song file and every artwork file, each
    /// counted once however many collections reference it.
    func testTheTotalCountsEverySongAndArtworkFileOnce() async throws {
        stubCollections([
            "al1": [
                trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover"),
                trackInAlbum("a2", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover"),
            ],
            "pl1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover")],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")
        store.download(BaseItemDto(id: "pl1", name: "Mix", type: .playlist))
        try await waitForBatch(store, id: "pl1")

        // The stub serves 5-byte "audio" for every song; the playlist's
        // member is the album's already-saved file, and the album's two
        // songs share one cover.
        XCTAssertEqual(store.entries["a1"]?.fileSize, 5)
        XCTAssertEqual(store.entries["a2"]?.fileSize, 5)
        XCTAssertEqual(store.totalByteCount, 10 + stubbedCoverSize)
    }

    /// A collection's own size, as its detail reports it: its songs on disk
    /// plus the cover it resolves. The group and its stand-in item agree —
    /// the detail renders the item — and an artist borrows the album's cover.
    func testCollectionsCountTheirSongsAndTheArtworkTheyResolve() async throws {
        stubCollections([
            "al1": [
                trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover"),
                trackInAlbum("a2", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover"),
            ],
        ])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")

        let album = try XCTUnwrap(store.downloadedAlbums().first)
        XCTAssertEqual(store.byteCount(for: album), 10 + stubbedCoverSize)
        XCTAssertEqual(
            store.byteCount(for: album.item),
            store.byteCount(for: album),
            "The detail's stand-in item resolves the same bytes as the group"
        )
        let artist = try XCTUnwrap(store.downloadedArtists().first)
        XCTAssertEqual(
            store.byteCount(for: artist),
            10 + stubbedCoverSize,
            "An artist counts their songs and borrows the album's cover"
        )
        // A plain song counts only its own file — the cover belongs to the album.
        XCTAssertEqual(store.byteCount(for: TestFixtures.item(id: "a1")), 5)
    }

    /// A downloaded playlist counts its members' files and its own cover.
    func testAPlaylistCountsItsMembersFilesAndItsCover() async throws {
        stubCollections(["pl1": [TrackStub(id: "x"), TrackStub(id: "y")]])
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())
        store.download(BaseItemDto(
            id: "pl1",
            imageTags: ["Primary": "cover-tag"],
            name: "Mix",
            type: .playlist
        ))
        try await waitForBatch(store, id: "pl1")

        let playlist = try XCTUnwrap(store.downloadedPlaylists().first)
        XCTAssertEqual(store.byteCount(for: playlist), 10 + stubbedCoverSize)
        XCTAssertEqual(store.byteCount(for: playlist.item), store.byteCount(for: playlist))
    }

    func testSizesSurviveRelaunch() async throws {
        stubCollections([
            "al1": [trackInAlbum("a1", albumID: "al1", album: "One", artistID: "art-1", artist: "Artist", imageTag: "cover")],
        ])
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())
        store.download(albumStub(id: "al1", artist: "Artist"))
        try await waitForBatch(store, id: "al1")
        let total = store.totalByteCount

        // The manifest write is async; give it a beat before reopening.
        try await Task.sleep(for: .milliseconds(100))
        let reopened = DownloadStore(directory: directory, session: try stubbedSession())

        XCTAssertEqual(reopened.entries["a1"]?.fileSize, 5)
        XCTAssertEqual(reopened.totalByteCount, total, "Sizes are read back from the manifest")
    }

    /// A manifest saved before sizes were recorded gains them at load,
    /// measured off the files themselves — the totals work after an upgrade
    /// without a re-download, and the measured sizes are persisted.
    func testAManifestWithoutSizesGainsThemFromTheFilesOnLoad() throws {
        let directory = newTestDirectory()
        let artworkDirectory = directory.appending(path: "Artwork", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try Data("audio-byte".utf8).write(to: directory.appending(path: "t1.mp3"))
        try Data("jpeg-data".utf8).write(to: artworkDirectory.appending(path: "al1-cover.jpg"))

        let manifest = #"""
        {"version":4,"tracks":{
            "t1":{"track":{"Id":"t1","Name":"t1","Type":"Audio","AlbumId":"al1","Album":"One","AlbumPrimaryImageTag":"cover"},
                  "filename":"t1.mp3","order":0,"requiredBy":["al1"]}
        },"playlists":{},"artwork":{
            "al1|cover":{"filename":"al1-cover.jpg","ownerItemID":"al1","imageTag":"cover","requiredBy":["t1"]}
        },"pendingTransfers":{},"activeBatches":{}}
        """#
        try Data(manifest.utf8).write(to: directory.appending(path: "manifest.json"))

        let store = DownloadStore(directory: directory, session: try stubbedSession())

        XCTAssertEqual(store.entries["t1"]?.fileSize, 10)
        XCTAssertEqual(store.artworkEntries["al1|cover"]?.fileSize, 9)
        XCTAssertEqual(store.totalByteCount, 19)
        let album = try XCTUnwrap(store.downloadedAlbums().first)
        XCTAssertEqual(store.byteCount(for: album), 19)
        let rewritten = try String(contentsOf: directory.appending(path: "manifest.json"), encoding: .utf8)
        XCTAssertTrue(rewritten.contains(#""fileSize":10"#), "The measured sizes are persisted")
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

    /// Albums downloaded before the manifest carried a total were downloaded
    /// whole, so migration gives them the total they were downloaded with —
    /// without it the default "complete albums" filter would hide every album
    /// an upgraded install has. An album that only surfaced through a playlist
    /// song stays unknown, and stays filtered: it was never downloaded whole.
    func testALegacyAlbumGainsItsTotalAndReadsAsComplete() throws {
        let directory = newTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["a1", "a2", "b1"] {
            try Data("audio".utf8).write(to: directory.appending(path: "\(name).mp3"))
        }

        func entry(id: String, albumID: String, album: String, source: String, order: Int) -> String {
            let track = #"{"Id":"\#(id)","Name":"\#(id)","Type":"Audio","AlbumId":"\#(albumID)","Album":"\#(album)"}"#
            return #""\#(id)":{"track":\#(track),"filename":"\#(id).mp3","order":\#(order),"requiredBy":["\#(source)"]}"#
        }
        let manifest = """
        {"version":2,"tracks":{
            \(entry(id: "a1", albumID: "al1", album: "One", source: "al1", order: 0)),
            \(entry(id: "a2", albumID: "al1", album: "One", source: "al1", order: 1)),
            \(entry(id: "b1", albumID: "al2", album: "Two", source: "pl1", order: 2))
        },"playlists":{},"artwork":{}}
        """
        try Data(manifest.utf8).write(to: directory.appending(path: "manifest.json"))

        let store = DownloadStore(directory: directory, session: try stubbedSession())

        XCTAssertEqual(store.entries["a1"]?.albumSongCount, 2, "The downloaded album's total is its songs on disk")
        XCTAssertNil(store.entries["b1"]?.albumSongCount, "A borrowed song's album keeps its unknown total")
        let albums = store.downloadedAlbums()
        let one = try XCTUnwrap(albums.first { $0.id == "al1" })
        let two = try XCTUnwrap(albums.first { $0.id == "al2" })
        XCTAssertTrue(one.isFullyDownloaded, "The legacy album survives the complete-albums filter")
        XCTAssertFalse(two.isFullyDownloaded, "The borrowed album stays filtered as partial")
    }

    /// An installed manifest that saved its songs under the server's raw
    /// multi-value container as the extension is repaired at load: the same
    /// bytes move to the playable name and the manifest is rewritten — no
    /// re-download, so the album an upgrade left unplayable plays again.
    func testASavedFileWithAnUnplayableExtensionIsRepairedOnLoad() throws {
        let directory = newTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unplayable = "a1.mov,mp4,m4a,3gp,3g2,mj2"
        try Data("audio".utf8).write(to: directory.appending(path: unplayable))

        let manifest = #"""
        {"version":4,"tracks":{
            "a1":{"track":{"Id":"a1","Name":"a1","Type":"Audio","Container":"mov,mp4,m4a,3gp,3g2,mj2","AlbumId":"al1","Album":"One"},
                  "filename":"\#(unplayable)","order":0,"requiredBy":["al1"]}
        },"playlists":{},"artwork":{},"pendingTransfers":{},"activeBatches":{}}
        """#
        try Data(manifest.utf8).write(to: directory.appending(path: "manifest.json"))

        let store = DownloadStore(directory: directory, session: try stubbedSession())

        XCTAssertEqual(store.entries["a1"]?.filename, "a1.m4a")
        XCTAssertEqual(
            store.localURL(forItemId: "a1")?.lastPathComponent,
            "a1.m4a",
            "The song resolves without a re-download"
        )
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains(unplayable), "The unplayable name is gone")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appending(path: "a1.m4a")),
            Data("audio".utf8),
            "The bytes moved with the rename"
        )
        let rewritten = try String(contentsOf: directory.appending(path: "manifest.json"), encoding: .utf8)
        XCTAssertTrue(rewritten.contains("a1.m4a"), "The repair is persisted")
        XCTAssertFalse(rewritten.contains(unplayable), "The unplayable name is not recorded any more")
    }

    /// The bug this guards: a manifest that would not decode reopened the
    /// store as empty, and the next download persisted that empty state over
    /// the unreadable file — every record gone, every file orphaned. Now the
    /// unreadable manifest is moved aside, the user is told, and later writes
    /// cannot touch it.
    func testAnUnreadableManifestIsSetAsideNotOverwritten() async throws {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data("audio-a".utf8))
        }
        let directory = newTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("not json {{{".utf8)
        try corrupt.write(to: directory.appending(path: "manifest.json"))

        let store = DownloadStore(directory: directory, session: try stubbedSession())

        let quarantine = directory.appending(path: "manifest.corrupt.json")
        XCTAssertEqual(try? Data(contentsOf: quarantine), corrupt, "The unreadable manifest is kept as-is")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "manifest.json").path),
                       "Nothing overwrites the evidence until the user downloads again")
        XCTAssertNotNil(store.errorMessage, "The user is told their downloads could not be read")

        store.configure(client: TestFixtures.stubbedClient())
        XCTAssertNotNil(store.errorMessage, "Signing in must not dismiss the warning before it was shown")
        store.download(TestFixtures.item(id: "a"))
        try await waitForBatch(store, id: "a")

        let rewritten = try Data(contentsOf: directory.appending(path: "manifest.json"))
        XCTAssertNotEqual(rewritten, corrupt)
        XCTAssertNotNil(store.entries["a"], "The store works normally after starting fresh")
        XCTAssertEqual(try? Data(contentsOf: quarantine), corrupt, "The set-aside record survives the fresh start")
    }

    /// "Delete All" mid-download: the batch is cancelled, whatever already
    /// landed is deleted with the rest, and no in-flight track resurrects an
    /// entry after the wipe.
    func testRemoveAllCancelsRunningBatchesAndNothingResurrects() async throws {
        stubCollections([
            "album": [
                trackInAlbum("t1", albumID: "album", album: "Album"),
                trackInAlbum("t2", albumID: "album", album: "Album"),
            ],
        ])
        URLProtocolStub.responseDelay = { request in
            request.url?.path.contains("t2") == true ? 0.3 : 0
        }
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: TestFixtures.stubbedClient())

        store.download(albumStub(id: "album", artist: "Artist"))
        for _ in 0 ..< 200 {
            if store.entries["t1"] != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(store.entries["t1"], "The first song landed before the wipe")

        store.removeAll()

        XCTAssertTrue(store.batches.isEmpty, "The running batch is gone immediately")
        XCTAssertTrue(store.entries.isEmpty)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(store.entries.isEmpty, "The cancelled transfer's song does not resurrect")
        XCTAssertNil(store.errorMessage, "A cancelled download is not an error")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains("t1.mp3"))
        XCTAssertFalse(files.contains("t2.mp3"))
        let reopened = DownloadStore(directory: directory, session: try stubbedSession())
        XCTAssertTrue(reopened.entries.isEmpty, "The empty state persists across relaunch")
        XCTAssertTrue(reopened.batches.isEmpty, "A wiped batch is not resumed either")
    }

    /// Removing a group stops its own download: without the cancel, every
    /// track still queued would re-save itself after the removal.
    func testRemoveCancelsTheItemsOwnBatch() async throws {
        stubCollections([
            "album": [
                trackInAlbum("t1", albumID: "album", album: "Album"),
                trackInAlbum("t2", albumID: "album", album: "Album"),
            ],
        ])
        URLProtocolStub.responseDelay = { request in
            request.url?.path.contains("t2") == true ? 0.3 : 0
        }
        let store = try makeStore()
        store.configure(client: TestFixtures.stubbedClient())

        let album = albumStub(id: "album", artist: "Artist")
        store.download(album)
        for _ in 0 ..< 200 {
            if store.entries["t1"] != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.remove(album)

        XCTAssertFalse(store.isBusy(album))
        XCTAssertTrue(store.entries.isEmpty)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(store.entries.isEmpty, "The queued track does not come back")
        XCTAssertNil(store.errorMessage, "A cancelled download is not an error")
    }

    /// A batch the process died in the middle of is persisted with its item,
    /// and the next signed-in launch starts it again: tracks already on disk
    /// dedupe, so the resume fetches only what is missing.
    func testARelaunchResumesAnInterruptedBatch() async throws {
        stubCollections([
            "album": [
                trackInAlbum("t1", albumID: "album", album: "Album"),
                trackInAlbum("t2", albumID: "album", album: "Album"),
            ],
        ])
        let directory = newTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appending(path: "t1.mp3"))
        let track = trackInAlbum("t1", albumID: "album", album: "Album")
        let manifest = #"""
        {"version":4,
         "tracks":{"t1":{"track":\#(track.json),"filename":"t1.mp3","order":0,"requiredBy":["album"],"albumSongCount":2,"artistKeys":[]}},
         "playlists":{},
         "artwork":{},
         "pendingTransfers":{},
         "activeBatches":{"album":{"Id":"album","Name":"album","Type":"MusicAlbum"}}}
        """#
        try Data(manifest.utf8).write(to: directory.appending(path: "manifest.json"))

        let store = DownloadStore(directory: directory, session: try stubbedSession())
        XCTAssertFalse(store.batches.contains { $0.id == "album" }, "Nothing resumes before a client exists")

        store.configure(client: TestFixtures.stubbedClient())
        try await waitForBatch(store, id: "album")

        XCTAssertNotNil(store.entries["t1"], "The song that was already on disk keeps its entry")
        XCTAssertNotNil(store.entries["t2"], "The missing song is fetched by the resume")
        XCTAssertEqual(store.downloadedAlbums().first { $0.id == "album" }?.downloadedSongs, 2)
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

    // MARK: - Background transfers: pending records and orphan adoption

    /// Writes a manifest as a process that died mid-transfer would have left
    /// it: `pendingTransfers` seeded from real values, so a test never
    /// hand-spells the encoder's shape.
    private func seedManifest(
        in directory: URL,
        tracks: String = "{}",
        pendingTransfers: [String: DownloadStore.PendingTransfer] = [:]
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pending = String(data: try JSONEncoder().encode(pendingTransfers), encoding: .utf8)!
        let manifest = #"""
        {"version":4,"tracks":\#(tracks),"playlists":{},"artwork":{},"pendingTransfers":\#(pending),"activeBatches":{}}
        """#
        try Data(manifest.utf8).write(to: directory.appending(path: "manifest.json"))
    }

    /// A delivered file parked under a temporary name of ours — the shape the
    /// session's delegate hands an adoption.
    private func parkedFile(_ contents: String = "audio") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "JellyJams-orphan-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// The record an adoption depends on is on disk while the transfer is in
    /// flight — keyed by a hash of the request URL, because stream URLs carry
    /// the access token and the manifest must not.
    func testAnInFlightTransferIsRecordedWithoutItsTokenOnDisk() async throws {
        let client = TestFixtures.stubbedClient(token: "s3cret-token")
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), Data("audio".utf8))
        }
        URLProtocolStub.responseDelay = { _ in 0.3 }
        let directory = newTestDirectory()
        let store = DownloadStore(directory: directory, session: try stubbedSession())
        store.configure(client: client)

        let remote = try client.streamURL(itemId: "a", mediaSourceId: nil)
        XCTAssertTrue(remote.absoluteString.contains("s3cret-token"), "The stream URL carries the token")
        let key = DownloadStore.pendingKey(for: remote)

        store.download(TestFixtures.item(id: "a"))
        var text = ""
        for _ in 0 ..< 200 {
            let data = (try? Data(contentsOf: directory.appending(path: "manifest.json"))) ?? Data()
            text = String(data: data, encoding: .utf8) ?? ""
            if text.contains(key) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(text.contains(key), "The in-flight transfer is recorded under its URL hash")
        XCTAssertFalse(text.contains("s3cret-token"), "The token never reaches the disk")

        try await waitForBatch(store, id: "a")
        XCTAssertNotNil(store.entries["a"])
        let after = String(
            data: try Data(contentsOf: directory.appending(path: "manifest.json")),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(after.contains(key), "The record is consumed once the file lands")
        XCTAssertFalse(after.contains("s3cret-token"), "Neither does the finished manifest carry it")
    }

    /// A completion the system kept across a process death is filed exactly
    /// the way the transfer would have filed itself: entry, file under its
    /// recorded name, and the pending record consumed and persisted.
    func testAnOrphanedAudioTransferIsFiledFromItsPendingRecord() throws {
        let directory = newTestDirectory()
        let remote = URL(string: "https://example.com/jellyfin/Audio/t1/stream")!
        try seedManifest(in: directory, pendingTransfers: [
            DownloadStore.pendingKey(for: remote): .audio(
                track: TestFixtures.item(id: "t1"),
                filename: "t1.mp3",
                source: "album",
                batchId: "album",
                albumSongCount: 2,
                artistKeys: ["Artist"]
            ),
        ])
        let store = DownloadStore(directory: directory, session: try stubbedSession())

        let parked = try parkedFile()
        store.adoptOrphanedTransfer(requestURL: remote, file: parked, statusCode: 200)

        let entry = try XCTUnwrap(store.entries["t1"], "The kept file is filed as the song it was for")
        XCTAssertEqual(entry.filename, "t1.mp3")
        XCTAssertEqual(entry.sources, ["album"])
        XCTAssertEqual(entry.albumSongCount, 2)
        XCTAssertEqual(entry.artistKeys, ["Artist"])
        XCTAssertEqual(
            try? Data(contentsOf: directory.appending(path: "t1.mp3")),
            Data("audio".utf8),
            "The file is filed under its recorded name"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path), "The parked copy is consumed")

        let reopened = DownloadStore(directory: directory, session: try stubbedSession())
        XCTAssertNotNil(reopened.entries["t1"], "The adoption survives a relaunch")
        let text = String(
            data: try Data(contentsOf: directory.appending(path: "manifest.json")),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(text.contains(DownloadStore.pendingKey(for: remote)), "The pending record is consumed")
    }

    /// A transfer that was in flight when the app was upgraded recorded the
    /// raw multi-value container as its filename. The record is repaired at
    /// load, so the delivery the system kept is filed under the playable
    /// name.
    func testAPendingTransferRecordIsRepairedToThePlayableFilename() throws {
        let directory = newTestDirectory()
        let remote = URL(string: "https://example.com/jellyfin/Audio/t1/stream")!
        try seedManifest(in: directory, pendingTransfers: [
            DownloadStore.pendingKey(for: remote): .audio(
                track: BaseItemDto(container: "mov,mp4,m4a,3gp,3g2,mj2", id: "t1", name: "t1", type: .audio),
                filename: "t1.mov,mp4,m4a,3gp,3g2,mj2",
                source: "album",
                batchId: "album",
                albumSongCount: nil,
                artistKeys: []
            ),
        ])
        let store = DownloadStore(directory: directory, session: try stubbedSession())

        let parked = try parkedFile()
        store.adoptOrphanedTransfer(requestURL: remote, file: parked, statusCode: 200)

        XCTAssertEqual(store.entries["t1"]?.filename, "t1.m4a")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appending(path: "t1.m4a")),
            Data("audio".utf8),
            "The kept file is filed under the playable name"
        )
    }

    /// A cover the system finished across a death is filed the same way, under
    /// the owner-plus-tag key the views resolve.
    func testAnOrphanedArtworkTransferIsFiledFromItsPendingRecord() throws {
        let directory = newTestDirectory()
        let remote = URL(string: "https://example.com/jellyfin/Items/al1/Images/Primary")!
        try seedManifest(in: directory, pendingTransfers: [
            DownloadStore.pendingKey(for: remote): .artwork(
                ownerID: "al1",
                imageTag: "cover",
                filename: "al1-cover.jpg",
                holderID: "t1"
            ),
        ])
        let store = DownloadStore(directory: directory, session: try stubbedSession())

        let parked = try parkedFile("jpeg-bytes")
        store.adoptOrphanedTransfer(requestURL: remote, file: parked, statusCode: 200)

        let entry = try XCTUnwrap(store.artworkEntries["al1|cover"])
        XCTAssertEqual(entry.requiredBy, ["t1"])
        XCTAssertEqual(
            try? Data(contentsOf: directory.appending(path: "Artwork").appending(path: "al1-cover.jpg")),
            Data("jpeg-bytes".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path))
    }

    /// The pending record is the only authority for a delivery: a file nobody
    /// recorded, one whose record named a different transfer, and one whose
    /// transfer failed HTTP are all deleted rather than filed — an error page
    /// must not become a song.
    func testOrphanedTransfersWithoutAUsableRecordAreDiscarded() throws {
        let directory = newTestDirectory()
        let remote = URL(string: "https://example.com/jellyfin/Audio/t1/stream")!
        try seedManifest(in: directory, pendingTransfers: [
            DownloadStore.pendingKey(for: remote): .audio(
                track: TestFixtures.item(id: "t1"),
                filename: "t1.mp3",
                source: "album",
                batchId: "album",
                albumSongCount: nil,
                artistKeys: []
            ),
        ])
        let store = DownloadStore(directory: directory, session: try stubbedSession())

        let unknown = try parkedFile()
        store.adoptOrphanedTransfer(
            requestURL: URL(string: "https://example.com/jellyfin/Audio/other/stream")!,
            file: unknown,
            statusCode: 200
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknown.path), "An unrecorded file is deleted")

        let nameless = try parkedFile()
        store.adoptOrphanedTransfer(requestURL: nil, file: nameless, statusCode: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nameless.path), "A delivery with no URL cannot match a record")

        XCTAssertTrue(store.entries.isEmpty, "Neither delivery filed anything")

        let failed = try parkedFile("<html>500</html>")
        store.adoptOrphanedTransfer(requestURL: remote, file: failed, statusCode: 500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path), "A failed transfer's file is deleted")
        XCTAssertTrue(store.entries.isEmpty, "An error page is not filed as audio")

        let reopened = DownloadStore(directory: directory, session: try stubbedSession())
        XCTAssertTrue(reopened.entries.isEmpty)
        let text = String(
            data: try Data(contentsOf: directory.appending(path: "manifest.json")),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(
            text.contains(DownloadStore.pendingKey(for: remote)),
            "The failed record does not linger to catch a later delivery"
        )
    }

    /// A resumed batch can re-fetch a song the system also kept: the entry
    /// that already exists wins and the kept duplicate is deleted, rather
    /// than the adoption overwriting the fresher file.
    func testAnOrphanedSongAResumeAlreadyRefetchedIsDiscarded() throws {
        let directory = newTestDirectory()
        let remote = URL(string: "https://example.com/jellyfin/Audio/t1/stream")!
        let tracks = #"""
        {"t1":{"track":{"Id":"t1","Name":"t1","Type":"Audio"},"filename":"t1.mp3","order":0,"requiredBy":["album"],"albumSongCount":1,"artistKeys":[]}}
        """#
        try seedManifest(in: directory, tracks: tracks, pendingTransfers: [
            DownloadStore.pendingKey(for: remote): .audio(
                track: TestFixtures.item(id: "t1"),
                filename: "t1.mp3",
                source: "album",
                batchId: "album",
                albumSongCount: 1,
                artistKeys: []
            ),
        ])
        try Data("already-here".utf8).write(to: directory.appending(path: "t1.mp3"))
        let store = DownloadStore(directory: directory, session: try stubbedSession())

        let parked = try parkedFile("kept-duplicate")
        store.adoptOrphanedTransfer(requestURL: remote, file: parked, statusCode: 200)

        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path), "The kept duplicate is deleted")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appending(path: "t1.mp3")),
            Data("already-here".utf8),
            "The refetched file stays as it was"
        )
        XCTAssertEqual(store.entries.count, 1)
    }

    /// The quarantine message's promise: the audio an unreadable manifest
    /// orphaned is still on disk, and "Delete All" — which wipes by directory
    /// enumeration, not by record — reclaims it along with the set-aside
    /// manifest itself.
    func testRemoveAllReclaimsAudioAQuarantinedManifestOrphaned() throws {
        let directory = newTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json {{{".utf8).write(to: directory.appending(path: "manifest.json"))
        try Data("audio".utf8).write(to: directory.appending(path: "orphaned-song.mp3"))
        try FileManager.default.createDirectory(at: directory.appending(path: "Artwork"), withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: directory.appending(path: "Artwork").appending(path: "orphaned-cover.jpg"))

        let store = DownloadStore(directory: directory, session: try stubbedSession())
        XCTAssertNotNil(store.errorMessage, "The unreadable manifest is quarantined")
        XCTAssertTrue(store.entries.isEmpty)

        store.removeAll()

        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains("orphaned-song.mp3"), "Audio no entry knows about is reclaimed too")
        XCTAssertFalse(files.contains("manifest.corrupt.json"), "The user chose to delete everything")
        let artwork = (try? FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Artwork").path)) ?? []
        XCTAssertEqual(artwork, [])
        XCTAssertTrue(store.entries.isEmpty)
    }

    #if os(iOS)
    /// The configuration the background transfers are promised to run under:
    /// proceeds right away rather than at the system's discretion, and wakes
    /// the app when the system finishes a transfer it kept across a death.
    func testTheBackgroundSessionIsConfiguredToSurviveTheApp() {
        let session = DownloadSession(
            backgroundIdentifier: "net.aseriesoftubes.JellyJamsTests.\(UUID().uuidString)"
        )
        XCTAssertTrue(
            session.configuration.sessionSendsLaunchEvents,
            "A transfer finished after a death wakes the app to adopt it"
        )
        XCTAssertFalse(session.configuration.isDiscretionary, "Downloads proceed right away")
    }
    #endif
}
