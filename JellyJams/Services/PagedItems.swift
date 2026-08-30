import SwiftUI

/// The state of one browsable library list: which sort is applied, the pages
/// loaded so far, and the current loading/error status.
///
/// Instances are owned by ``LibraryCache`` rather than by a `View`, so a list
/// keeps its items, its sort selection and its scroll position when the user
/// navigates away and comes back.
@MainActor
final class PagedItems: ObservableObject {
    /// Fetches one page given a start index and a limit. Production loads go
    /// through ``LibraryRepository``; tests supply their own to exercise paging
    /// without a server.
    typealias PageLoader = (Int, Int) async throws -> BaseItemDtoQueryResult

    @Published private(set) var items: [BaseItemDto] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var total = 0
    @Published private(set) var hasLoadedOnce = false

    /// The user's sort selection, bound directly by the toolbar controls.
    /// Changing either re-keys ``query`` so the next ``load(from:)`` refetches,
    /// and both persist for as long as the list stays cached.
    @Published var sortBy: SortBy
    @Published var sortOrder: SortOrder

    let list: LibraryList

    private let pageSize: Int
    private var loader: PageLoader?
    private var generation = UUID()
    private var nextStartIndex = 0
    private var reachedEnd = false
    /// Identifies the query behind the currently loaded items, so a view that
    /// re-appears can tell "same list, keep it" from "sort changed, reload".
    private var loadedQuery: LibraryQuery?

    init(list: LibraryList, pageSize: Int? = nil) {
        self.list = list
        self.pageSize = pageSize ?? list.pageSize
        self.sortBy = list.defaultSortBy
        self.sortOrder = list.defaultSortOrder
    }

    /// The list plus its current sort — what ``load(from:)`` will fetch, and a
    /// stable value for a view's `.task(id:)`.
    var query: LibraryQuery {
        LibraryQuery(list: list, sortBy: sortBy, sortOrder: sortOrder)
    }

    /// Sort fields this list offers, for its toolbar menu.
    var sortOptions: [SortBy] { list.sortOptions }

    var isEmpty: Bool { items.isEmpty }
    var canLoadMore: Bool { !reachedEnd }

    // MARK: - Loading

    /// Loads the first page unless the current ``query`` is already loaded.
    ///
    /// Safe to call on every appearance: returning from a pushed detail screen
    /// keeps the existing items, while a changed sort or a previous failure
    /// triggers a fresh load.
    func load(from repository: LibraryRepository) async {
        let query = self.query
        await load(query) { startIndex, limit in
            try await repository.page(query, startIndex: startIndex, limit: limit)
        }
    }

    /// Core of ``load(from:)``, split out so tests can drive paging directly.
    func load(_ query: LibraryQuery, using loader: @escaping PageLoader) async {
        if query == loadedQuery, hasLoadedOnce, errorMessage == nil { return }
        loadedQuery = query
        await start(loader)
    }

    /// Discards the loaded pages and fetches the first one again.
    func reload() async {
        guard let loader else { return }
        await start(loader)
    }

    func loadNextPage() async {
        guard let loader, !isLoading else { return }
        await loadPage(generation: generation, loader: loader)
    }

    /// Call from the last visible row to trigger the next page.
    func loadMoreIfNeeded(_ item: BaseItemDto) async {
        guard items.last?.id == item.id, canLoadMore, !isLoading else { return }
        await loadNextPage()
    }

    // MARK: - Internals

    private func start(_ loader: @escaping PageLoader) async {
        generation = UUID()
        self.loader = loader
        items = []
        total = 0
        nextStartIndex = 0
        reachedEnd = false
        errorMessage = nil
        hasLoadedOnce = false
        isLoading = false
        await loadPage(generation: generation, loader: loader)
    }

    private func loadPage(
        generation requestGeneration: UUID,
        loader: @escaping PageLoader
    ) async {
        guard requestGeneration == generation, !isLoading else { return }
        if hasLoadedOnce && !canLoadMore { return }

        isLoading = true
        errorMessage = nil
        let requestedStartIndex = nextStartIndex

        do {
            let result = try await loader(requestedStartIndex, pageSize)
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }

            let pageItems = result.items ?? []
            guard pageItems.allSatisfy({ $0.id != nil }) else {
                throw JellyfinError.missingItemIdentifier
            }
            let consumed = pageItems.count
            nextStartIndex = max(
                requestedStartIndex + consumed,
                (result.startIndex ?? requestedStartIndex) + consumed
            )
            if let totalRecordCount = result.totalRecordCount {
                total = max(totalRecordCount, nextStartIndex)
                reachedEnd = consumed == 0 || nextStartIndex >= totalRecordCount
            } else {
                total = nextStartIndex
                reachedEnd = consumed == 0
            }

            // De-dupe defensively in case of overlapping pages.
            var known = Set(items.compactMap(\.id))
            for item in pageItems {
                if let id = item.id, known.insert(id).inserted {
                    items.append(item)
                }
            }

            isLoading = false
            hasLoadedOnce = true
        } catch {
            guard requestGeneration == generation else { return }
            if error.isCancellation {
                // The task backing this load was cancelled because the view was
                // replaced or briefly went away (during launch the adaptive
                // sidebar/tab shell settles and restarts the task). The SDK
                // reports this as `URLError.cancelled`, not `CancellationError`.
                // Leave the model unloaded — with no visible error and no false
                // "empty" state — so the restarted or next load fetches cleanly.
                // `loadedQuery` deliberately stays set: pages already loaded are
                // still valid, and `hasLoadedOnce` remaining false is what makes
                // an interrupted first load retry.
                isLoading = false
            } else {
                errorMessage = error.userFacingMessage
                isLoading = false
                hasLoadedOnce = true
            }
        }
    }
}
