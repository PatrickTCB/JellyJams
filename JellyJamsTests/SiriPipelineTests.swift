#if os(iOS) || os(tvOS)
import Intents
import XCTest
@testable import JellyJams

/// ``SiriCandidate`` is the shared pipeline's currency: its display strings
/// must read the same way the schema entities' do, so a request sounds the
/// same whichever Siri path answered it.
final class SiriCandidateTests: XCTestCase {
    func testASongCandidateTakesItsTitleAndArtistFromTheItem() {
        let candidate = SiriCandidate(
            item: BaseItemDto(
                artists: ["Architects"],
                id: "song-1",
                name: "Whiplash",
                type: .audio
            ),
            kind: .song,
            artworkURL: nil
        )

        XCTAssertEqual(candidate.id, "song-1")
        XCTAssertEqual(candidate.title, "Whiplash")
        XCTAssertEqual(candidate.subtitle, "Architects")
    }

    func testAnAlbumCandidateTakesItsAlbumArtistFromTheItem() {
        let candidate = SiriCandidate(
            item: BaseItemDto(
                albumArtist: "Architects",
                id: "album-1",
                name: "For All Kings",
                type: .musicAlbum
            ),
            kind: .album,
            artworkURL: nil
        )

        XCTAssertEqual(candidate.title, "For All Kings")
        XCTAssertEqual(candidate.subtitle, "Architects")
    }

    func testArtistAndPlaylistCandidatesCarryNoSubtitle() {
        let artist = SiriCandidate(item: BaseItemDto(id: "artist-1", name: "Architects", type: .musicArtist), kind: .artist, artworkURL: nil)
        let playlist = SiriCandidate(item: BaseItemDto(id: "playlist-1", name: "Top 40", type: .playlist), kind: .playlist, artworkURL: nil)

        XCTAssertNil(artist.subtitle)
        XCTAssertNil(playlist.subtitle)
        XCTAssertEqual(artist.title, "Architects")
        XCTAssertEqual(playlist.title, "Top 40")
    }

    func testASyntheticCandidateKeepsItsIdentityWithoutAnItem() {
        let candidate = FavouriteSongsPlaylist.candidate()

        XCTAssertEqual(candidate.id, FavouriteSongsPlaylist.id)
        XCTAssertEqual(candidate.kind, .playlist)
        XCTAssertEqual(candidate.title, FavouriteSongsPlaylist.title)
        XCTAssertNil(candidate.item)
    }
}

/// The hand-off contract between the tvOS Siri extension and the app: the
/// pass-through identifier marking, and the request snapshot the app takes
/// from the delivered activity — intent first, userInfo as the fallback.
final class SiriMediaRequestTests: XCTestCase {
    private func makeSearch(name: String?, artist: String? = nil, mediaType: INMediaItemType = .unknown) -> INMediaSearch {
        INMediaSearch(
            mediaType: mediaType,
            sortOrder: .unknown,
            mediaName: name,
            artistName: artist,
            albumName: nil,
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: nil
        )
    }

    private func makeActivity(userInfo: [String: Any]? = nil) -> NSUserActivity {
        let activity = NSUserActivity(activityType: SiriMediaRequest.activityType)
        activity.userInfo = userInfo
        return activity
    }

    private func makeIntent(search: INMediaSearch?, itemIdentifier: String?) -> INPlayMediaIntent {
        let items = itemIdentifier.map {
            [INMediaItem(identifier: $0, title: "Stand-in", type: .unknown, artwork: nil)]
        }
        return INPlayMediaIntent(
            mediaItems: items,
            mediaContainer: nil,
            playShuffled: nil,
            playbackRepeatMode: .unknown,
            resumePlayback: nil,
            playbackQueueLocation: .unknown,
            playbackSpeed: nil,
            mediaSearch: search
        )
    }

    func testPassThroughIdentifiersAreMarked() {
        let identifier = SiriMediaRequest.passThroughIdentifier()

        XCTAssertTrue(identifier.hasPrefix(SiriMediaRequest.identifierPrefix))
        XCTAssertNotEqual(identifier, SiriMediaRequest.passThroughIdentifier())
    }

    func testAPassThroughRequestResolvesFreshRatherThanByItsIdentifier() {
        let intent = makeIntent(
            search: makeSearch(name: "Whiplash", artist: "Architects", mediaType: .song),
            itemIdentifier: SiriMediaRequest.passThroughIdentifier()
        )

        let request = SiriMediaRequest(intent: intent, userInfo: nil)

        XCTAssertEqual(request.name, "Whiplash")
        XCTAssertEqual(request.artist, "Architects")
        XCTAssertEqual(request.mediaType, .song)
        XCTAssertNil(request.concreteIdentifier, "The stand-in id must send the app back to the search, not the server")
    }

    func testAConcreteIdentifierPlaysDirectly() {
        let intent = makeIntent(search: nil, itemIdentifier: "server-item-1")

        let request = SiriMediaRequest(intent: intent, userInfo: nil)

        XCTAssertEqual(request.concreteIdentifier, "server-item-1")
        XCTAssertNil(request.name)
    }

    func testTheUserInfoFallbackCarriesTheSearchWhenNoIntentArrives() {
        let search = makeSearch(name: "Whiplash", artist: "Architects", mediaType: .song)
        let activity = makeActivity(userInfo: SiriMediaRequest.userInfo(for: search))

        let request = SiriMediaRequest(activity: activity)

        XCTAssertEqual(request.name, "Whiplash")
        XCTAssertEqual(request.artist, "Architects")
        XCTAssertEqual(request.mediaType, .song)
        XCTAssertNil(request.concreteIdentifier)
    }

    func testTheIntentWinsOverTheUserInfoCopy() {
        let intent = makeIntent(search: makeSearch(name: "From the intent"), itemIdentifier: nil)

        let request = SiriMediaRequest(
            intent: intent,
            userInfo: SiriMediaRequest.userInfo(for: makeSearch(name: "From the fallback"))
        )

        XCTAssertEqual(request.name, "From the intent")
    }

    func testAnEmptyRequestCarriesNothing() {
        let request = SiriMediaRequest(intent: makeIntent(search: nil, itemIdentifier: nil), userInfo: nil)

        XCTAssertNil(request.name)
        XCTAssertNil(request.artist)
        XCTAssertNil(request.mediaType)
        XCTAssertNil(request.concreteIdentifier)
    }
}
#endif
