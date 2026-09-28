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
        static let aiRadioEnabled = "aiRadioEnabled"
        static let aiRadioSuffix = "aiRadioSuffix"
    }

    /// The playlist-name ending AudioMuse-AI appends to what it generates, and
    /// what the setting's field is pre-filled with.
    static let defaultAIRadioSuffix = "_automatic"

    /// Whether album and artist screens look up similar music.
    ///
    /// This gates the request, not just the row: with it off the
    /// ``SimilarItemsSection`` never appears, so its `task` never runs and
    /// Jellyfin is never asked. Someone turning this off to keep their server
    /// quiet gets exactly that.
    @Published var showsSimilarItems: Bool {
        didSet { defaults.set(showsSimilarItems, forKey: Key.showsSimilarItems) }
    }

    /// Whether playlists AudioMuse-AI generated are gathered into their own
    /// ``LibrarySection/aiRadio`` and kept out of the ordinary playlist list.
    ///
    /// Off until the user asks for it: turning it on hides playlists from the
    /// library, which should be a choice rather than a surprise.
    @Published var aiRadioEnabled: Bool {
        didSet { defaults.set(aiRadioEnabled, forKey: Key.aiRadioEnabled) }
    }

    /// The name ending that marks a playlist as one of AudioMuse-AI's, exactly
    /// as the user typed it. Match through ``playlistNameFilter(for:)``, which
    /// trims it, rather than comparing against this directly.
    @Published var aiRadioSuffix: String {
        didSet { defaults.set(aiRadioSuffix, forKey: Key.aiRadioSuffix) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than `bool(forKey:)`: the latter reports
        // false for an absent key, which would ship the feature switched off.
        showsSimilarItems = defaults.object(forKey: Key.showsSimilarItems) as? Bool ?? true
        aiRadioEnabled = defaults.object(forKey: Key.aiRadioEnabled) as? Bool ?? false
        aiRadioSuffix = defaults.string(forKey: Key.aiRadioSuffix) ?? Self.defaultAIRadioSuffix
    }

    /// The ending to match, or nil when there is nothing to match with.
    ///
    /// An empty suffix ends every name, so it would hand the whole playlist
    /// library to AI Radio and leave the ordinary list empty. A blank field is
    /// therefore the feature standing down rather than a rule that matches
    /// everything — which also keeps the section hidden while the user is
    /// mid-edit, and back again when they finish typing.
    private var suffixToMatch: String? {
        guard aiRadioEnabled else { return nil }
        let suffix = aiRadioSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    /// Whether AI Radio is switched on and able to work — what decides if the
    /// section appears at all.
    var isAIRadioActive: Bool { suffixToMatch != nil }

    /// The playlist-name split a list fetches with, or nil when it wants every
    /// playlist there is.
    ///
    /// Only the two playlist lists are split, and only in opposite directions:
    /// AI Radio takes the generated ones, the ordinary list gives them up.
    /// Favourites and the "Add to Playlist" menus are left alone — hiding a
    /// station there would make it unreachable rather than tidier.
    func playlistNameFilter(for list: LibraryList) -> PlaylistNameFilter? {
        guard let suffix = suffixToMatch else { return nil }
        switch list {
        case .aiRadioPlaylists: return .endsWith(suffix)
        case .playlists: return .notEndsWith(suffix)
        case .albums, .artists, .songs, .favouriteSongs, .favouriteAlbums,
             .favouriteArtists, .favouritePlaylists:
            return nil
        }
    }
}
