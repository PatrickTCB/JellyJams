import MediaPlayer
import XCTest
@testable import JellyJams

/// The Now Playing dictionary is what tvOS renders in Control Centre's tile
/// and the idle-time overlay, and what Continuity reads to publish the iPhone
/// lock-screen card. These tests pin the keys that classify the playback as
/// audio — a dictionary missing them is exactly the failure where music
/// plays but the system shows nothing for it.
@MainActor
final class NowPlayingCenterTests: XCTestCase {
    override func tearDown() {
        NowPlayingCenter.shared.clear()
        super.tearDown()
    }

    func testUpdatePublishesTheAudioMediaTypes() {
        NowPlayingCenter.shared.update(
            item: TestFixtures.item(id: "song-1", name: "Whiplash"),
            isPlaying: true,
            currentTime: 12,
            duration: 240,
            artworkURL: nil,
            localArtworkURL: nil,
            canGoNext: true,
            canGoPrevious: false,
            isFavourite: false,
            isShuffled: false,
            repeatMode: .repeatNone
        )

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Whiplash")
        XCTAssertEqual(
            info?[MPNowPlayingInfoPropertyMediaType] as? UInt,
            MPNowPlayingInfoMediaType.audio.rawValue,
            "tvOS classifies the Now Playing card by this key"
        )
        XCTAssertEqual(
            info?[MPMediaItemPropertyMediaType] as? UInt,
            MPMediaType.music.rawValue,
            "Continuity reads the legacy key for the iPhone lock-screen card"
        )
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
    }

    func testPausedPlaybackPublishesAZeroRate() {
        NowPlayingCenter.shared.update(
            item: TestFixtures.item(id: "song-1", name: "Whiplash"),
            isPlaying: false,
            currentTime: 12,
            duration: 240,
            artworkURL: nil,
            localArtworkURL: nil,
            canGoNext: true,
            canGoPrevious: false,
            isFavourite: false,
            isShuffled: false,
            repeatMode: .repeatNone
        )

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
    }

    func testClearRemovesTheNowPlayingInfo() {
        NowPlayingCenter.shared.update(
            item: TestFixtures.item(id: "song-1", name: "Whiplash"),
            isPlaying: true,
            currentTime: 0,
            duration: 240,
            artworkURL: nil,
            localArtworkURL: nil,
            canGoNext: false,
            canGoPrevious: false,
            isFavourite: false,
            isShuffled: false,
            repeatMode: .repeatNone
        )

        NowPlayingCenter.shared.clear()

        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }
}
