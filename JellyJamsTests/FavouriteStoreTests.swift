import Foundation
import XCTest
@testable import JellyJams

@MainActor
final class FavouriteStoreTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        URLProtocolStub.responseDelay = nil
        super.tearDown()
    }

    func testAnUntouchedItemReportsTheSnapshotItArrivedWith() {
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())

        XCTAssertTrue(store.isFavourite(favouritedItem(id: "a")))
        XCTAssertFalse(store.isFavourite(TestFixtures.item(id: "b")))
    }

    func testTogglingIsVisibleBeforeTheServerAnswers() async throws {
        stubWrites()
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = TestFixtures.item(id: "a")

        store.toggle(track)

        XCTAssertTrue(store.isFavourite(track), "The heart must fill on tap, not on response")
        XCTAssertTrue(store.isBusy(track))

        // Let the write land before the stub is torn down, so it can't be
        // recorded against a later test's handler.
        try await waitForWrites(store, item: track)
    }

    /// The regression this store exists for. A grid cell that scrolls off
    /// screen is rebuilt from the item it was handed, whose snapshot still says
    /// "not favourited" — the heart used to empty itself.
    func testAChangeSurvivesTheItemBeingRebuiltFromItsOriginalSnapshot() async throws {
        stubWrites()
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let onScreen = TestFixtures.item(id: "album")

        store.toggle(onScreen)
        try await waitForWrites(store, item: onScreen)

        let rebuilt = TestFixtures.item(id: "album")
        XCTAssertTrue(store.isFavourite(rebuilt))
    }

    /// The same track reaches the screen through several unrelated requests.
    /// Favouriting it in one place has to show everywhere.
    func testTheSameItemFetchedTwoWaysAgrees() async throws {
        stubWrites()
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let fromSongsList = TestFixtures.item(id: "song", name: "Song")
        let fromSearch = TestFixtures.item(id: "song", name: "Song")

        store.toggle(fromSongsList)
        try await waitForWrites(store, item: fromSongsList)

        XCTAssertTrue(store.isFavourite(fromSearch))
    }

    func testUnfavouritingAnItemTheServerSaysIsFavourited() async throws {
        let recorder = stubWrites()
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = favouritedItem(id: "a")

        store.toggle(track)
        try await waitForWrites(store, item: track)

        XCTAssertFalse(store.isFavourite(track))
        XCTAssertEqual(recorder.all.map(\.method), ["DELETE"])
    }

    func testFavouritingSendsAWriteForThatItem() async throws {
        let recorder = stubWrites()
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = TestFixtures.item(id: "a")

        store.toggle(track)
        try await waitForWrites(store, item: track)

        XCTAssertEqual(recorder.all.map(\.method), ["POST"])
        XCTAssertEqual(recorder.all.first?.path, "/jellyfin/UserFavoriteItems/a")
    }

    func testAFailedWriteRestoresTheStateAndReportsWhy() async throws {
        stubWrites(statusCode: 500)
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = TestFixtures.item(id: "a")

        store.toggle(track)
        XCTAssertTrue(store.isFavourite(track))
        try await waitForWrites(store, item: track)

        XCTAssertFalse(store.isFavourite(track), "An unsent change must not be left on screen")
        XCTAssertNotNil(store.errorMessage)
    }

    /// Rolling back has to restore the previous entry, not just write `false`:
    /// an item the user favourited earlier and failed to unfavourite now must
    /// stay favourited.
    func testAFailedWriteRestoresTheEarlierChangeRatherThanTheSnapshot() async throws {
        stubWrites()
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = TestFixtures.item(id: "a")
        store.toggle(track)
        try await waitForWrites(store, item: track)
        XCTAssertTrue(store.isFavourite(track))

        stubWrites(statusCode: 500)
        store.toggle(track)
        try await waitForWrites(store, item: track)

        XCTAssertTrue(store.isFavourite(track))
    }

    /// Two affordances for the same item used to hold the value and the
    /// in-flight guard separately, so a second tap could clobber the first.
    func testASecondTapIsIgnoredWhileTheFirstWriteIsInFlight() async throws {
        let recorder = stubWrites()
        URLProtocolStub.responseDelay = { _ in 0.15 }
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = TestFixtures.item(id: "a")

        store.toggle(track)
        store.toggle(track)
        store.toggle(track)
        try await waitForWrites(store, item: track)

        XCTAssertEqual(recorder.all.count, 1)
        XCTAssertTrue(store.isFavourite(track))
    }

    func testSignOutDiscardsTheChangesMadeByThatAccount() async throws {
        stubWrites()
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let track = TestFixtures.item(id: "a")
        store.toggle(track)
        try await waitForWrites(store, item: track)

        store.configure(client: nil)

        XCTAssertFalse(store.isFavourite(track))
        XCTAssertNil(store.errorMessage)
    }

    func testReconfiguringWithTheSameClientKeepsTheChanges() async throws {
        stubWrites()
        let client = TestFixtures.stubbedClient()
        let store = FavouriteStore()
        store.configure(client: client)
        let track = TestFixtures.item(id: "a")
        store.toggle(track)
        try await waitForWrites(store, item: track)

        store.configure(client: client)

        XCTAssertTrue(store.isFavourite(track), "A redundant configure must not wipe session state")
    }

    func testTogglingWhileSignedOutReportsInsteadOfFailingSilently() {
        let store = FavouriteStore()

        store.toggle(TestFixtures.item(id: "a"))

        XCTAssertEqual(store.errorMessage, JellyfinError.notAuthenticated.errorDescription)
        XCTAssertFalse(store.isFavourite(TestFixtures.item(id: "a")))
    }

    func testAnItemWithNoIdentifierCannotBeFavourited() {
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let anonymous = BaseItemDto(name: "No id", type: .audio)

        store.toggle(anonymous)

        XCTAssertEqual(store.errorMessage, JellyfinError.missingItemIdentifier.errorDescription)
        XCTAssertFalse(store.isBusy(anonymous))
    }

    func testDismissingTheErrorClearsIt() {
        let store = FavouriteStore()
        store.toggle(TestFixtures.item(id: "a"))
        XCTAssertNotNil(store.errorMessage)

        store.dismissError()

        XCTAssertNil(store.errorMessage)
    }

    func testChangesToOneItemDoNotAffectAnother() async throws {
        stubWrites()
        let store = FavouriteStore()
        store.configure(client: TestFixtures.stubbedClient())
        let first = TestFixtures.item(id: "a")
        let second = TestFixtures.item(id: "b")

        store.toggle(first)
        try await waitForWrites(store, item: first)

        XCTAssertTrue(store.isFavourite(first))
        XCTAssertFalse(store.isFavourite(second))
        XCTAssertFalse(store.isBusy(second))
    }

    // MARK: - Helpers

    private func favouritedItem(id: String) -> BaseItemDto {
        TestFixtures.item(id: id, isFavourite: true)
    }

    @discardableResult
    private func stubWrites(statusCode: Int = 200) -> RequestRecorder {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: statusCode), Data(#"{"Key":"k"}"#.utf8))
        }
        return recorder
    }

    private func waitForWrites(
        _ store: FavouriteStore,
        item: BaseItemDto,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 400 {
            if !store.isBusy(item) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Favourite write never finished", file: file, line: line)
    }
}
