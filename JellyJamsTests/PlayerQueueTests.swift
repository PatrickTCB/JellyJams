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
    /// Names of the `UserDefaults` suites the Infinite Queue tests create,
    /// removed on the way out so a flipped preference never leaks into the
    /// next run.
    private var defaultsSuites: [String] = []

    override func tearDown() {
        URLProtocolStub.handler = nil
        URLProtocolStub.responseDelay = nil
        for suite in defaultsSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        defaultsSuites = []
        retainedPreferences = []
        super.tearDown()
    }

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

    // MARK: - Visible history

    func testTheQueueShowsEverythingUntilMoreThanTwoTracksHavePlayed() {
        let player = makePlayer()
        player.play(["a", "b", "c", "d"].map { TestFixtures.item(id: $0) }, startAt: 2)

        XCTAssertEqual(player.visibleQueueStartIndex, 0)
    }

    /// Playing the fourth track hides the first; it stays queued so Previous
    /// and Repeat All can still reach it.
    func testOnlyTheTwoMostRecentlyPlayedTracksStayVisible() {
        let player = makePlayer()
        let trackIds = (1 ... 10).map { "t\($0)" }
        play(player, trackIds)

        player.play(atQueueIndex: 3)

        XCTAssertEqual(player.visibleQueueStartIndex, 1)
        XCTAssertEqual(ids(player), trackIds, "Hidden tracks remain in the queue")
    }

    func testTheWholeQueueIsVisibleWhenNothingIsPlaying() {
        let player = makePlayer()

        XCTAssertEqual(player.visibleQueueStartIndex, 0)
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
        XCTAssertEqual(player.clock.currentTime, 0)
        XCTAssertEqual(player.clock.duration, 0)
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

    // MARK: - Infinite Queue: reading the listen

    /// A queue entry carrying the album attribution and position the
    /// album-in-order detection reads.
    private func albumTrack(_ id: String, albumID: String?, disc: Int? = nil, track: Int?) -> QueueEntry {
        var item = TestFixtures.item(id: id)
        item.albumID = albumID
        item.parentIndexNumber = disc
        item.indexNumber = track
        return QueueEntry(item: item)
    }

    private func detect(_ queue: [QueueEntry], at index: Int, isShuffled: Bool = false) -> QueueExtensionPlan {
        QueueExtensionPlan.detect(queue: queue, currentIndex: index, isShuffled: isShuffled)
    }

    func testAnAlbumRunToTheEndOfTheQueueExtendsByAlbum() {
        let queue = (1 ... 5).map { albumTrack("a\($0)", albumID: "album-a", track: $0) }

        XCTAssertEqual(detect(queue, at: 2), .album(id: "album-a"))
    }

    /// Starting mid-album — or queueing an album behind other songs — is
    /// still an album listen: the run may begin anywhere, as long as it is in
    /// order and the queue ends with it.
    func testAMidAlbumStartStillCountsAsAnAlbumListen() {
        let queue = [albumTrack("x", albumID: "album-b", track: 4)]
            + (3 ... 5).map { albumTrack("a\($0)", albumID: "album-a", track: $0) }

        XCTAssertEqual(detect(queue, at: 1), .album(id: "album-a"))
    }

    /// A foreign track ahead means the appended album would land mid-listen
    /// rather than at its seam, so the queue falls back to alchemy.
    func testAForeignTrackAheadFallsBackToAlchemy() {
        let queue = [
            albumTrack("a1", albumID: "album-a", track: 1),
            albumTrack("a2", albumID: "album-a", track: 2),
            albumTrack("x", albumID: "album-b", track: 1),
        ]

        XCTAssertEqual(detect(queue, at: 0), .general)
    }

    func testAnAlbumRunThatStopsShortOfTheQueueEndFallsBack() {
        let queue = [
            albumTrack("a1", albumID: "album-a", track: 1),
            albumTrack("a2", albumID: "album-a", track: 2),
            albumTrack("s", albumID: nil, track: nil),
        ]

        XCTAssertEqual(detect(queue, at: 0), .general)
    }

    /// Track 2 never arrived: the expected tracks are not all there, so this
    /// is a handful of songs, not an album in order.
    func testAGapInTheTrackNumbersFallsBackToAlchemy() {
        let queue = [
            albumTrack("a1", albumID: "album-a", track: 1),
            albumTrack("a3", albumID: "album-a", track: 3),
        ]

        XCTAssertEqual(detect(queue, at: 0), .general)
    }

    /// Looking back matters as much as looking forward: the same album
    /// behind the current track, but out of order, is not an album listen.
    func testAnOutOfOrderAlbumBehindFallsBackToAlchemy() {
        let queue = [
            albumTrack("a1", albumID: "album-a", track: 1),
            albumTrack("a3", albumID: "album-a", track: 3),
            albumTrack("a4", albumID: "album-a", track: 4),
        ]

        XCTAssertEqual(detect(queue, at: 1), .general)
    }

    /// One song from an album proves a song choice, not an album listen —
    /// there is no order to observe in a single item.
    func testALoneAlbumTrackIsASongChoiceNotAnAlbumListen() {
        let queue = [
            albumTrack("x", albumID: "album-b", track: 2),
            albumTrack("a5", albumID: "album-a", track: 5),
        ]

        XCTAssertEqual(detect(queue, at: 1), .general)
    }

    func testAShuffledQueueNeverExtendsByAlbum() {
        let queue = (1 ... 5).map { albumTrack("a\($0)", albumID: "album-a", track: $0) }

        XCTAssertEqual(detect(queue, at: 2, isShuffled: true), .general)
    }

    /// A disc boundary is the expected order continuing, not breaking: the
    /// first track of the next disc follows the last of this one.
    func testDiscBoundariesContinueTheAlbumRun() {
        let queue = [
            albumTrack("d1t2", albumID: "album-a", disc: 1, track: 2),
            albumTrack("d1t3", albumID: "album-a", disc: 1, track: 3),
            albumTrack("d2t1", albumID: "album-a", disc: 2, track: 1),
            albumTrack("d2t2", albumID: "album-a", disc: 2, track: 2),
        ]

        XCTAssertEqual(detect(queue, at: 1), .album(id: "album-a"))
    }

    /// Tracks without numbers cannot confirm an expected order, whichever
    /// side of the run they sit on.
    func testMissingTrackNumbersCannotProveAnOrder() {
        let unnumbered = [
            albumTrack("a1", albumID: "album-a", track: nil),
            albumTrack("a2", albumID: "album-a", track: nil),
        ]
        XCTAssertEqual(detect(unnumbered, at: 0), .general)

        let currentUnnumbered = [
            albumTrack("a?", albumID: "album-a", track: nil),
            albumTrack("a2", albumID: "album-a", track: 2),
        ]
        XCTAssertEqual(detect(currentUnnumbered, at: 0), .general)
    }

    func testTracksWithoutAnAlbumExtendByAlchemy() {
        let queue = (1 ... 4).map { albumTrack("s\($0)", albumID: nil, track: nil) }

        XCTAssertEqual(detect(queue, at: 1), .general)
    }

    // MARK: - Infinite Queue: topping the queue up

    /// Unlike the offline-client tests above, these run against the stubbed
    /// loader: the backend picks the new track ids, the Jellyfin server
    /// resolves them, and `AVPlayer`'s probes of the stream URL are answered
    /// with an empty 200 — the item fails harmlessly and the queue
    /// bookkeeping, which is what these tests read, runs exactly as in the app.
    ///
    /// The controller holds preferences weakly — in the app the service graph
    /// keeps them alive — so the test keeps the strong reference here.
    private var retainedPreferences: [PreferencesStore] = []

    private func makePreferences(infiniteQueueEnabled: Bool) -> PreferencesStore {
        let suite = "PlayerQueueTests.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(infiniteQueueEnabled, forKey: "infiniteQueueEnabled")
        let store = PreferencesStore(defaults: defaults)
        retainedPreferences.append(store)
        return store
    }

    private func makeExtender(registered: Bool = true) -> QueueExtender {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let extender = QueueExtender()
        extender.configure(
            userID: "user-id",
            address: "https://backend.example.com",
            registered: registered,
            deviceInfo: TestFixtures.deviceInfo,
            sessionConfiguration: configuration
        )
        return extender
    }

    /// The handler runs on the URL loading system's own threads, so it is
    /// built `nonisolated`: a closure formed in the MainActor test context
    /// would carry that isolation into the loader and trap the host the
    /// moment a request arrived.
    private nonisolated func stubExtension(newTrackIDs: [String], recorder: RequestRecorder, backendDelay: TimeInterval = 0) {
        URLProtocolStub.responseDelay = backendDelay > 0
            ? { request in request.url?.host == "backend.example.com" ? backendDelay : 0 }
            : nil
        URLProtocolStub.handler = { request in
            let recorded = RecordedRequest(request)
            let response = try emptyResponse(for: request, statusCode: 200)
            if request.url?.host == "backend.example.com" {
                recorder.record(request)
                let ids = newTrackIDs.map { "\"\($0)\"" }.joined(separator: ",")
                return (response, Data(#"{"NewTrackIDs":[\#(ids)],"Count":\#(newTrackIDs.count)}"#.utf8))
            }
            let ids = recorded.values(for: "ids")
            if !ids.isEmpty {
                return (response, itemsPayload(ids.map { (id: $0, type: "Audio") }))
            }
            return (response, emptyItemsPayload)
        }
    }

    private func makeInfinitePlayer(preferences: PreferencesStore, extender: QueueExtender) -> PlayerController {
        let player = PlayerController()
        player.configure(client: TestFixtures.stubbedClient())
        player.configure(preferences: preferences)
        player.configure(queueExtender: extender)
        return player
    }

    private func waitForQueueCount(_ player: PlayerController, _ count: Int) async throws {
        for _ in 0 ..< 500 {
            if player.queue.count == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The queue never reached \(count) tracks (has \(player.queue.count))")
    }

    /// The alchemy path: a queue of plain songs runs short, the whole queue
    /// seeds `/extend-queue`, and the picked tracks land at the end in the
    /// order the backend sent them.
    func testInfiniteQueueAppendsAlchemyTracksWhenTheQueueRunsShort() async throws {
        let recorder = RequestRecorder()
        stubExtension(newTrackIDs: ["x1", "x2"], recorder: recorder)
        let player = makeInfinitePlayer(
            preferences: makePreferences(infiniteQueueEnabled: true),
            extender: makeExtender()
        )

        player.play((1 ... 6).map { TestFixtures.item(id: "s\($0)") }, startAt: 2)

        try await waitForQueueCount(player, 8)
        XCTAssertEqual(Array(ids(player).suffix(2)), ["x1", "x2"])
        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.path, "/extend-queue")
        XCTAssertEqual(request.value(for: "userID"), "user-id")
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: request.body),
            ["s1", "s2", "s3", "s4", "s5", "s6"]
        )
    }

    /// The album path: an in-order album listen about to run off its end
    /// asks `/extend-queue-by-album` for the album the backend picks next.
    func testInfiniteQueueContinuesWithTheNextAlbumDuringAnAlbumListen() async throws {
        let recorder = RequestRecorder()
        stubExtension(newTrackIDs: ["b1", "b2", "b3"], recorder: recorder)
        let player = makeInfinitePlayer(
            preferences: makePreferences(infiniteQueueEnabled: true),
            extender: makeExtender()
        )

        player.play((1 ... 6).map { albumTrack("a\($0)", albumID: "album-a", track: $0).item }, startAt: 3)

        try await waitForQueueCount(player, 9)
        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.path, "/extend-queue-by-album")
        XCTAssertEqual(request.value(for: "userID"), "user-id")
        XCTAssertEqual(request.value(for: "currentAlbumID"), "album-a")
    }

    /// Four or more tracks still to come is not "running short": no request,
    /// and no growth, until the listener gets within three of the end.
    func testInfiniteQueueWaitsUntilThreeTracksRemain() async throws {
        let recorder = RequestRecorder()
        stubExtension(newTrackIDs: ["x1", "x2"], recorder: recorder)
        let player = makeInfinitePlayer(
            preferences: makePreferences(infiniteQueueEnabled: true),
            extender: makeExtender()
        )

        player.play((1 ... 8).map { TestFixtures.item(id: "s\($0)") }, startAt: 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.queue.count, 8)
        XCTAssertTrue(recorder.all.isEmpty)

        player.play(atQueueIndex: 4)
        try await waitForQueueCount(player, 10)
        XCTAssertEqual(recorder.count(forPath: "/extend-queue"), 1)
    }

    func testInfiniteQueueStaysQuietWhileTheToggleIsOff() async throws {
        let recorder = RequestRecorder()
        stubExtension(newTrackIDs: ["x1"], recorder: recorder)
        let player = makeInfinitePlayer(
            preferences: makePreferences(infiniteQueueEnabled: false),
            extender: makeExtender()
        )

        player.play((1 ... 4).map { TestFixtures.item(id: "s\($0)") }, startAt: 2)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.queue.count, 4)
        XCTAssertTrue(recorder.all.isEmpty)
    }

    /// The toggle is the same preference the player's infinity button edits;
    /// flipping it mid-listen tops the queue up right away rather than
    /// waiting for a track change that — on the last track — never comes.
    func testTurningInfiniteQueueOnExtendsAShortQueueRightAway() async throws {
        let recorder = RequestRecorder()
        stubExtension(newTrackIDs: ["x1", "x2"], recorder: recorder)
        let preferences = makePreferences(infiniteQueueEnabled: false)
        let player = makeInfinitePlayer(preferences: preferences, extender: makeExtender())
        player.play((1 ... 4).map { TestFixtures.item(id: "s\($0)") }, startAt: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(player.queue.count, 4)

        preferences.infiniteQueueEnabled = true

        try await waitForQueueCount(player, 6)
    }

    /// The backend extends for accounts it knows: an address nobody
    /// registered has no `userID` to ask for, so nothing is sent at all.
    func testAnUnregisteredBackendNeverExtends() async throws {
        let recorder = RequestRecorder()
        stubExtension(newTrackIDs: ["x1"], recorder: recorder)
        let player = makeInfinitePlayer(
            preferences: makePreferences(infiniteQueueEnabled: true),
            extender: makeExtender(registered: false)
        )

        player.play((1 ... 4).map { TestFixtures.item(id: "s\($0)") }, startAt: 2)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.queue.count, 4)
        XCTAssertTrue(recorder.all.isEmpty)
    }

    /// Alchemy seeded from the queue can echo the queue back; a song already
    /// queued is not a new one.
    func testTracksAlreadyInTheQueueAreNotAppendedAgain() async throws {
        let recorder = RequestRecorder()
        stubExtension(newTrackIDs: ["s5", "x1"], recorder: recorder)
        let player = makeInfinitePlayer(
            preferences: makePreferences(infiniteQueueEnabled: true),
            extender: makeExtender()
        )

        player.play((1 ... 6).map { TestFixtures.item(id: "s\($0)") }, startAt: 2)

        try await waitForQueueCount(player, 7)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ids(player), ["s1", "s2", "s3", "s4", "s5", "s6", "x1"])
    }

    /// A clear while the request is in flight means those tracks were picked
    /// for a listen that no longer exists: appending them would resurrect the
    /// queue the listener just emptied — and, worse, start it playing.
    func testAnExtensionForAClearedQueueIsDiscarded() async throws {
        let recorder = RequestRecorder()
        stubExtension(newTrackIDs: ["x1", "x2"], recorder: recorder, backendDelay: 0.3)
        let player = makeInfinitePlayer(
            preferences: makePreferences(infiniteQueueEnabled: true),
            extender: makeExtender()
        )

        player.play((1 ... 4).map { TestFixtures.item(id: "s\($0)") }, startAt: 2)
        try await Task.sleep(for: .milliseconds(50))
        player.clearQueue()

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(recorder.count(forPath: "/extend-queue"), 1, "The request was made; its answer was dropped")
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
