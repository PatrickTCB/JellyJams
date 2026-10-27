import Foundation

/// The item an open-ended play request starts, with its transport settings.
///
/// Chosen in Settings and consulted wherever "play something" arrives with
/// nothing named — Siri's default-playback sentinel and the system play
/// button. Explicit requests never look at it. `nil` in
/// ``PreferencesStore/defaultPlayback`` means the built-in behaviour: a
/// favourites shuffle.
struct DefaultPlaybackSetting: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case song, album, artist, playlist

        var label: String {
            switch self {
            case .song: "Song"
            case .album: "Album"
            case .artist: "Artist"
            case .playlist: "Playlist"
            }
        }
    }

    let kind: Kind
    let itemId: String
    /// The item's name when it was chosen, so settings rows and Siri's
    /// confirmation can show it without a server round-trip.
    let title: String
    var shuffle: Bool
    var repeatMode: RepeatMode
}

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
        static let showsCompleteAlbumsOnly = "showsCompleteAlbumsOnly"
        static let jellyJamsBackendAddress = "jellyJamsBackendAddress"
        static let mixtapeSuffix = "mixtapeSuffix"
        static let defaultPlayback = "defaultPlayback"
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

    /// Whether the Downloads albums list shows only albums whose every song is
    /// on disk.
    ///
    /// On by default: the section is where you go for what you can actually
    /// listen to, so albums that surfaced from one borrowed song shouldn't
    /// crowd it. Switching it off shows those partial albums too, which is how
    /// you find an album to finish downloading.
    @Published var showsCompleteAlbumsOnly: Bool {
        didSet { defaults.set(showsCompleteAlbumsOnly, forKey: Key.showsCompleteAlbumsOnly) }
    }

    /// The address of the Jelly Jams Backend — the companion service whose
    /// first feature is Mixtapes — exactly as it was entered, with a
    /// successful registration replacing it with the normalised form. The
    /// settings field edits this directly; it alone decides nothing about the
    /// feature, because an address nobody registered with has no rules yet.
    @Published var jellyJamsBackendAddress: String {
        didSet { defaults.set(jellyJamsBackendAddress, forKey: Key.jellyJamsBackendAddress) }
    }

    /// The name ending that marks a playlist as a mixtape the backend built,
    /// as the backend itself reported it. Never typed by hand — it arrives
    /// through ``recordRegistration(address:suffix:)`` — because the backend
    /// chooses how its own output is named, and an app that guessed would
    /// split the library on a rule the generator does not follow.
    ///
    /// Match through ``playlistNameFilter(for:)``, which trims it, rather
    /// than comparing against this directly.
    @Published private(set) var mixtapeSuffix: String {
        didSet { defaults.set(mixtapeSuffix, forKey: Key.mixtapeSuffix) }
    }

    /// Record a successful registration with the backend: the address it was
    /// reached at, and the playlist-name ending it gave back. This is what
    /// turns Mixtapes on — the section appears with the first registration
    /// and stays until a registration reports an ending that matches nothing.
    func recordRegistration(address: String, suffix: String) {
        jellyJamsBackendAddress = address
        mixtapeSuffix = suffix
    }

    /// What "play some music" starts. `nil` is the built-in favourites
    /// shuffle; a value names the item and transport settings the user chose.
    @Published var defaultPlayback: DefaultPlaybackSetting? {
        didSet {
            guard let defaultPlayback,
                  let data = try? JSONEncoder().encode(defaultPlayback)
            else {
                defaults.removeObject(forKey: Key.defaultPlayback)
                return
            }
            defaults.set(data, forKey: Key.defaultPlayback)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than `bool(forKey:)`: the latter reports
        // false for an absent key, which would ship the feature switched off.
        showsSimilarItems = defaults.object(forKey: Key.showsSimilarItems) as? Bool ?? true
        showsCompleteAlbumsOnly = defaults.object(forKey: Key.showsCompleteAlbumsOnly) as? Bool ?? true
        jellyJamsBackendAddress = defaults.string(forKey: Key.jellyJamsBackendAddress) ?? ""
        mixtapeSuffix = defaults.string(forKey: Key.mixtapeSuffix) ?? ""
        defaultPlayback = defaults.data(forKey: Key.defaultPlayback).flatMap {
            try? JSONDecoder().decode(DefaultPlaybackSetting.self, from: $0)
        }
    }

    /// The ending to match, or nil when there is nothing to match with.
    ///
    /// An empty suffix ends every name, so it would hand the whole playlist
    /// library to Mixtapes and leave the ordinary list empty. No ending is
    /// therefore the feature standing down rather than a rule that matches
    /// everything — which is also why an unregistered app shows no section.
    private var suffixToMatch: String? {
        let suffix = mixtapeSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    /// Whether the app has a registration to work from — what decides if the
    /// Mixtapes section appears at all.
    var isMixtapesActive: Bool { suffixToMatch != nil }

    /// The playlist-name split a list fetches with, or nil when it wants every
    /// playlist there is.
    ///
    /// Only the two playlist lists are split, and only in opposite directions:
    /// Mixtapes takes the backend's ones, the ordinary list gives them up.
    /// Favourites and the "Add to Playlist" menus are left alone — hiding a
    /// mixtape there would make it unreachable rather than tidier.
    func playlistNameFilter(for list: LibraryList) -> PlaylistNameFilter? {
        guard let suffix = suffixToMatch else { return nil }
        switch list {
        case .mixtapePlaylists: return .endsWith(suffix)
        case .playlists: return .notEndsWith(suffix)
        case .albums, .artists, .songs, .favouriteSongs, .favouriteAlbums,
             .favouriteArtists, .favouritePlaylists:
            return nil
        }
    }

    /// Whether an item is one of the backend's mixtapes, judged by the same
    /// name rule that splits the two playlist lists. False for every other
    /// kind of item, and for everything while the app is unregistered.
    func isMixtape(_ item: BaseItemDto) -> Bool {
        guard item.itemType == .playlist,
              let filter = playlistNameFilter(for: .mixtapePlaylists)
        else { return false }
        return filter.matches(item.name ?? "")
    }

    /// A mixtape's name with the backend's ending taken off, for showing it
    /// the way the Mixtapes screen does. Names without the ending — or every
    /// name, while the app is unregistered — come back untouched.
    func mixtapeName(for item: BaseItemDto) -> String {
        guard let filter = playlistNameFilter(for: .mixtapePlaylists) else {
            return item.displayName
        }
        return filter.trimmingMatchedEnding(from: item.displayName)
    }
}
