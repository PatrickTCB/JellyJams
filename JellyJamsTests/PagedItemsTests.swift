import Foundation
import XCTest
@testable import JellyJams

@MainActor
final class PagedItemsTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    // MARK: - Paging

    func testReloadFetchesFirstPageAgain() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        let counter = CallCounter()

        await model.load(model.query) { startIndex, _ in
            XCTAssertEqual(startIndex, 0)
            return BaseItemDtoQueryResult(
                items: [TestFixtures.item(id: "\(counter.next())")],
                startIndex: 0,
                totalRecordCount: 1
            )
        }

        XCTAssertEqual(model.items.compactMap(\.id), ["1"])

        await model.reload()

        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(model.items.compactMap(\.id), ["2"])
        XCTAssertTrue(model.hasLoadedOnce)
    }

    func testOverlappingPagesAdvanceByServerCursorAndDeduplicate() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        var requestedIndices: [Int] = []

        await model.load(model.query) { startIndex, _ in
            requestedIndices.append(startIndex)
            return BaseItemDtoQueryResult(
                items: [
                    TestFixtures.item(id: "a"),
                    TestFixtures.item(id: "b"),
                ],
                startIndex: 0,
                totalRecordCount: 4
            )
        }

        await model.loadNextPage()

        XCTAssertEqual(requestedIndices, [0, 2])
        XCTAssertEqual(model.items.compactMap(\.id), ["a", "b"])
        XCTAssertFalse(model.canLoadMore)
    }

    func testMissingTotalContinuesUntilServerReturnsEmptyPage() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        var requestedIndices: [Int] = []

        await model.load(model.query) { startIndex, _ in
            requestedIndices.append(startIndex)
            let items: [BaseItemDto]
            switch startIndex {
            case 0:
                items = [TestFixtures.item(id: "a"), TestFixtures.item(id: "b")]
            case 2:
                items = [TestFixtures.item(id: "c")]
            default:
                items = []
            }
            return BaseItemDtoQueryResult(items: items, startIndex: startIndex)
        }

        await model.loadNextPage()
        XCTAssertTrue(model.canLoadMore)
        await model.loadNextPage()

        XCTAssertEqual(requestedIndices, [0, 2, 3])
        XCTAssertEqual(model.items.compactMap(\.id), ["a", "b", "c"])
        XCTAssertFalse(model.canLoadMore)
    }

    func testReplacedLoadCannotOverwriteNewerResults() async throws {
        let model = PagedItems(list: .albums)
        let query = model.query

        let staleLoad = Task { @MainActor in
            await model.load(query) { _, _ in
                try? await Task.sleep(for: .milliseconds(100))
                return BaseItemDtoQueryResult(
                    items: [TestFixtures.item(id: "stale")],
                    startIndex: 0,
                    totalRecordCount: 1
                )
            }
        }

        try await Task.sleep(for: .milliseconds(10))
        await model.load(query) { _, _ in
            BaseItemDtoQueryResult(
                items: [TestFixtures.item(id: "current")],
                startIndex: 0,
                totalRecordCount: 1
            )
        }
        await staleLoad.value

        XCTAssertEqual(model.items.compactMap(\.id), ["current"])
        XCTAssertNil(model.errorMessage)
    }

    func testItemsWithoutIdentifiersAreRejected() async {
        let model = PagedItems(list: .albums, pageSize: 2)

        await model.load(model.query) { _, _ in
            BaseItemDtoQueryResult(
                items: [BaseItemDto(name: "No identifier", type: .musicAlbum)],
                startIndex: 0,
                totalRecordCount: 1
            )
        }

        XCTAssertTrue(model.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testLoadMoreOnlyTriggersFromTheLastRow() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        let counter = CallCounter()
        let loader: PagedItems.PageLoader = { _, _ in
            let n = counter.next()
            return BaseItemDtoQueryResult(
                items: [TestFixtures.item(id: "a-\(n)"), TestFixtures.item(id: "b-\(n)")],
                startIndex: 0,
                totalRecordCount: 10
            )
        }

        await model.load(model.query, using: loader)
        await model.loadMoreIfNeeded(TestFixtures.item(id: "a-1"))
        XCTAssertEqual(counter.count, 1, "A row that isn't the last must not page")

        await model.loadMoreIfNeeded(TestFixtures.item(id: "b-1"))
        XCTAssertEqual(counter.count, 2)
    }

    /// The bottom-of-list stall: the last row's one-shot trigger can arrive
    /// while a page is in flight, and that page is then cancelled (the row
    /// briefly left the viewport). The load settles with nothing appended, so
    /// the view — whose row task is keyed on `settledLoads` — asks again. That
    /// second ask must succeed, not be swallowed.
    func testATriggerDroppedByAnInFlightLoadIsRecoveredOnceItSettles() async throws {
        let model = PagedItems(list: .albums, pageSize: 2)
        var followUps = 0
        let loader: PagedItems.PageLoader = { startIndex, _ in
            if startIndex == 0 {
                return BaseItemDtoQueryResult(
                    items: [TestFixtures.item(id: "a"), TestFixtures.item(id: "b")],
                    startIndex: 0,
                    totalRecordCount: 6
                )
            }
            followUps += 1
            if followUps == 1 { throw URLError(.cancelled) }
            return BaseItemDtoQueryResult(
                items: [TestFixtures.item(id: "c"), TestFixtures.item(id: "d")],
                startIndex: startIndex,
                totalRecordCount: 6
            )
        }

        await model.load(model.query, using: loader)
        XCTAssertEqual(model.items.compactMap(\.id), ["a", "b"])
        let settledAfterFirstPage = model.settledLoads

        // The follow-up page is cancelled: nothing appended, no error, more to load.
        await model.loadNextPage()
        XCTAssertEqual(followUps, 1)
        XCTAssertEqual(model.items.compactMap(\.id), ["a", "b"])
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canLoadMore)
        XCTAssertGreaterThan(model.settledLoads, settledAfterFirstPage,
                             "The view re-arms its row task on this changing")

        // The re-keyed row task asks again once the load has settled.
        let lastRow = try XCTUnwrap(model.items.last)
        await model.loadMoreIfNeeded(lastRow)
        XCTAssertEqual(followUps, 2)
        XCTAssertEqual(model.items.compactMap(\.id), ["a", "b", "c", "d"])
    }

    /// The counter the views key their pagination task on must advance on every
    /// outcome — success, cancellation and failure — so a dropped trigger is
    /// always re-armed, whatever ended the load.
    func testSettledLoadsAdvancesOnEveryLoadOutcome() async {
        let ok = PagedItems(list: .albums, pageSize: 2)
        await ok.load(ok.query) { _, _ in
            BaseItemDtoQueryResult(items: [TestFixtures.item(id: "a")], startIndex: 0, totalRecordCount: 3)
        }
        XCTAssertEqual(ok.settledLoads, 1)

        let cancelled = PagedItems(list: .albums, pageSize: 2)
        await cancelled.load(cancelled.query) { _, _ in throw URLError(.cancelled) }
        XCTAssertEqual(cancelled.settledLoads, 1)
        XCTAssertNil(cancelled.errorMessage)

        let failed = PagedItems(list: .albums, pageSize: 2)
        await failed.load(failed.query) { _, _ in throw JellyfinError.notAuthenticated }
        XCTAssertEqual(failed.settledLoads, 1)
        XCTAssertNotNil(failed.errorMessage)
    }

    /// A settled-but-failed page shows the Retry affordance; the last row must
    /// not also auto-retry it, or a re-keyed task would loop on a persistent
    /// failure.
    func testLoadMoreDoesNotAutoRetryWhileAnErrorIsDisplayed() async throws {
        let model = PagedItems(list: .albums, pageSize: 2)
        let counter = CallCounter()
        let loader: PagedItems.PageLoader = { _, _ in
            if counter.next() == 1 {
                return BaseItemDtoQueryResult(
                    items: [TestFixtures.item(id: "a"), TestFixtures.item(id: "b")],
                    startIndex: 0,
                    totalRecordCount: 10
                )
            }
            throw JellyfinError.notAuthenticated
        }

        await model.load(model.query, using: loader)
        await model.loadNextPage()
        XCTAssertNotNil(model.errorMessage)
        let calls = counter.count

        let lastRow = try XCTUnwrap(model.items.last)
        await model.loadMoreIfNeeded(lastRow)

        XCTAssertEqual(counter.count, calls, "A displayed error is the Retry button's job")
    }

    // MARK: - Reuse and reloading

    func testAlreadyLoadedQueryIsNotFetchedAgain() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        let counter = CallCounter()

        await model.load(model.query, using: countingLoader(counter))
        await model.load(model.query, using: countingLoader(counter))

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(model.items.compactMap(\.id), ["1"])
    }

    /// Sort lives on the model, so changing it re-keys the query and the next
    /// load refetches. This is the wiring that makes the sort toolbar work.
    func testChangingTheSortFieldRefetches() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        let counter = CallCounter()

        await model.load(model.query, using: countingLoader(counter))
        model.sortBy = .dateCreated
        await model.load(model.query, using: countingLoader(counter))

        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(model.items.compactMap(\.id), ["2"])
    }

    func testChangingTheSortOrderRefetches() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        let counter = CallCounter()

        await model.load(model.query, using: countingLoader(counter))
        model.sortOrder = model.sortOrder.toggled
        await model.load(model.query, using: countingLoader(counter))

        XCTAssertEqual(counter.count, 2)
    }

    func testFailedLoadIsRetriedOnTheNextAppearance() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        let counter = CallCounter()
        let loader: PagedItems.PageLoader = { _, _ in
            if counter.next() == 1 { throw JellyfinError.notAuthenticated }
            return BaseItemDtoQueryResult(
                items: [TestFixtures.item(id: "ok")],
                startIndex: 0,
                totalRecordCount: 1
            )
        }

        await model.load(model.query, using: loader)
        XCTAssertNotNil(model.errorMessage)

        await model.load(model.query, using: loader)

        XCTAssertEqual(counter.count, 2)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.compactMap(\.id), ["ok"])
    }

    func testCancelledLoadIsNotSurfacedAndRetriesOnNextAppearance() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        let counter = CallCounter()
        let loader: PagedItems.PageLoader = { _, _ in
            if counter.next() == 1 { throw URLError(.cancelled) }
            return BaseItemDtoQueryResult(
                items: [TestFixtures.item(id: "ok")],
                startIndex: 0,
                totalRecordCount: 1
            )
        }

        // A load cancelled by the launch view rebuild must not become a visible
        // error, and must leave the model unloaded so it can retry.
        await model.load(model.query, using: loader)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.hasLoadedOnce)
        XCTAssertTrue(model.isEmpty)

        await model.load(model.query, using: loader)

        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(model.items.compactMap(\.id), ["ok"])
        XCTAssertNil(model.errorMessage)
    }

    /// A cancelled *follow-up* page is different from a cancelled first load:
    /// the pages already on screen are still valid, so re-appearing must not
    /// throw them away and start over from the top.
    func testCancelledFollowUpPageKeepsWhatIsAlreadyLoaded() async {
        let model = PagedItems(list: .albums, pageSize: 2)
        let counter = CallCounter()
        let loader: PagedItems.PageLoader = { startIndex, _ in
            _ = counter.next()
            if startIndex > 0 { throw URLError(.cancelled) }
            return BaseItemDtoQueryResult(
                items: [TestFixtures.item(id: "a"), TestFixtures.item(id: "b")],
                startIndex: 0,
                totalRecordCount: 10
            )
        }

        await model.load(model.query, using: loader)
        await model.loadNextPage()
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(model.items.compactMap(\.id), ["a", "b"])

        await model.load(model.query, using: loader)

        XCTAssertEqual(counter.count, 2, "The loaded pages must not be discarded and refetched")
        XCTAssertEqual(model.items.compactMap(\.id), ["a", "b"])
    }

    /// Registering with a backend — or a change to the ending it reports —
    /// re-keys the query. The model has to treat that as a new question rather
    /// than keep serving the playlists it already holds.
    func testAChangedNameFilterRefetches() async {
        let model = PagedItems(list: .playlists)
        let counter = CallCounter()
        let split = model.query(nameFilter: .notEndsWith("_automatic"))

        await model.load(split, using: countingLoader(counter))
        await model.load(split, using: countingLoader(counter))
        XCTAssertEqual(counter.count, 1, "An unchanged split must not refetch")

        await model.load(model.query, using: countingLoader(counter))
        XCTAssertEqual(counter.count, 2)
    }

    // MARK: - Sort state

    func testSortSeedsFromTheListAndTracksIntoTheQuery() {
        let songs = PagedItems(list: .songs)
        XCTAssertEqual(songs.sortBy, LibraryList.songs.defaultSortBy)
        XCTAssertEqual(songs.sortOrder, .ascending)
        XCTAssertEqual(songs.sortOptions, LibraryList.songs.sortOptions)

        let albums = PagedItems(list: .albums)
        XCTAssertEqual(albums.sortBy, .albumArtist)

        albums.sortBy = .productionYear
        XCTAssertEqual(albums.query.sortBy, .productionYear)
        XCTAssertEqual(albums.query.list, .albums)
    }

    // MARK: - Repository integration

    /// The model must send its *own* current query, not the list's defaults.
    func testLoadFromRepositorySendsTheModelsCurrentQuery() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.record(request)
            return (try emptyResponse(for: request, statusCode: 200), emptyItemsPayload)
        }

        let model = PagedItems(list: .favouriteAlbums)
        model.sortBy = .productionYear
        model.sortOrder = .descending

        await model.load(from: TestFixtures.stubbedRepository())

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.values(for: "includeItemTypes"), ["MusicAlbum"])
        XCTAssertEqual(request.values(for: "filters"), ["IsFavorite"])
        XCTAssertEqual(request.values(for: "sortBy"), ["ProductionYear", "PremiereDate", "SortName"])
        XCTAssertEqual(request.value(for: "sortOrder"), "Descending")
        XCTAssertEqual(request.value(for: "limit"), "\(LibraryList.favouriteAlbums.pageSize)")
        XCTAssertNil(model.errorMessage)
    }

    /// The name-split screens build their own query, so the model must fetch
    /// that one rather than falling back to the unfiltered ``query`` — and a
    /// split list arrives complete, so there is no next page to ask for.
    func testLoadFromRepositorySendsTheNameFilteredQuery() async {
        URLProtocolStub.handler = { request in
            (try emptyResponse(for: request, statusCode: 200),
             playlistsPayload(ids: ["Chill_automatic", "Road Trip"]))
        }

        let model = PagedItems(list: .mixtapePlaylists)
        await model.load(model.query(nameFilter: .endsWith("_automatic")),
                         from: TestFixtures.stubbedRepository())

        XCTAssertEqual(model.items.compactMap(\.id), ["Chill_automatic"])
        XCTAssertEqual(model.total, 1)
        XCTAssertFalse(model.canLoadMore)
        XCTAssertNil(model.errorMessage)
    }

    func testLoadFromASignedOutRepositorySurfacesAnError() async {
        let model = PagedItems(list: .albums)

        await model.load(from: TestFixtures.signedOutRepository())

        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - Helpers

    /// Counts loader invocations. A reference type so closures can share it.
    private final class CallCounter {
        private(set) var count = 0

        @discardableResult
        func next() -> Int {
            count += 1
            return count
        }
    }

    /// A loader that returns a single item named after the call number, so
    /// tests can tell one fetch's results from another's.
    private func countingLoader(_ counter: CallCounter) -> PagedItems.PageLoader {
        { _, _ in
            BaseItemDtoQueryResult(
                items: [TestFixtures.item(id: "\(counter.next())")],
                startIndex: 0,
                totalRecordCount: 1
            )
        }
    }
}
