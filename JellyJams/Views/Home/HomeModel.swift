import Foundation

/// The phrases the Recent Music header rotates through. Adding one to
/// ``options`` is all it takes to expand the rotation.
enum RecentMusicHeading {
    static let options = ["New Tunage", "New Jams", "New Music", "What's New", "Latest Music", "Fresh Cuts"]

    /// A heading other than `current` where possible, so consecutive builds of
    /// the home screen don't repeat the same phrase.
    static func random(excluding current: String? = nil) -> String {
        let choices = options.filter { $0 != current }
        return (choices.isEmpty ? options : choices).randomElement() ?? "New Jams"
    }
}

/// Loads the home screen's server-backed sections in one place, so a section
/// added later is a fetch here and a view in ``HomeView``.
@MainActor
final class HomeModel: ObservableObject {
    struct Latest {
        var albums: [BaseItemDto] = []
        var artists: [BaseItemDto] = []

        var isEmpty: Bool { albums.isEmpty && artists.isEmpty }
    }

    /// How many tiles each Recent Music row asks for.
    static let latestLimit = 10
    /// How many AI Radio stations the quick links show.
    static let stationLimit = 3

    @Published private(set) var latest = Latest()
    @Published private(set) var stations: [BaseItemDto] = []
    @Published private(set) var recentHeading = RecentMusicHeading.random()

    /// Reloads every section, keeping the last good data when a request fails:
    /// a home screen with one stale row is better than a home screen with an
    /// error in the middle of it.
    func reload(using library: LibraryRepository, preferences: PreferencesStore) async {
        recentHeading = RecentMusicHeading.random(excluding: recentHeading)
        if let loaded = try? await fetchLatest(using: library) {
            latest = loaded
        }
        if let filter = preferences.playlistNameFilter(for: .aiRadioPlaylists) {
            if let loaded = try? await library.aiRadioStations(nameFilter: filter, limit: Self.stationLimit) {
                stations = loaded
            }
        } else {
            stations = []
        }
    }

    private func fetchLatest(using library: LibraryRepository) async throws -> Latest {
        async let albums = library.latestItems(.albums, limit: Self.latestLimit)
        async let artists = library.latestItems(.artists, limit: Self.latestLimit)
        return try await Latest(albums: albums, artists: artists)
    }
}
