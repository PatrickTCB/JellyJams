import XCTest
@testable import JellyJams

/// Covers the pin limit, the per-account persistence, and the resolution that
/// marks pins the server no longer answers for — never deleting one without
/// the user's say-so.
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

    private func resolvedItem(ofPin itemId: String, in store: PinnedItemsStore) -> BaseItemDto? {
        guard let state = store.entries.first(where: { $0.pin.itemId == itemId })?.state else {
            return nil
        }
        if case .resolved(let item) = state { return item }
        return nil
    }

    private func isMissing(_ itemId: String, in store: PinnedItemsStore) -> Bool {
        guard let state = store.entries.first(where: { $0.pin.itemId == itemId })?.state else {
            return false
        }
        if case .missing = state { return true }
        return false
    }

    private func isUnresolved(_ itemId: String, in store: PinnedItemsStore) -> Bool {
        guard let state = store.entries.first(where: { $0.pin.itemId == itemId })?.state else {
            return false
        }
        if case .unresolved = state { return true }
        return false
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
        XCTAssertEqual(resolvedItem(ofPin: "album-1", in: store)?.id, "album-1")
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

    /// A reloaded store has not asked the server anything yet, so its pins
    /// show as unresolved entries built from the stored names — the row is
    /// visible from launch whatever the network is doing.
    func testReloadedPinsStartUnresolved() {
        makeStore().pin(album("album-1"), kind: .album)

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.entries.map(\.pin.itemId), ["album-1"])
        XCTAssertTrue(isUnresolved("album-1", in: reloaded))
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

        stubItems([("album-2", "MusicAlbum"), ("album-1", "MusicAlbum")])

        await store.refresh(using: TestFixtures.stubbedRepository())

        XCTAssertEqual(store.entries.map(\.pin.itemId), ["album-1", "album-2"])
        XCTAssertEqual(resolvedItem(ofPin: "album-1", in: store)?.id, "album-1")
        XCTAssertEqual(resolvedItem(ofPin: "album-2", in: store)?.id, "album-2")
    }

    /// An id the server no longer returns marks the pin missing, in memory
    /// and nowhere else: the pin stays, because one answer is not trusted
    /// with a deletion. Removal is the user's call.
    func testRefreshMarksGonePinsMissingInsteadOfDeletingThem() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)
        store.pin(album("album-2"), kind: .album)

        stubItems([("album-2", "MusicAlbum")])

        await store.refresh(using: TestFixtures.stubbedRepository())

        XCTAssertEqual(store.pins.map(\.itemId), ["album-1", "album-2"])
        XCTAssertTrue(isMissing("album-1", in: store))
        XCTAssertEqual(resolvedItem(ofPin: "album-2", in: store)?.id, "album-2")
        XCTAssertEqual(makeStore().pins.map(\.itemId), ["album-1", "album-2"])
    }

    /// A pin answered with a different kind of item no longer points at what
    /// the user pinned, so it is missing too.
    func testRefreshMarksAPinMissingWhenTheKindChanges() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)

        stubItems([("album-1", "MusicArtist")])

        await store.refresh(using: TestFixtures.stubbedRepository())

        XCTAssertTrue(isMissing("album-1", in: store))
        XCTAssertEqual(store.pins.map(\.itemId), ["album-1"])
    }

    /// A failed request is not evidence the item is gone, so nothing changes:
    /// the entries keep the state they had — resolved for a pin just pinned —
    /// and the error waits for a later retry.
    func testRefreshKeepsPinsWhenTheRequestFails() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)

        await store.refresh(using: TestFixtures.signedOutRepository())

        XCTAssertEqual(store.pins.map(\.itemId), ["album-1"])
        XCTAssertEqual(store.entries.map(\.pin.itemId), ["album-1"])
        XCTAssertEqual(resolvedItem(ofPin: "album-1", in: store)?.id, "album-1")
        XCTAssertNotNil(store.errorMessage)
    }

    // MARK: - Use

    /// The tap on a pin the server still has: the outcome carries the item and
    /// the entry is upgraded in place.
    func testUseResolvesAPinTheServerStillHas() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)
        stubItems([("album-1", "MusicAlbum")])

        let outcome = await store.use(store.entries[0], using: TestFixtures.stubbedRepository())

        if case .resolved(let item) = outcome {
            XCTAssertEqual(item.id, "album-1")
        } else {
            XCTFail("Expected a resolved item, got \(outcome)")
        }
        XCTAssertEqual(resolvedItem(ofPin: "album-1", in: store)?.id, "album-1")
    }

    /// The tap on a pin the server no longer has: the outcome says missing and
    /// the pin is marked, kept, and still stored for the next ask.
    func testUseMarksAPinMissingWhenTheServerNoLongerHasIt() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)
        stubItems([])

        let outcome = await store.use(store.entries[0], using: TestFixtures.stubbedRepository())

        if case .missing = outcome {} else {
            XCTFail("Expected missing, got \(outcome)")
        }
        XCTAssertTrue(isMissing("album-1", in: store))
        XCTAssertEqual(store.pins.map(\.itemId), ["album-1"])
        XCTAssertEqual(makeStore().pins.map(\.itemId), ["album-1"])
    }

    /// A failed lookup is not evidence the item is gone: the pin is kept in
    /// whatever state it was, and the caller gets a message to present.
    func testUseKeepsAPinWhenTheRequestFails() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)

        let outcome = await store.use(store.entries[0], using: TestFixtures.signedOutRepository())

        if case .unavailable(let message) = outcome {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected an unavailable outcome, got \(outcome)")
        }
        XCTAssertEqual(store.pins.map(\.itemId), ["album-1"])
        XCTAssertEqual(resolvedItem(ofPin: "album-1", in: store)?.id, "album-1")
    }

    /// Asking again can bring a missing pin back: an id that returns is
    /// upgraded to resolved and handed to the caller.
    func testUseRevivesAMissingPinWhenTheItemReturns() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)
        stubItems([])
        await store.refresh(using: TestFixtures.stubbedRepository())
        XCTAssertTrue(isMissing("album-1", in: store))

        stubItems([("album-1", "MusicAlbum")])
        let outcome = await store.use(store.entries[0], using: TestFixtures.stubbedRepository())

        if case .resolved(let item) = outcome {
            XCTAssertEqual(item.id, "album-1")
        } else {
            XCTFail("Expected a resolved item, got \(outcome)")
        }
        XCTAssertEqual(resolvedItem(ofPin: "album-1", in: store)?.id, "album-1")
    }

    /// The "oops" path: a pin can be unpinned by itself, without an item to
    /// pass, and the removal is persisted.
    func testUnpinningAServerGonePinByItselfRemovesIt() async {
        let store = makeStore()
        store.pin(album("album-1"), kind: .album)
        stubItems([])
        await store.refresh(using: TestFixtures.stubbedRepository())

        store.unpin(store.pins[0])

        XCTAssertTrue(store.pins.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(makeStore().pins.isEmpty)
    }

    /// `nonisolated` because `URLProtocolStub` runs its handler on the URL
    /// loading thread, not the main actor this test class is isolated to.
    nonisolated private func stubItems(_ items: [(id: String, type: String)]) {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200), itemsPayload(items))
        }
    }
}