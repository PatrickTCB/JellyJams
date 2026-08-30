import XCTest
@testable import JellyJams

@MainActor
final class PlayerControllerTests: XCTestCase {
    func testDuplicateTracksKeepDistinctQueueIdentity() {
        let player = PlayerController()
        let track = TestFixtures.item(id: "duplicate-track")

        player.addToQueue([track, track])

        XCTAssertEqual(player.queue.compactMap(\.item.id), ["duplicate-track", "duplicate-track"])
        XCTAssertNotEqual(player.queue[0].id, player.queue[1].id)

        player.removeFromQueue(atOffsets: IndexSet(integer: 0))

        XCTAssertEqual(player.queue.count, 1)
        XCTAssertEqual(player.queue[0].item.id, "duplicate-track")
    }

    func testPlayNextInsertsWholeCollectionAfterCurrentTrackInOrder() {
        let player = PlayerController()
        player.configure(client: TestFixtures.offlineClient())
        player.play([TestFixtures.item(id: "a"), TestFixtures.item(id: "b")])
        XCTAssertEqual(player.currentIndex, 0)

        player.playNext([TestFixtures.item(id: "x"), TestFixtures.item(id: "y")])

        XCTAssertEqual(player.queue.compactMap(\.item.id), ["a", "x", "y", "b"])
    }

    func testPlayNextStartsPlaybackWhenTheQueueIsEmpty() {
        let player = PlayerController()
        player.configure(client: TestFixtures.offlineClient())

        player.playNext([TestFixtures.item(id: "a"), TestFixtures.item(id: "b")])

        XCTAssertEqual(player.queue.compactMap(\.item.id), ["a", "b"])
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testPlayNextIgnoresNonAudioItems() {
        let player = PlayerController()
        player.configure(client: TestFixtures.offlineClient())
        player.play([TestFixtures.item(id: "a")])

        player.playNext([TestFixtures.item(id: "album", type: .musicAlbum)])

        XCTAssertEqual(player.queue.compactMap(\.item.id), ["a"])
    }

    func testClearUpcomingRemovesTracksAfterCurrentAndKeepsPlaying() {
        let player = PlayerController()
        player.configure(client: TestFixtures.offlineClient())
        player.play([
            TestFixtures.item(id: "a"),
            TestFixtures.item(id: "b"),
            TestFixtures.item(id: "c"),
            TestFixtures.item(id: "d"),
        ])
        player.play(atQueueIndex: 1)
        XCTAssertEqual(player.currentIndex, 1)

        player.clearUpcoming()

        XCTAssertEqual(player.queue.compactMap(\.item.id), ["a", "b"])
        XCTAssertEqual(player.currentIndex, 1)
    }

    func testClearUpcomingClearsWholeQueueWhenCurrentIsLast() {
        let player = PlayerController()
        player.configure(client: TestFixtures.offlineClient())
        player.play([TestFixtures.item(id: "a"), TestFixtures.item(id: "b")])
        player.play(atQueueIndex: 1)
        XCTAssertEqual(player.currentIndex, 1)

        player.clearUpcoming()

        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentIndex)
    }
}
