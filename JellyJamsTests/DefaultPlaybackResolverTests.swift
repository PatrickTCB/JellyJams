import XCTest
@testable import JellyJams

/// ``DefaultPlaybackResolver`` turns a saved "play this by default" setting
/// into an actual queue, falling back to a favourites shuffle whenever the
/// setting is absent or no longer produces anything playable.
final class DefaultPlaybackResolverTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    /// Routes `GET /Items/{id}` to `itemResponse` and every other request to
    /// `otherResponse`, mirroring how the resolver first looks the item up
    /// and then either expands it or falls back to the favourites queue.
    private func installStub(
        itemId: String,
        itemResponse: @escaping () -> Data,
        otherResponse: @escaping (URLRequest) -> Data
    ) {
        URLProtocolStub.handler = { request in
            let data = request.url?.path == "/jellyfin/Items/\(itemId)"
                ? itemResponse()
                : otherResponse(request)
            return (try emptyResponse(for: request, statusCode: 200), data)
        }
    }

    private func setting(
        kind: DefaultPlaybackSetting.Kind,
        itemId: String,
        shuffle: Bool,
        repeatMode: RepeatMode
    ) -> DefaultPlaybackSetting {
        DefaultPlaybackSetting(
            kind: kind,
            itemId: itemId,
            title: itemId,
            shuffle: shuffle,
            repeatMode: repeatMode
        )
    }

    func testResolveWithNoSettingFallsBackToAFavouritesShuffle() async throws {
        URLProtocolStub.handler = { request in
            let isFavourites = request.url?.absoluteString.contains("IsFavorite") == true
            let payload = isFavourites ? itemsPayload([(id: "fav-1", type: "Audio")]) : emptyItemsPayload
            return (try emptyResponse(for: request, statusCode: 200), payload)
        }

        let resolved = try await DefaultPlaybackResolver.resolve(setting: nil, client: TestFixtures.stubbedClient())

        XCTAssertEqual(resolved.tracks.compactMap(\.id), ["fav-1"])
        XCTAssertFalse(resolved.shuffled)
        XCTAssertNil(resolved.repeatMode)
    }

    func testResolveSongSettingPlaysOnlyThatTrackWithoutExpandingIt() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            let isItem = request.url?.path == "/jellyfin/Items/song-id"
            let data = isItem ? singleItemPayload(id: "song-id", type: "Audio") : emptyItemsPayload
            return (try emptyResponse(for: request, statusCode: 200), data)
        }

        let resolved = try await DefaultPlaybackResolver.resolve(
            setting: setting(kind: .song, itemId: "song-id", shuffle: false, repeatMode: .repeatOne),
            client: TestFixtures.stubbedClient()
        )

        XCTAssertEqual(resolved.tracks.compactMap(\.id), ["song-id"])
        XCTAssertEqual(recorder.all.map(\.path), ["/jellyfin/Items/song-id"])
        XCTAssertFalse(resolved.shuffled)
        XCTAssertEqual(resolved.repeatMode, .repeatOne)
    }

    func testResolveAlbumSettingExpandsToTracksAndKeepsTheSettingsShuffleFlag() async throws {
        installStub(
            itemId: "album-id",
            itemResponse: { singleItemPayload(id: "album-id", type: "MusicAlbum") },
            otherResponse: { _ in itemsPayload([(id: "track-1", type: "Audio"), (id: "track-2", type: "Audio")]) }
        )

        let resolved = try await DefaultPlaybackResolver.resolve(
            setting: setting(kind: .album, itemId: "album-id", shuffle: true, repeatMode: .repeatAll),
            client: TestFixtures.stubbedClient()
        )

        XCTAssertEqual(resolved.tracks.compactMap(\.id), ["track-1", "track-2"])
        XCTAssertTrue(resolved.shuffled)
        XCTAssertEqual(resolved.repeatMode, .repeatAll)
    }

    func testResolveArtistSettingAlwaysShufflesEvenWhenTheSettingDoesNot() async throws {
        installStub(
            itemId: "artist-id",
            itemResponse: { singleItemPayload(id: "artist-id", type: "MusicArtist") },
            otherResponse: { _ in itemsPayload([(id: "track-1", type: "Audio")]) }
        )

        let resolved = try await DefaultPlaybackResolver.resolve(
            setting: setting(kind: .artist, itemId: "artist-id", shuffle: false, repeatMode: .repeatNone),
            client: TestFixtures.stubbedClient()
        )

        XCTAssertTrue(resolved.shuffled, "Artist playback always shuffles, regardless of the saved flag")
    }

    func testResolveFallsBackWhenTheSavedPlaylistHasNoTracksLeft() async throws {
        URLProtocolStub.handler = { request in
            let data: Data
            if request.url?.path == "/jellyfin/Items/playlist-id" {
                data = singleItemPayload(id: "playlist-id", type: "Playlist")
            } else if request.url?.path == "/jellyfin/Playlists/playlist-id/Items" {
                data = emptyItemsPayload
            } else if request.url?.absoluteString.contains("IsFavorite") == true {
                data = itemsPayload([(id: "fallback-fav", type: "Audio")])
            } else {
                data = emptyItemsPayload
            }
            return (try emptyResponse(for: request, statusCode: 200), data)
        }

        let resolved = try await DefaultPlaybackResolver.resolve(
            setting: setting(kind: .playlist, itemId: "playlist-id", shuffle: true, repeatMode: .repeatAll),
            client: TestFixtures.stubbedClient()
        )

        XCTAssertEqual(resolved.tracks.compactMap(\.id), ["fallback-fav"])
        XCTAssertFalse(resolved.shuffled, "An emptied-out setting should fall back exactly like a missing one")
        XCTAssertNil(resolved.repeatMode)
    }
}
