import Foundation

/// Settings the user controls that outlive a session, persisted to
/// `UserDefaults`.
///
/// Separate from ``SessionStore`` on purpose: these survive signing out and
/// belong to the person using the app, not to the server they happen to be
/// signed in to.
@MainActor
final class PreferencesStore: ObservableObject {
    private enum Key {
        static let showsSimilarItems = "showsSimilarItems"
    }

    /// Whether album and artist screens look up similar music.
    ///
    /// This gates the request, not just the row: with it off the
    /// ``SimilarItemsSection`` never appears, so its `task` never runs and
    /// Jellyfin is never asked. Someone turning this off to keep their server
    /// quiet gets exactly that.
    @Published var showsSimilarItems: Bool {
        didSet { defaults.set(showsSimilarItems, forKey: Key.showsSimilarItems) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than `bool(forKey:)`: the latter reports
        // false for an absent key, which would ship the feature switched off.
        showsSimilarItems = defaults.object(forKey: Key.showsSimilarItems) as? Bool ?? true
    }
}
