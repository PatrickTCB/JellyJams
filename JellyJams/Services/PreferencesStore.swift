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

/// Settings the user controls, persisted to `UserDefaults`.
///
/// Separate from ``SessionStore``, but nothing here outlives a sign-out:
/// leaving a server is a clean break back to the fresh-install state, so
/// ``forgetEverything()`` returns every field to its default. Everything the
/// Jelly Jams Backend relationship recorded is part of that, and
/// ``forgetBackend()`` covers the backend's share on its own for the
/// backend's own Sign Out.
@MainActor
final class PreferencesStore: ObservableObject {
    private enum Key {
        static let showsSimilarItems = "showsSimilarItems"
        static let showsCompleteAlbumsOnly = "showsCompleteAlbumsOnly"
        static let jellyJamsBackendAddress = "jellyJamsBackendAddress"
        static let mixtapeSuffix = "mixtapeSuffix"
        static let serverPlaylistJoined = "serverPlaylistJoined"
        static let serverPlaylist = "serverPlaylist"
        static let sameAlbumLimit = "sameAlbumLimit"
        static let sameArtistLimit = "sameArtistLimit"
        static let defaultPlayback = "defaultPlayback"
        static let infiniteQueueEnabled = "infiniteQueueEnabled"
    }

    /// The whole reset a Jellyfin server sign-out performs: every setting
    /// returns to the state a fresh install reads before anyone has touched
    /// anything. The backend's share goes through ``forgetBackend()`` —
    /// locally only; a server sign-out tells the backend nothing.
    func forgetEverything() {
        forgetBackend()
        showsSimilarItems = true
        showsCompleteAlbumsOnly = true
        defaultPlayback = nil
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
    /// through ``recordRegistration(address:suffix:playlist:)`` — because the backend
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
    func recordRegistration(address: String, suffix: String, playlist: String) {
        jellyJamsBackendAddress = address
        mixtapeSuffix = suffix
        serverPlaylist = playlist
    }

    /// The undo of ``recordRegistration(address:suffix:playlist:)``, and
    /// then some: a clean break with the backend. Everything the app
    /// learned through the relationship goes — the address, the
    /// registration, the Server Playlist's name and membership, the limits
    /// (back to the defaults a fresh install reads), and the Infinite
    /// Queue switch — so migrating to a different backend starts from the
    /// same blank slate this one did, with nothing carried over behind its
    /// back.
    ///
    /// Forgetting is local; the backend hears nothing from this call. Its
    /// account — bans, tape recipes, membership and all — stands until a
    /// backend Sign Out confirmed with the deletion checkbox rides
    /// `DELETE /delete-me` and takes it off the books, or nothing ever
    /// does. The Jellyfin sign-in is untouched either way, and the
    /// server's own sign-out runs this as part of ``forgetEverything()``
    /// without calling the backend either.
    func forgetBackend() {
        jellyJamsBackendAddress = ""
        mixtapeSuffix = ""
        serverPlaylist = ""
        serverPlaylistJoined = false
        sameAlbumLimit = Self.defaultSameAlbumLimit
        sameArtistLimit = Self.defaultSameArtistLimit
        infiniteQueueEnabled = false
    }

    /// Whether this account is in the backend's Server Playlist, as last known:
    /// the backend's own answer when it could be reached, this memory when it
    /// could not. The settings sheet writes a change through to the backend
    /// first and only settles it here once the backend agrees — which is also
    /// why joining is opt-in: the blend gathers a real account's listening
    /// for everyone in it, so nobody should be in it before asking to be.
    @Published var serverPlaylistJoined: Bool {
        didSet { defaults.set(serverPlaylistJoined, forKey: Key.serverPlaylistJoined) }
    }
    
    /// This is the name for the server playlist that the was set in the backend
    @Published private(set) var serverPlaylist: String {
        didSet { defaults.set(serverPlaylist, forKey: Key.serverPlaylist) }
    }

    /// The most tracks from one album that the backend may put into a single
    /// generated mixtape for this account, as last known: the backend's own
    /// answer when it could be reached, this memory when it could not. The
    /// defaults are the backend's own — album 3 — so an account that never
    /// set limits is remembered the way the backend would answer it.
    @Published var sameAlbumLimit: Int {
        didSet { defaults.set(sameAlbumLimit, forKey: Key.sameAlbumLimit) }
    }

    /// The most tracks from one artist that the backend may put into a single
    /// generated mixtape for this account — the artist twin of
    /// ``sameAlbumLimit``, defaulting to the backend's own 5.
    @Published var sameArtistLimit: Int {
        didSet { defaults.set(sameArtistLimit, forKey: Key.sameArtistLimit) }
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

    /// Whether Infinite Queue keeps the running queue topped up from the
    /// Jelly Jams Backend: when the listener nears the end of the queue, the
    /// backend is asked for more tracks — the next album's when the listen is
    /// an album in order, alchemy picks otherwise — and they are appended.
    ///
    /// Off by default: it grows every queue forever and leans on a companion
    /// service, so it should start when the user asks for it, not before.
    /// Unlike the backend's own feature settings, this one is purely local —
    /// the backend keeps no copy of it — so it is editable whether or not the
    /// backend can be reached; an unreachable backend simply means nothing
    /// extends.
    @Published var infiniteQueueEnabled: Bool {
        didSet { defaults.set(infiniteQueueEnabled, forKey: Key.infiniteQueueEnabled) }
    }

    private let defaults: UserDefaults

    /// The repeat limits the backend answers with for an account that never
    /// set any — what the memory starts at, and what it returns to when a
    /// sign-out forgets the backend entirely.
    private static let defaultSameAlbumLimit = 3
    private static let defaultSameArtistLimit = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than `bool(forKey:)`: the latter reports
        // false for an absent key, which would ship the feature switched off.
        showsSimilarItems = defaults.object(forKey: Key.showsSimilarItems) as? Bool ?? true
        showsCompleteAlbumsOnly = defaults.object(forKey: Key.showsCompleteAlbumsOnly) as? Bool ?? true
        jellyJamsBackendAddress = defaults.string(forKey: Key.jellyJamsBackendAddress) ?? ""
        mixtapeSuffix = defaults.string(forKey: Key.mixtapeSuffix) ?? ""
        serverPlaylistJoined = defaults.object(forKey: Key.serverPlaylistJoined) as? Bool ?? false
        serverPlaylist = defaults.object(forKey: Key.serverPlaylist) as? String ?? ""
        sameAlbumLimit = defaults.object(forKey: Key.sameAlbumLimit) as? Int ?? Self.defaultSameAlbumLimit
        sameArtistLimit = defaults.object(forKey: Key.sameArtistLimit) as? Int ?? Self.defaultSameArtistLimit
        defaultPlayback = defaults.data(forKey: Key.defaultPlayback).flatMap {
            try? JSONDecoder().decode(DefaultPlaybackSetting.self, from: $0)
        }
        // Off until asked for: an absent key must not switch the feature on.
        infiniteQueueEnabled = defaults.object(forKey: Key.infiniteQueueEnabled) as? Bool ?? false
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
