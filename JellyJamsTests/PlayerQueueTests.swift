import AVFoundation
import XCTest
@testable import JellyJams

/// Queue, shuffle, repeat and transport behaviour.
///
/// These tests drive the real ``PlayerController`` against an offline client
/// (see ``TestFixtures/offlineClient()``): stream URLs are built exactly as in
/// the app so all queue bookkeeping runs, but nothing reaches the network. The
/// `AVPlayer` never actually produces audio, so assertions stay on the
/// controller's own published state.
@MainActor
final class PlayerQueueTests: XCTestCase {
    private func makePlayer() -> PlayerController {
        let player = PlayerController()
        player.configure(client: TestFixtures.offlineClient())
        return player
    }

    private func ids(_ player: PlayerController) -> [String] {
        player.queue.compactMap(\.item.id)
    }

    private func play(_ player: PlayerController, _ trackIds: [String]) {
        player.play(trackIds.map { TestFixtures.item(id: $0) })
    }

    // MARK: - Starting playback

    func testPlayStartsAtTheRequestedIndex() {
        let player = makePlayer()

        player.play(["a", "b", "c"].map { TestFixtures.item(id: $0) }, startAt: 2)

        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.currentItem?.id, "c")
        XCTAssertTrue(player.isPlaying)
    }

    /// Non-audio entries are dropped from the queue, so the caller's index —
    /// which counts them — has to be translated, not used verbatim.
    func testPlayTranslatesTheStartIndexPastFilteredOutItems() {
        let player = makePlayer()
        let items = [
            TestFixtures.item(id: "album", type: .musicAlbum),
            TestFixtures.item(id: "a"),
            TestFixtures.item(id: "b"),
        ]

        player.play(items, startAt: 2)

        XCTAssertEqual(ids(player), ["a", "b"])
        XCTAssertEqual(player.currentItem?.id, "b", "The caller asked for the item at index 2")
    }

    func testPlayIgnoresACollectionWithNoPlayableTracks() {
        let player = makePlayer()

        player.play([TestFixtures.item(id: "album", type: .musicAlbum)])

        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentIndex)
    }

    /// Nothing can be built without a client, and silently doing nothing would
    /// look identical to a broken button.
    func testPlayingWithoutAConfiguredClientDoesNotHalfFillTheQueue() {
        let player = PlayerController()

        player.play([TestFixtures.item(id: "a")])

        XCTAssertNil(player.currentItem)
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - next / previous

    /// Running off the end finishes playback rather than parking on the last
    /// track: the queue is emptied, which is what tears the Now Playing bar
    /// down. Only the natural end of the final track gets here — `canGoNext` is
    /// false at that point, so every Next affordance is already disabled.
    func testNextAdvancesAndClearsTheQueueAtTheEnd() {
        let player = makePlayer()
        play(player, ["a", "b"])

        player.next()
        XCTAssertEqual(player.currentItem?.id, "b")
        XCTAssertFalse(player.canGoNext)

        player.next()

        XCTAssertTrue(player.queue.isEmpty, "Finishing the queue clears it")
        XCTAssertNil(player.currentIndex)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasQueue)
    }

    func testPreviousStepsBackAndStaysPutOnTheFirstTrack() {
        let player = makePlayer()
        play(player, ["a", "b"])
        player.play(atQueueIndex: 1)

        player.previous()
        XCTAssertEqual(player.currentItem?.id, "a")

        player.previous()
        XCTAssertEqual(player.currentItem?.id, "a", "There is nothing before the first track")
    }

    func testPlayAtQueueIndexIgnoresAnOutOfRangeIndex() {
        let player = makePlayer()
        play(player, ["a", "b"])

        player.play(atQueueIndex: 7)

        XCTAssertEqual(player.currentIndex, 0)
    }

    // MARK: - Repeat

    func testCycleRepeatModeRotatesThroughAllThreeModes() {
        let player = makePlayer()
        XCTAssertEqual(player.repeatMode, .repeatNone)

        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .repeatAll)

        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .repeatOne)

        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .repeatNone)
    }

    func testRepeatAllWrapsFromTheLastTrackBackToTheFirst() {
        let player = makePlayer()
        play(player, ["a", "b"])
        player.play(atQueueIndex: 1)
        player.repeatMode = .repeatAll

        XCTAssertTrue(player.canGoNext, "Repeat All always offers a next track")
        player.next()

        XCTAssertEqual(player.currentItem?.id, "a")
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.queue.count, 2, "Wrapping must not take the finish-and-clear path")
    }

    func testRepeatNoneReportsNoNextTrackOnTheLastItem() {
        let player = makePlayer()
        play(player, ["a", "b"])
        player.play(atQueueIndex: 1)

        XCTAssertFalse(player.canGoNext)
    }

    // MARK: - Shuffle

    func testShufflingKeepsTheCurrentTrackPlayingAndFirstInTheQueue() {
        let player = makePlayer()
        play(player, (0 ..< 25).map { "track-\($0)" })
        player.play(atQueueIndex: 7)
        let playing = player.currentItem?.id

        player.toggleShuffle()

        XCTAssertTrue(player.isShuffled)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.currentItem?.id, playing, "Shuffling must not change what is playing")
        XCTAssertEqual(player.queue.count, 25)
        XCTAssertEqual(Set(ids(player)).count, 25, "Shuffling must not drop or duplicate tracks")
    }

    func testUnshufflingRestoresTheOriginalOrderAndFollowsTheCurrentTrack() {
        let player = makePlayer()
        let original = (0 ..< 25).map { "track-\($0)" }
        play(player, original)
        player.play(atQueueIndex: 7)

        player.toggleShuffle()
        player.toggleShuffle()

        XCTAssertFalse(player.isShuffled)
        XCTAssertEqual(ids(player), original)
        XCTAssertEqual(player.currentItem?.id, "track-7", "The playing track is tracked by identity")
        XCTAssertEqual(player.currentIndex, 7)
    }

    func testPlayingShuffledCanBeUnshuffledIntoTheSuppliedOrder() {
        let player = makePlayer()
        let original = (0 ..< 25).map { "track-\($0)" }

        player.play(original.map { TestFixtures.item(id: $0) }, shuffled: true)
        XCTAssertTrue(player.isShuffled)
        let playing = player.currentItem?.id

        player.toggleShuffle()

        XCTAssertEqual(ids(player), original)
        XCTAssertEqual(player.currentItem?.id, playing)
    }

    /// Tracks queued while shuffled have to land in the unshuffled order too,
    /// or they vanish the moment shuffle is switched off.
    func testTracksAddedWhileShuffledSurviveUnshuffling() {
        let player = makePlayer()
        play(player, ["a", "b", "c"])
        player.toggleShuffle()

        player.addToQueue([TestFixtures.item(id: "appended")])
        player.playNext([TestFixtures.item(id: "inserted")])
        player.toggleShuffle()

        XCTAssertEqual(Set(ids(player)), ["a", "b", "c", "appended", "inserted"])
        XCTAssertEqual(player.queue.count, 5)
    }

    // MARK: - Removing

    func testRemovingTracksBeforeTheCurrentOneKeepsItPlaying() {
        let player = makePlayer()
        play(player, ["a", "b", "c", "d"])
        player.play(atQueueIndex: 2)

        player.removeFromQueue(atOffsets: IndexSet([0, 1]))

        XCTAssertEqual(ids(player), ["c", "d"])
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.currentItem?.id, "c", "The same track keeps playing")
    }

    func testRemovingTracksAfterTheCurrentOneLeavesItUntouched() {
        let player = makePlayer()
        play(player, ["a", "b", "c", "d"])
        player.play(atQueueIndex: 1)

        player.removeFromQueue(atOffsets: IndexSet([2, 3]))

        XCTAssertEqual(ids(player), ["a", "b"])
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.currentItem?.id, "b")
    }

    func testRemovingTheCurrentTrackStartsTheOneThatTakesItsPlace() {
        let player = makePlayer()
        play(player, ["a", "b", "c"])
        player.play(atQueueIndex: 1)

        player.removeFromQueue(atOffsets: IndexSet(integer: 1))

        XCTAssertEqual(ids(player), ["a", "c"])
        XCTAssertEqual(player.currentItem?.id, "c")
        XCTAssertTrue(player.isPlaying)
    }

    func testRemovingTheLastTrackFallsBackToTheNewFinalTrack() {
        let player = makePlayer()
        play(player, ["a", "b", "c"])
        player.play(atQueueIndex: 2)

        player.removeFromQueue(atOffsets: IndexSet(integer: 2))

        XCTAssertEqual(ids(player), ["a", "b"])
        XCTAssertEqual(player.currentItem?.id, "b")
    }

    /// Deleting the playing track from the queue while paused must not turn
    /// into an unexpected burst of audio.
    func testRemovingTheCurrentTrackWhilePausedStaysPaused() {
        let player = makePlayer()
        play(player, ["a", "b", "c"])
        player.pause()
        XCTAssertFalse(player.isPlaying)

        player.removeFromQueue(atOffsets: IndexSet(integer: 0))

        XCTAssertEqual(player.currentItem?.id, "b")
        XCTAssertFalse(player.isPlaying, "Removing a track is not a request to start playing")
    }

    func testRemovingEveryTrackClearsThePlayer() {
        let player = makePlayer()
        play(player, ["a", "b"])

        player.removeFromQueue(atOffsets: IndexSet([0, 1]))

        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentIndex)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(player.isPlaying)
    }

    func testRemovingNothingIsANoOp() {
        let player = makePlayer()
        play(player, ["a", "b"])

        player.removeFromQueue(atOffsets: IndexSet())

        XCTAssertEqual(ids(player), ["a", "b"])
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testRemovalKeepsTheUnshuffledOrderInSync() {
        let player = makePlayer()
        play(player, ["a", "b", "c", "d"])
        player.toggleShuffle()

        // Remove whichever track is currently sitting last in the shuffled queue.
        let doomed = try! XCTUnwrap(player.queue.last?.item.id)
        player.removeFromQueue(atOffsets: IndexSet(integer: player.queue.count - 1))
        player.toggleShuffle()

        XCTAssertFalse(ids(player).contains(doomed), "A removed track must not reappear when unshuffling")
        XCTAssertEqual(player.queue.count, 3)
    }

    // MARK: - Reordering

    func testMovingATrackKeepsTheCurrentIndexOnTheSameTrack() {
        let player = makePlayer()
        play(player, ["a", "b", "c"])
        player.play(atQueueIndex: 0)

        // Drag "a" to the end.
        player.moveQueue(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(ids(player), ["b", "c", "a"])
        XCTAssertEqual(player.currentItem?.id, "a", "The playing track is followed, not the slot")
        XCTAssertEqual(player.currentIndex, 2)
    }

    func testMovingAroundTheCurrentTrackShiftsItsIndex() {
        let player = makePlayer()
        play(player, ["a", "b", "c"])
        player.play(atQueueIndex: 2)

        player.moveQueue(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(ids(player), ["b", "c", "a"])
        XCTAssertEqual(player.currentItem?.id, "c")
        XCTAssertEqual(player.currentIndex, 1)
    }

    // MARK: - Clearing

    func testClearQueueResetsEveryPieceOfPlaybackState() {
        let player = makePlayer()
        play(player, ["a", "b"])
        player.toggleShuffle()
        player.repeatMode = .repeatAll

        player.clearQueue()

        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentIndex)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isShuffled)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertNil(player.errorMessage)
        XCTAssertFalse(player.hasQueue)
    }

    func testClearUpcomingOnAnEmptyQueueIsHarmless() {
        let player = makePlayer()

        player.clearUpcoming()

        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentIndex)
    }

    // MARK: - Queue additions

    func testAddToQueueStartsPlaybackWhenNothingIsQueued() {
        let player = makePlayer()

        player.addToQueue([TestFixtures.item(id: "a")])

        XCTAssertEqual(ids(player), ["a"])
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testAddToQueueAppendsWithoutDisturbingTheCurrentTrack() {
        let player = makePlayer()
        play(player, ["a", "b"])

        player.addToQueue([TestFixtures.item(id: "c")])

        XCTAssertEqual(ids(player), ["a", "b", "c"])
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.currentItem?.id, "a")
    }

    func testAddToQueueDropsNonAudioItems() {
        let player = makePlayer()
        play(player, ["a"])

        player.addToQueue([TestFixtures.item(id: "album", type: .musicAlbum)])

        XCTAssertEqual(ids(player), ["a"])
    }

    /// Two `playNext` calls in a row should queue up in the order they were
    /// made, not reverse it.
    func testRepeatedPlayNextKeepsTheRequestedOrder() {
        let player = makePlayer()
        play(player, ["a", "z"])

        player.playNext(TestFixtures.item(id: "first"))
        player.playNext(TestFixtures.item(id: "second"))

        XCTAssertEqual(ids(player), ["a", "second", "first", "z"])
    }
}

/// Mapping of `AVFoundation` / HTTP failures onto the message shown in the
/// "Playback Problem" alert.
final class PlaybackFailureMessageTests: XCTestCase {
    func testHTTPStatusIsExplainedInPlainLanguage() {
        let reason = PlayerController.reason(from: nil, statusCode: 401)

        XCTAssertTrue(reason.contains("401"), reason)
        XCTAssertTrue(reason.contains("session may have expired"), reason)
    }

    func testKnownStatusCodesAllGetAHint() {
        XCTAssertNotNil(PlayerController.httpHint(401))
        XCTAssertNotNil(PlayerController.httpHint(403))
        XCTAssertNotNil(PlayerController.httpHint(404))
        XCTAssertNotNil(PlayerController.httpHint(503))
        XCTAssertNil(PlayerController.httpHint(200))
    }

    func testUnderlyingErrorIsPreferredOverTheWrapper() {
        let underlying = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        let wrapper = NSError(
            domain: AVFoundationErrorDomain,
            code: -11800,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation could not be completed",
                NSUnderlyingErrorKey: underlying,
            ]
        )

        let reason = PlayerController.reason(from: wrapper, statusCode: nil)

        XCTAssertEqual(reason, "The Internet connection appears to be offline.")
    }

    func testAnUnexplainedFailureStillProducesAUsableMessage() {
        let reason = PlayerController.reason(from: nil, statusCode: nil)

        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(reason.contains("couldn’t be played"), reason)
    }

    /// A zero status code means "no HTTP response recorded" and must not be
    /// reported as though the server answered `0`.
    func testAZeroStatusCodeIsNotReportedAsAServerResponse() {
        let reason = PlayerController.reason(from: nil, statusCode: 0)

        XCTAssertFalse(reason.contains("responded 0"), reason)
    }
}
