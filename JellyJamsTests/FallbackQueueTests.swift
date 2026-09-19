import XCTest
@testable import JellyJams

/// The "play something with nothing named" queue: favourite songs first, a
/// shuffle of everything as the fallback. Drives both the system play command
/// (empty queue + play) and the Siri play intent's favourites entry point.
final class FallbackQueueTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    /// Answers every stubbed request, switching payloads on whether the
    /// request filters to favourites.
    private func installStub(favouriteIds: [String], otherIds: [String]) {
        URLProtocolStub.handler = { request in
            let isFavourites = request.url?.absoluteString.contains("IsFavorite") == true
            let ids = isFavourites ? favouriteIds : otherIds
            let payload = itemsPayload(ids.map { (id: $0, type: "Audio") })
            return (try emptyResponse(for: request, statusCode: 200), payload)
        }
    }

    func testFallbackQueuePrefersFavouriteSongs() async throws {
        installStub(favouriteIds: ["fav-1", "fav-2"], otherIds: ["all-1"])

        let queue = try await PlayerController.fallbackQueue(client: TestFixtures.stubbedClient())

        XCTAssertEqual(Set(queue.compactMap(\.id)), ["fav-1", "fav-2"])
    }

    func testFallbackQueueFallsBackToAllSongsWhenNothingIsFavourited() async throws {
        installStub(favouriteIds: [], otherIds: ["all-1", "all-2"])

        let queue = try await PlayerController.fallbackQueue(client: TestFixtures.stubbedClient())

        XCTAssertEqual(Set(queue.compactMap(\.id)), ["all-1", "all-2"])
    }

    @MainActor
    func testPlayOrResumeResumesTheLoadedTrackInsteadOfStartingTheFallback() {
        let player = PlayerController()
        player.configure(client: TestFixtures.offlineClient())
        player.play([TestFixtures.item(id: "a")])
        player.pause()

        player.playOrResume()

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.queue.count, 1)
    }

    @MainActor
    func testPlayOrResumeStartsAFavouritesShuffleWhenTheQueueIsEmpty() async throws {
        installStub(favouriteIds: ["siri-1", "siri-2"], otherIds: [])
        let player = PlayerController()
        player.configure(client: TestFixtures.stubbedClient())

        player.playOrResume()

        // The queue lands asynchronously once the fetch resolves.
        let deadline = Date().addingTimeInterval(5)
        while player.queue.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(Set(player.queue.compactMap(\.item.id)), ["siri-1", "siri-2"])
        XCTAssertTrue(player.isPlaying)
    }
}
