import Foundation

/// The single source of truth for which items are favourited.
///
/// A `BaseItemDto` carries the server's answer in `userData.isFavorite`, but
/// that snapshot is only as fresh as the request that produced it, and the same
/// track reaches the screen through several independent requests — the songs
/// list, an album's tracks, search results, the queue. Views used to each keep
/// their own `@State` copy and write to the server themselves, which meant a
/// favourite applied in one place was invisible everywhere else, and was lost
/// entirely as soon as the view was rebuilt from the original snapshot (for
/// example when a grid cell scrolled off screen and back).
///
/// This store keeps the user's own changes in one dictionary keyed by item id.
/// An entry always wins over the snapshot, so every view that asks about an
/// item gets the same answer for as long as the session lasts, whichever
/// request the item arrived on.
@MainActor
final class FavouriteStore: ObservableObject {
    /// Items the user has changed this session, and what they changed them to.
    @Published private var overrides: [String: Bool] = [:]
    /// Items with a write in flight, so the affordance can disable itself and
    /// a second tap can't race the first.
    @Published private var inFlight: Set<String> = []
    @Published private(set) var errorMessage: String?

    private var client: JellyfinService?

    /// Points the store at a new session, discarding the previous account's
    /// changes. Pass `nil` on sign-out.
    func configure(client: JellyfinService?) {
        guard client !== self.client else { return }
        self.client = client
        overrides = [:]
        inFlight = []
        errorMessage = nil
    }

    /// Whether `item` is currently favourited, preferring a change made this
    /// session over the snapshot the item was fetched with.
    func isFavourite(_ item: BaseItemDto) -> Bool {
        guard let id = item.id else { return item.isFavorite }
        return overrides[id] ?? item.isFavorite
    }

    /// Whether a write for `item` is still in flight.
    func isBusy(_ item: BaseItemDto) -> Bool {
        guard let id = item.id else { return false }
        return inFlight.contains(id)
    }

    /// Flips `item`'s favourite state optimistically and tells the server,
    /// restoring the previous state if the write fails.
    func toggle(_ item: BaseItemDto) {
        guard let id = item.id else {
            errorMessage = JellyfinError.missingItemIdentifier.errorDescription
            return
        }
        guard let client else {
            errorMessage = JellyfinError.notAuthenticated.errorDescription
            return
        }
        guard !inFlight.contains(id) else { return }

        let previous = overrides[id]
        let newValue = !isFavourite(item)
        overrides[id] = newValue
        inFlight.insert(id)

        Task {
            do {
                try await client.setFavourite(itemId: id, isFavorite: newValue)
            } catch {
                // Restore the entry exactly as it was, so an item the user
                // never touched goes back to deferring to its snapshot.
                overrides[id] = previous
                if !error.isCancellation {
                    errorMessage = error.userFacingMessage
                }
            }
            inFlight.remove(id)
        }
    }

    func dismissError() {
        errorMessage = nil
    }
}
