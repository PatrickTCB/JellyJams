#if os(iOS)
import CarPlay
import Foundation
import XCTest
@testable import JellyJams

/// CarPlay trims a list template to its first ``CPListTemplate/maximumItemCount``
/// rows, so the pager must leave the last slot for the Load more row and show
/// one page at a time — an accumulated display would overflow the cap and the
/// row would be trimmed away, never appearing at all.
@MainActor
final class CarPlayPagedListTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    // MARK: - The cap

    func testLoadMoreRowFitsWithinTheTemplateCap() async throws {
        let pageSize = CarPlayPagedList.pageSize
        let total = pageSize * 2 + 5
        servePages(total: total)
        let (pager, _, template) = makePager(pageSize: pageSize)

        pager.start()
        await waitUntil { template.itemCount > 0 }

        // A full page plus the row is exactly the cap — the row is the last
        // item displayed, not the first one trimmed.
        let rows = try displayedRows(template)
        XCTAssertEqual(rows.count, pageSize + 1)
        XCTAssertLessThanOrEqual(rows.count, CPListTemplate.maximumItemCount)
        XCTAssertEqual(rows.last?.text, "Load more")
        XCTAssertEqual(rows.first?.text, "item-0")
    }

    func testLoadMoreReplacesTheWindowAndKeepsGlobalIndices() async throws {
        let pageSize = CarPlayPagedList.pageSize
        let total = pageSize * 2 + 5
        servePages(total: total)
        var rowIndexes: [String: Int] = [:]
        let (pager, model, template) = makePager(pageSize: pageSize, makeRow: { item, index in
            rowIndexes[item.id ?? ""] = index
            return CPListItem(text: item.displayName, detailText: nil)
        })

        pager.start()
        await waitUntil { template.itemCount > 0 }
        try tapLoadMore(in: template)
        await waitUntil { self.firstRowText(template) == "item-\(pageSize)" }

        // The second page replaces the first on screen — accumulating both
        // would overflow the cap and trim the Load more row again — while the
        // model keeps everything, and rows keep their index in that full list
        // so a track tap plays from the right place in the whole queue.
        let rows = try displayedRows(template)
        XCTAssertEqual(rows.count, pageSize + 1)
        XCTAssertEqual(rows.first?.text, "item-\(pageSize)")
        XCTAssertEqual(rows.last?.text, "Load more")
        XCTAssertEqual(rowIndexes["item-\(pageSize)"], pageSize)
        XCTAssertEqual(model.items.count, pageSize * 2)

        try tapLoadMore(in: template)
        await waitUntil { self.firstRowText(template) == "item-\(pageSize * 2)" }

        // The short final page ends the list: no row, no further requests.
        let finalRows = try displayedRows(template)
        XCTAssertEqual(finalRows.count, 5)
        XCTAssertEqual(finalRows.first?.text, "item-\(pageSize * 2)")
        XCTAssertFalse(model.canLoadMore)
    }

    // MARK: - Failure

    func testFailedLoadMoreKeepsTheCurrentPage() async throws {
        let pageSize = CarPlayPagedList.pageSize
        servePages(total: pageSize * 2, failingAfterFirstPage: true)
        var errors: [String] = []
        let (pager, _, template) = makePager(pageSize: pageSize, showError: { errors.append($0) })

        pager.start()
        await waitUntil { template.itemCount > 0 }
        try tapLoadMore(in: template)
        // The alert is reported after the rebuild, so waiting on it means the
        // whole load-more task has settled.
        await waitUntil { errors.count == 1 }

        // The window must not jump past the items that exist: the first page
        // stays on screen and the failure surfaces as an alert.
        let rows = try displayedRows(template)
        XCTAssertEqual(rows.first?.text, "item-0")
        XCTAssertEqual(rows.count, pageSize + 1)
        XCTAssertEqual(rows.last?.text, "Load more")
        XCTAssertEqual(errors.count, 1)
    }

    // MARK: - Helpers

    /// A pager wired to a stubbed repository, with the model and template
    /// exposed for assertions.
    private func makePager(
        pageSize: Int,
        showError: @escaping (String) -> Void = { XCTFail("Unexpected error: \($0)") },
        makeRow: ((BaseItemDto, Int) -> CPListItem)? = nil
    ) -> (CarPlayPagedList, PagedItems, CPListTemplate) {
        let model = PagedItems(list: .albums, pageSize: pageSize)
        let template = CPListTemplate(title: "Albums", sections: [])
        let row = makeRow ?? { item, _ in CPListItem(text: item.displayName, detailText: nil) }
        let pager = CarPlayPagedList(
            model: model,
            template: template,
            repository: TestFixtures.stubbedRepository(),
            emptyTitle: "Nothing here",
            makeRow: row,
            showError: showError
        )
        return (pager, model, template)
    }

    /// Serves `total` albums in pages, named after their index so assertions
    /// can tell which window is on screen.
    ///
    /// `nonisolated` because `URLProtocolStub` runs its handler on the URL
    /// loading thread, not the main actor this test class is isolated to.
    nonisolated private func servePages(total: Int, failingAfterFirstPage: Bool = false) {
        URLProtocolStub.handler = { request in
            let recorded = RecordedRequest(request)
            let startIndex = Int(recorded.value(for: "startIndex") ?? "0") ?? 0
            if failingAfterFirstPage, startIndex > 0 {
                return (try emptyResponse(for: request, statusCode: 500), Data())
            }
            let limit = Int(recorded.value(for: "limit") ?? "0") ?? 0
            let end = max(startIndex, min(startIndex + limit, total))
            let items = (startIndex..<end).map { index in
                #"{"Id":"item-\#(index)","Name":"item-\#(index)","Type":"MusicAlbum"}"#
            }
            let payload = Data(
                #"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(total),"StartIndex":\#(startIndex)}"#.utf8
            )
            return (try emptyResponse(for: request, statusCode: 200), payload)
        }
    }

    private func displayedRows(_ template: CPListTemplate) throws -> [CPListItem] {
        let section = try XCTUnwrap(template.sections.first)
        return section.items.compactMap { $0 as? CPListItem }
    }

    private func firstRowText(_ template: CPListTemplate) -> String? {
        (template.sections.first?.items.first as? CPListItem)?.text
    }

    private func tapLoadMore(in template: CPListTemplate) throws {
        let rows = try displayedRows(template)
        let row = try XCTUnwrap(rows.last, "No Load more row to tap")
        XCTAssertEqual(row.text, "Load more")
        row.handler?(row, {})
    }

    /// The pager loads in unstructured tasks; yield until the expected state
    /// arrives rather than assuming a fixed number of hops.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Condition not met within \(timeout)s", file: file, line: line)
    }
}
#endif
