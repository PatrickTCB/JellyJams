import Combine
import Foundation

/// Caches the signed-in user's audio playlists so "Add to Playlist" menus can
/// be built instantly instead of hitting the server once per menu.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [BaseItemDto] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// How long a cached list is trusted before a menu triggers a refresh.
    private let staleInterval: TimeInterval = 300
    /// Failed attempts are retried sooner, but not so often that a server
    /// outage turns into one request per grid cell that scrolls into view.
    private let retryInterval: TimeInterval = 30

    private var client: JellyfinService?
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastAttempt: Date?
    private var lastAttemptSucceeded = false

    var hasPlaylists: Bool { !playlists.isEmpty }

    /// Points the store at a new session, discarding anything cached for the
    /// previous one. Pass `nil` on sign-out.
    func configure(client: JellyfinService?) {
        guard client !== self.client else { return }
        cancelLoad()
        self.client = client
        playlists = []
        lastAttempt = nil
        lastAttemptSucceeded = false
        errorMessage = nil
        isLoading = false
        if client != nil { refresh() }
    }

    /// Reloads only when nothing has been fetched yet or the cache has gone
    /// stale. Safe to call from every menu or cell that might need playlists.
    func refreshIfNeeded() {
        guard client != nil, loadTask == nil else { return }
        guard let lastAttempt else {
            refresh()
            return
        }
        let interval = lastAttemptSucceeded ? staleInterval : retryInterval
        if Date().timeIntervalSince(lastAttempt) >= interval { refresh() }
    }

    /// Starts a load, replacing any in-flight one so a response that predates
    /// a newly created playlist can never overwrite fresher state.
    func refresh() {
        guard let client else { return }
        loadTask?.cancel()
        let requestGeneration = UUID()
        generation = requestGeneration
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            let outcome: Result<[BaseItemDto], Error>
            do {
                outcome = .success(try await client.getPlaylists())
            } catch {
                outcome = .failure(error)
            }
            guard let self, generation == requestGeneration else { return }
            switch outcome {
            case .success(let loaded):
                playlists = loaded
                lastAttemptSucceeded = true
            case .failure(let error):
                if !error.isCancellation {
                    errorMessage = error.userFacingMessage
                }
                lastAttemptSucceeded = false
            }
            lastAttempt = Date()
            isLoading = false
            loadTask = nil
        }
    }

    func add(itemIds: [String], toPlaylistWithId playlistId: String?) async throws {
        guard let client else { throw JellyfinError.notAuthenticated }
        try await client.addItemsToPlaylist(playlistId: playlistId, itemIds: itemIds)
    }

    /// Creates a playlist seeded with `itemIds` and reloads the cache so the
    /// new playlist appears in menus immediately. The server creates the
    /// playlist before the seeding steps can fail, so the cache is reconciled
    /// whatever the outcome.
    func createPlaylist(named name: String, itemIds: [String]) async throws {
        guard let client else { throw JellyfinError.notAuthenticated }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JellyfinError.emptyPlaylistName }
        defer { refresh() }
        try await client.createPlaylist(name: trimmed, itemIds: itemIds)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func cancelLoad() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
    }
}
