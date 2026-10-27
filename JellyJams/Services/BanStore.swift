import Foundation

/// The kind of thing a ban removes from the playlists the backend generates.
///
/// The backend stores nothing but item ids and works the kind out itself
/// when it matches bans against candidate songs; the app sorts them back
/// out — the server hands the kinds apart in its `GET /bans` answer — so
/// the bans screen can group and name them.
enum BanKind: String, CaseIterable, Sendable {
    case artist
    case album
    case song

    /// The bans screen's section title. Plural because a section collects
    /// every ban of the kind, and empty kinds show no section at all.
    var sectionTitle: String {
        switch self {
        case .artist: return "Artists"
        case .album: return "Albums"
        case .song: return "Songs"
        }
    }

    /// The symbol the kind is known by elsewhere in the app's lists —
    /// the artist and album symbols its track rows navigate with.
    var symbol: String {
        switch self {
        case .artist: return "person"
        case .album: return "record.circle.fill"
        case .song: return "music.note"
        }
    }
}

/// One banned item as the bans screen shows it.
///
/// The item is whatever the user's server answered for the banned id — a
/// complete DTO, not the app's own stub — so the labels read its real
/// artist and album fields, and a tapped row can navigate on its ids.
struct BannedItem: Identifiable, Equatable, Sendable {
    let kind: BanKind
    let item: BaseItemDto

    /// The bans screen's selection key, and the id `DELETE /ban` undoes by.
    /// Jellyfin ids are unique across kinds, so one set keys every section.
    var id: String { item.id ?? item.displayName }

    /// The row's one line, naming the item and where it belongs: an artist
    /// is just itself; an album carries its artist; a song carries its
    /// artists and the album it was taken from. Missing names drop their
    /// clause rather than leaving a dangling "by" or "on".
    var label: String {
        switch kind {
        case .artist:
            return item.displayName
        case .album:
            guard let artist = albumArtistCredit else { return item.displayName }
            return "\(item.displayName) by \(artist)"
        case .song:
            var text = "“\(item.displayName)”"
            if let artist = trackArtistCredit {
                text += " by “\(artist)”"
            }
            if let album = item.album, !album.isEmpty {
                text += " on “\(album)”"
            }
            return text
        }
    }

    /// The song's credited artists on one line. Servers send the display
    /// names (`Artists`) and the id-carrying pairs (`ArtistItems`)
    /// together; a payload that brought only one still reads right, and
    /// the lone album artist answers for a solo act whose track lists
    /// came back empty.
    private var trackArtistCredit: String? {
        Self.credit(item.artists ?? [])
            ?? Self.credit((item.artistItems ?? []).compactMap { $0.name })
            ?? Self.credit(item.albumArtist.map { [$0] } ?? [])
    }

    /// The album's credited artist — the album artist first, because that
    /// is who "by" names on an album, whatever compilation credits the
    /// track list carries.
    private var albumArtistCredit: String? {
        Self.credit(item.albumArtist.map { [$0] } ?? [])
            ?? Self.credit((item.albumArtists ?? []).compactMap { $0.name })
            ?? Self.credit(item.artists ?? [])
            ?? Self.credit((item.artistItems ?? []).compactMap { $0.name })
    }

    /// Names joined for display, or nil when there were none to join.
    private static func credit(_ names: [String]) -> String? {
        let kept = names.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }

    /// What opening the row leads to: a banned artist or album is its own
    /// page; a banned song leads to the album it was taken from, because
    /// the song itself lives there and the ban reaches no other copy of it.
    /// Nil when there is no id to route on — the row then has nowhere to
    /// go and says so by not moving.
    var navigationTarget: BaseItemDto? {
        switch kind {
        case .artist, .album:
            return item.id == nil ? nil : item
        case .song:
            return item.albumNavigationItem
        }
    }

    /// The kind's order within its section: what Jellyfin sorts the library
    /// by, falling back to the name the server didn't sort.
    var sortKey: String {
        if let sortName = item.sortName, !sortName.isEmpty { return sortName }
        return item.displayName
    }
}

/// Holds the ban side of the Jelly Jams Backend: sending bans from context
/// menus, and the banned-items list the settings screen shows, unbans from,
/// and resets.
///
/// A ban is one Jellyfin item id — song, album or artist; the backend matches
/// stored bans against the ids every candidate song carries, so banning an
/// artist removes that artist's whole output from the playlists it generates,
/// and the app resolves nothing to send it. What the backend *can* take a ban
/// from follows the settings rather than the library: a signed-in account, a
/// saved address, and a registration — an app that never registered has no
/// backend account to ban with.
@MainActor
final class BanStore: ObservableObject {
    /// Whether the "Ban" menus have everything a `POST /ban` needs. Menus
    /// ask this before offering themselves, so nobody can reach an action
    /// that has nowhere to go.
    @Published private(set) var canBan = false
    /// Errors raised by ban actions in context menus. The menu is usually on
    /// its way out by the time the request fails, so these are hosted by the
    /// root container rather than the affordance that raised them — the same
    /// arrangement ``PlaylistStore`` keeps for playlist actions.
    @Published private(set) var actionErrorMessage: String?

    /// The bans, sorted into sections and into name order within each, as
    /// the backend last answered for this account. Empty is also an answer;
    /// ``hasBans`` and ``isLoading`` tell an empty list from nothing yet.
    @Published private(set) var bannedArtists: [BannedItem] = []
    @Published private(set) var bannedAlbums: [BannedItem] = []
    @Published private(set) var bannedSongs: [BannedItem] = []
    @Published private(set) var isLoading = false
    /// The bans list's own failures — a refused read, unban or reset. The
    /// bans screen stays open through them and says so in place, unlike the
    /// context-menu sends whose failures the root alert hosts.
    @Published private(set) var listErrorMessage: String?

    private var userID: String?
    /// The saved backend address, normalised — nil while there is no
    /// address, it will not parse, or the account has never registered.
    private var backendURL: URL?
    private var deviceInfo: DeviceInfo?
    /// Passed through to every client the store builds. Production leaves
    /// it nil; tests install their stub loader with it.
    private var sessionConfiguration: URLSessionConfiguration?
    /// Replaced on every load and every account change, so a response that
    /// predates either can never write it over the screen's newer state —
    /// ``PlaylistStore`` keeps the same guard over the playlist cache.
    private var loadGeneration = UUID()

    var hasBans: Bool {
        !bannedArtists.isEmpty || !bannedAlbums.isEmpty || !bannedSongs.isEmpty
    }

    /// The section a kind shows on the bans screen.
    func bannedItems(of kind: BanKind) -> [BannedItem] {
        switch kind {
        case .artist: return bannedArtists
        case .album: return bannedAlbums
        case .song: return bannedSongs
        }
    }

    /// Points the store at the backend as the session and settings describe
    /// it. Everything arrives as the value a publisher just emitted rather
    /// than being read back off the stores — `@Published` announces a change
    /// before it lands, so reading `preferences` here can still return the
    /// old address, or the old suffix, mid-registration. `registered` speaks
    /// the same rule ``PreferencesStore/isMixtapesActive`` does: a
    /// registration that recorded a playlist-name ending.
    func configure(
        userID: String?,
        address: String,
        registered: Bool,
        deviceInfo: DeviceInfo,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        // A different account is a different set of bans — or none. The
        // address alone changing must not clear the list: the settings
        // field edits it one keystroke at a time, and the bans screen may
        // be open behind it. Retiring the generation strands any read the
        // old account's screen had in flight.
        if userID != self.userID {
            loadGeneration = UUID()
            clearLists()
        }
        self.userID = userID
        self.backendURL = registered
            ? (try? JellyJamsBackend.normalizeAddress(address))
            : nil
        self.deviceInfo = deviceInfo
        self.sessionConfiguration = sessionConfiguration
        canBan = userID != nil && backendURL != nil
    }

    /// Bans each id with `POST /ban`, one request per item — the endpoint
    /// takes a single item, so a multi-selection is a batch of sends that
    /// stops at the first refusal.
    func ban(itemIds: [String]) async throws {
        guard let backend = makeBackend(), let userID else {
            throw BackendError.notSignedIn
        }
        guard !itemIds.isEmpty else {
            throw JellyfinError.missingItemIdentifier
        }
        for itemId in itemIds {
            _ = try await backend.ban(userID: userID, itemID: itemId)
        }
    }

    /// Loads the account's bans for the bans screen, sorted into sections.
    /// A no-op while the backend cannot be reached at all; a refused read
    /// keeps whatever the screen already shows and says why in place.
    func refreshBans() async {
        guard let backend = makeBackend(), let userID else { return }
        guard !isLoading else { return }
        let requestGeneration = UUID()
        loadGeneration = requestGeneration
        isLoading = true
        do {
            let answer = try await backend.bans(userID: userID)
            guard loadGeneration == requestGeneration else { return }
            apply(answer)
        } catch where error.isCancellation {
            // A dismissal mid-read; the next opening asks again.
        } catch {
            guard loadGeneration == requestGeneration else { return }
            listErrorMessage = error.userFacingMessage
        }
        if loadGeneration == requestGeneration {
            isLoading = false
        }
    }

    /// Undoes the bans for these ids. The rows leave the list first — a
    /// deleted row should be gone the moment it is deleted, the way the
    /// queue works — and a refusal from the backend puts them back and
    /// keeps its answer for the screen to show.
    func unban(itemIds: [String]) async {
        guard let backend = makeBackend(), let userID else {
            listErrorMessage = BackendError.notSignedIn.errorDescription
            return
        }
        guard !itemIds.isEmpty else { return }
        let snapshot = (artists: bannedArtists, albums: bannedAlbums, songs: bannedSongs)
        let generation = loadGeneration
        removeFromLists(ids: itemIds)
        do {
            for itemId in itemIds {
                _ = try await backend.unban(userID: userID, itemID: itemId)
            }
            // A write that worked is proof the backend answers — an older
            // refusal from this screen shouldn't keep standing over the rows.
            listErrorMessage = nil
        } catch {
            // The lists moved on (another account's, or a fresh read's) —
            // this account's snapshot is not what the screen is showing.
            guard loadGeneration == generation else { return }
            (bannedArtists, bannedAlbums, bannedSongs) = snapshot
            listErrorMessage = error.userFacingMessage
        }
    }

    /// Undoes every ban at once with `DELETE /reset-bans`. Optimistic like
    /// ``unban(itemIds:)``: the lists empty immediately, and a refusal puts
    /// the whole set back with the backend's answer beside it.
    func resetBans() async {
        guard let backend = makeBackend(), let userID else {
            listErrorMessage = BackendError.notSignedIn.errorDescription
            return
        }
        let snapshot = (artists: bannedArtists, albums: bannedAlbums, songs: bannedSongs)
        let generation = loadGeneration
        clearLists()
        do {
            try await backend.resetBans(userID: userID)
            listErrorMessage = nil
        } catch {
            guard loadGeneration == generation else { return }
            (bannedArtists, bannedAlbums, bannedSongs) = snapshot
            listErrorMessage = error.userFacingMessage
        }
    }

    func dismissActionError() {
        actionErrorMessage = nil
    }

    /// Records an error raised by a ban action in a context menu so the
    /// root-hosted alert can present it.
    func presentActionError(_ message: String?) {
        actionErrorMessage = message
    }

    // MARK: - Plumbing

    /// The client for the address the store points at, built per send rather
    /// than in `configure`: the settings field edits the address one
    /// keystroke at a time, and a client saved along with it would be
    /// rebuilt — and abandoned, URLSession and all — as it was typed.
    private func makeBackend() -> JellyJamsBackend? {
        guard let backendURL, let deviceInfo else { return nil }
        return JellyJamsBackend(
            baseURL: backendURL,
            deviceInfo: deviceInfo,
            sessionConfiguration: sessionConfiguration
        )
    }

    private func apply(_ bans: BackendBans) {
        listErrorMessage = nil
        bannedArtists = sortedSection(bans.artists, kind: .artist)
        bannedAlbums = sortedSection(bans.albums, kind: .album)
        bannedSongs = sortedSection(bans.songs, kind: .song)
    }

    private func sortedSection(_ items: [BaseItemDto], kind: BanKind) -> [BannedItem] {
        items
            .map { BannedItem(kind: kind, item: $0) }
            .sorted { $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending }
    }

    private func removeFromLists(ids: [String]) {
        bannedArtists.removeAll { ids.contains($0.id) }
        bannedAlbums.removeAll { ids.contains($0.id) }
        bannedSongs.removeAll { ids.contains($0.id) }
    }

    private func clearLists() {
        bannedArtists = []
        bannedAlbums = []
        bannedSongs = []
        listErrorMessage = nil
        isLoading = false
    }
}
