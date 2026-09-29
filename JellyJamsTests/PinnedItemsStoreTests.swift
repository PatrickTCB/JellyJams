import XCTest
@testable import JellyJams

/// Covers the pin limit, the per-account persistence, and the pruning of pins
/// the server no longer answers for.
@MainActor
final class PinnedItemsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard
    private let account = "https://example.com/jellyfin#user-id"

    override func setUp() async throws {
        suiteName = "PinnedItemsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        URLProtocolStub.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore(_ accountKey: String? = nil) -> PinnedItemsStore {
        let store = PinnedItemsStore(defaults: defaults)
        store.configure(accountKey: accountKey ?? account)
        return store
    }

    private func album(_ id: String) -> BaseItemDto {
        TestFixtures.item(id: id, type: .musicAlbum)
    }

    // MARK: - Pinning

    func testNothingIsPinnedBeforeTheUserPinsIt() {
        let store = makeStore()

        XCTAssertTrue(store.pins.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.isFull)
    }

    func testPinningPublishesTheItemImmediately() {
        let store = makeStore()
        let item = album("album-1")

        XCTAssertTrue(store.pin(item, kind: .album))

        XCTAssertTrue(store.contains(item))
        XCTAssertEqual(store.pins.map(\.itemId), ["album-1"])
        XCTAssertEqual(store.entries.map(\.item.id), ["album-1"])
    }

    func testAnItemCannotBePinnedTwice() {
        let store = makeStore()
        let item = album("album-1")

        store.pin(item, kind: .album)

        XCTAssertFalse(store.pin(item, kind: .album))
        XCTAssertEqual(store.pins.count, 1)
    }

    func testTheSixthPinIsRefused() {
        let store = makeStore()
        for index in 0 ..< PinnedItemsStore.maxPins {
            XCTAssertTrue(store.pin(album("album-\(index)"), kind: .album))
        }

        XCTAssertTrue(store.isFull)
        XCTAssertFalse(store.pin(album("album-6"), kind: .album))
        XCTAssertEqual(store.pins.count, PinnedItemsStore.maxPins)
    }

    func testAnItemWithNoIdentifierIsRefused() {
        let store = makeStore()

        XCTAssertFalse(store.pin(BaseItemDto(type: .musicAlbum), kind: .album))
        XCTAssertTrue(store.pins.isEmpty)
    }

    func testUnpinningRemovesTheItem() {
        let store = makeStore()
        let item = album("album-1")
        store.pin(item, kind: .album)

        store.unpin(item)

        XCTAssertTrue(store.pins.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.contains(item))
    }

    /// The kind comes from the item type, and only the three collection kinds
    /// can be pinned.
    func testOnlyAlbumsArtistsAndPlaylistsCanBePinned() {
        let store = makeStore()

        XCTAssertEqual(store.kind(for: TestFixtures.item(id: "a", type: .musicAlbum)), .album)
        XCTAssertEqual(store.kind(for: TestFixtures.item(id: "b", type: .musicArtist)), .artist)
        XCTAssertEqual(store.kind(for: TestFixtures.item(id: "c", type: .playlist)), .playlist)
        XCTAssertNil(store.kind(for: TestFixtures.item(id: "d", type: .audio)))
        XCTAssertNil(store.kind(for: TestFixtures.item(id: "e", type: .musicGenre)))
    }

    // MARK: - Persistence

    func testPinsSurviveANewStoreForTheSameAccount() {
        makeStore().pin(album("album-1"), kind: .album)

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.pins.map(\.itemId), ["album-1"])
        XCTAssertEqual(reloaded.pins.first?.kind, .album)
    }

    func testUnpinningSurvivesANewStore() {
        let store = makeStore()
        let item = album("album-1")
        store.pin(item, kind: .album)
        store.unpin(item)

        XCTAssertTrue(makeStore().pins.isEmpty)
    }

    /// A pin names an item on one server, so another account must not see it,
    /// and its own pins must come back when it signs in again.
    func testPinsAreKeptApartPerAccount() {
        makeStore("https://one.example/jellyfin#user-1").pin(album("album-1"), kind: .album)

        let second = makeStore("https://two.example/jellyfin#user-2")
        XCTAssertTrue(second.pins.isEmpty)
        second.pin(album("album-2"), kind: .album)

        XCTAssertEqual(makeStore("https://one.example/jellyfin#user-1").pins.map(\.itemId), ["album-1"])
        XCTAssertEqual(makeStore("https://two.example/jellyfin#user-2").pins.map(\.itemId), ["album-2"])
    }

    func testSigningOutHidesPinsWithoutDeletingThem() {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)

        store.configure(accountKey: nil)
        XCTAssertTrue(store.pins.isEmpty)

        store.configure(accountKey: account)
        XCTAssertEqual(store.pins.map(\.itemId), ["album-1"])
    }

    // MARK: - Resolution

    func testRefreshResolvesPinsInPinOrder() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)
        store.pin(album("album-2"), kind: .album)

        stubItems(["album-2", "album-1"])

        await store.refresh(using: TestFixtures.stubbedRepository())

        XCTAssertEqual(store.entries.map(\.item.id), ["album-1", "album-2"])
    }

    /// An id the server no longer returns is gone for good: the pin is dropped
    /// in memory and in storage.
    func testRefreshPrunesPinsTheServerNoLongerHas() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)
        store.pin(album("album-2"), kind: .album)

        stubItems(["album-2"])

        await store.refresh(using: TestFixtures.stubbedRepository())

        XCTAssertEqual(store.pins.map(\.itemId), ["album-2"])
        XCTAssertEqual(store.entries.map(\.item.id), ["album-2"])
        XCTAssertEqual(makeStore().pins.map(\.itemId), ["album-2"])
    }

    /// A failed request is not evidence the item is gone, so nothing is pruned
    /// and the error waits for a later retry.
    func testRefreshKeepsPinsWhenTheRequestFails() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)

        await store.refresh(using: TestFixtures.signedOutRepository())

        XCTAssertEqual(store.pins.map(\.itemId), ["album-1"])
        XCTAssertNotNil(store.errorMessage)
    }

    /// `nonisolated` because `URLProtocolStub` runs its handler on the URL
    /// loading thread, not the main actor this test class is isolated to.
    nonisolated private func stubItems(_ ids: [String]) {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), itemsPayload(ids.map { ($0, "MusicAlbum") }))
        }
    }
}