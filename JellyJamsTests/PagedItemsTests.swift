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
