import Foundation
import Observation

/// Retains the state of every browsable library list for the lifetime of a
/// sign-in session.
///
/// Because each ``PagedItems`` lives here instead of inside its `View`,
/// returning to a list — or coming back from a pushed detail screen — restores
/// the pages already loaded, the chosen sort and the scroll position rather
/// than refetching from the top. The cache is emptied on sign-out so the next
/// account starts fresh, which also releases the ``JellyfinService`` each list
/// captured for paging.
@MainActor
@Observable
final class LibraryCache {
    private var models: [LibraryList: PagedItems]

    init() {
        models = Self.freshModels()
    }

    /// The shared model for a list.
    ///
    /// Every list is seeded up front rather than created on first access,
    /// because ``SectionRootView`` calls this from its `body`. Creating a model
    /// lazily would mutate this cache — which the reading view observes —
    /// during that view's update: an update loop. A ``PagedItems`` costs
    /// nothing until it is asked to load, so there is no reason to defer it.
    func items(for list: LibraryList) -> PagedItems {
        guard let model = models[list] else {
            // Unreachable: `freshModels()` covers every case. Vending a
            // detached model keeps the lookup total without silently sharing
            // one list's state with another.
            assertionFailure("No cached model for \(list)")
            return PagedItems(list: list)
        }
        return model
    }

    /// Discards every cached list. Call on sign-out so a newly signed-in
    /// account never sees the previous one's library.
    func clear() {
        models = Self.freshModels()
    }

    private static func freshModels() -> [LibraryList: PagedItems] {
        Dictionary(uniqueKeysWithValues: LibraryList.allCases.map { ($0, PagedItems(list: $0)) })
    }
}
