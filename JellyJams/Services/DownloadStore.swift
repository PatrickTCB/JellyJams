import Foundation
import JellyfinAPI
import OSLog

private let downloadLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "net.aseriesoftubes.JellyJams",
    category: "Downloads"
)

/// Offline playback: saves audio files under Application Support/Downloads,
/// keyed by track id.
///
/// The song is the only thing that is ever downloaded. Everything the downloads
/// section browses is a *view* over the songs on disk:
///
/// - **Albums and artists are derived**, grouped from the metadata each track
///   snapshot carries (`albumID`, `album`, album-artist attribution). No album
///   or artist record is stored, so downloading one track surfaces its album at
///   "1 of 12" and its artist, and removing a song can never leave an empty
///   collection behind.
/// - **Playlists** are the one grouping a song's own metadata cannot express,
///   so a downloaded playlist also saves a small membership record: title,
///   ordered track ids, cover tag.
/// - **Songs** are every file on disk, newest download first.
///
/// Each file keeps the set of *source ids* that required it — the album,
/// playlist or genre id it arrived with, plus its own id when it was downloaded
/// as a song. Removing a collection unlinks it from every song it required, and
/// songs then requiring nothing are deleted in a sweep over the entries. That
/// reference counting is what keeps "download album, then a playlist overlapping
/// it" from duplicating bytes or orphaning files. Removing a *song* is different
/// and deliberate: the file goes, and with it its place in every playlist.
///
/// Album artwork is downloaded alongside tracks under ``artworkPair(for:)``: the
/// album's id with the *album's* image tag, so one file serves every song of the
/// album and the album, artist and song views all ask for the same key. A song's
/// own `ImageTags` entry is its embedded file art — a different value per song on
/// lossless files — and pairing it with the album id would give each song its own
/// file and leave the album views with nothing to resolve. Artwork follows the
/// same reference counting as audio.
///
/// Nothing in the browse path (`groups`, `tracks`, `localURL`, `localArtworkURL`)
/// touches the network or needs a signed-in session: the manifest holds every
/// byte of metadata those screens render. It is rewritten after every change, so
/// downloads survive relaunches, and deliberately survives sign-out too —
/// offline listening is the point.
@MainActor
final class DownloadStore: ObservableObject {
    /// The kind of view the downloads section browses. Songs are not a kind:
    /// they are what every kind is made of.
    enum GroupKind: String, Codable, Sendable {
        case album, artist, playlist, genre
    }

    /// One downloaded file, and the source ids that require it.
    struct Entry: Codable, Sendable, Equatable {
        var track: BaseItemDto
        var filename: String
        /// Fetch order, preserved so collections list their tracks in the
        /// order the server returned them.
        var order: Int
        /// The album, playlist or genre ids this file was downloaded with, and
        /// its own id when it was downloaded as a song. Persisted under its v1
        /// name so existing manifests keep reading.
        var sources: Set<String>
        /// Total songs in the album this track arrived with, when the download
        /// had one — the denominator for a partially downloaded album.
        var albumSongCount: Int?
        /// Album-artist keys (ids, or names where the server sent none)
        /// captured at download time, so artist grouping does not depend on
        /// attribution a track payload may lack.
        var artistKeys: Set<String>

        private enum CodingKeys: String, CodingKey {
            case track, filename, order, albumSongCount, artistKeys
            case sources = "requiredBy"
        }

        init(
            track: BaseItemDto,
            filename: String,
            order: Int,
            sources: Set<String>,
            albumSongCount: Int? = nil,
            artistKeys: Set<String> = []
        ) {
            self.track = track
            self.filename = filename
            self.order = order
            self.sources = sources
            self.albumSongCount = albumSongCount
            self.artistKeys = artistKeys
        }

        /// Written tolerantly: the fields v2 added are absent from v1 manifests,
        /// and a missing one must read as empty rather than fail the whole file.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            track = try container.decode(BaseItemDto.self, forKey: .track)
            filename = try container.decode(String.self, forKey: .filename)
            order = try container.decode(Int.self, forKey: .order)
            sources = try container.decodeIfPresent(Set<String>.self, forKey: .sources) ?? []
            albumSongCount = try container.decodeIfPresent(Int.self, forKey: .albumSongCount)
            artistKeys = try container.decodeIfPresent(Set<String>.self, forKey: .artistKeys) ?? []
        }
    }

    /// A downloaded playlist's offline membership. Track ids are in playlist
    /// order and deduplicated — a song appearing twice is one row here, and one
    /// file on disk either way.
    struct PlaylistRecord: Codable, Sendable, Equatable {
        var id: String
        var title: String
        var trackIDs: [String]
        /// The playlist's own cover image tag, when it has one.
        var coverTag: String?
        /// How many songs the playlist had when it was saved.
        var totalSongs: Int?
    }

    /// One downloaded artwork file, and the ids that reference it.
    struct ArtworkEntry: Codable, Sendable, Equatable {
        var filename: String
        /// The item that owns the image — the album for album art, the playlist
        /// for a playlist cover. `nil` for artwork saved by a v1 manifest,
        /// which keyed files by tag alone.
        var ownerItemID: String?
        var imageTag: String
        /// Track ids (and playlist ids, for covers) that require this artwork.
        var requiredBy: Set<String>

        /// The manifest key: owner plus tag, or the bare tag for artwork
        /// carried over from a v1 manifest.
        var key: String {
            guard let ownerItemID, !ownerItemID.isEmpty else { return imageTag }
            return "\(ownerItemID)|\(imageTag)"
        }
    }

    /// One in-flight download batch, keyed by the id of the item that started
    /// it — which is also what progress UIs group by.
    struct Batch: Identifiable, Equatable, Sendable {
        let id: String
        var completed = 0
        var failed = 0
        var total = 0
    }

    /// Song-level progress across every running batch: what the downloads
    /// status bar's filling bar shows.
    struct DownloadProgress: Equatable, Sendable {
        /// Songs resolved — downloaded or failed, either way they are past.
        var completed: Int
        /// Songs expected, once the batch's track list has resolved.
        var total: Int

        /// Bar fill, clamped; zero while the total is unknown.
        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(completed) / Double(total))
        }
    }

    /// A browsable view over the downloaded songs: an album, an artist, or a
    /// downloaded playlist.
    struct DownloadGroup: Identifiable, Sendable {
        let id: String
        let kind: GroupKind
        let title: String
        /// A stand-in item carrying everything the screens render — name, type,
        /// attribution, image tags — assembled from the songs in the group, so
        /// a downloaded group and its online counterpart look the same to a
        /// view.
        let item: BaseItemDto
        /// Songs on disk right now.
        let downloadedSongs: Int
        /// Songs the group has on the server, when known at download time.
        let totalSongs: Int?
        /// Whether this group was itself downloaded, as opposed to surfacing
        /// because one of its songs arrived through a playlist or as a song.
        /// Drives the download toggle: a borrowed album still offers to fill
        /// the rest.
        let isExplicit: Bool
        /// The keys this group's cover is filed under, canonical first — an
        /// album's own pair, an artist the borrowed pair of one of its albums, a
        /// playlist its saved cover — followed by the spellings older manifests
        /// used, so artwork saved before a migration still shows.
        let artworkKeys: [String]
        /// Artist attribution for an album group; empty for playlists.
        let artistKeys: Set<String>

        /// Every song the group has on the server is on disk.
        ///
        /// An unknown total — an album that surfaced because one of its songs
        /// arrived by playlist or on its own, rather than through an album
        /// download — cannot be claimed complete. That is what lets the
        /// Downloads "complete albums" filter hide a one-song album rather than
        /// present it as finished.
        var isFullyDownloaded: Bool {
            guard let totalSongs, totalSongs > 0 else { return false }
            return downloadedSongs >= totalSongs
        }
    }

    @Published private(set) var entries: [String: Entry] = [:]
    /// Downloaded playlists by id — the only stored grouping, because playlist
    /// membership is the one thing a song's metadata cannot say.
    @Published private(set) var playlists: [String: PlaylistRecord] = [:]
    @Published private(set) var batches: [Batch] = []
    @Published private(set) var errorMessage: String?

    @Published private(set) var artworkEntries: [String: ArtworkEntry] = [:]

    /// Every file transfer, feeding the throughput the downloads status bar
    /// shows.
    private let downloadSession: DownloadSession

    private var client: JellyfinService?
    private let directory: URL
    private let manifestURL: URL
    private let artworkDirectory: URL

    private nonisolated static let manifestVersion = 3

    private struct Manifest: Codable, Sendable {
        var version: Int
        var tracks: [String: DownloadStore.Entry]
        var playlists: [String: DownloadStore.PlaylistRecord]
        var artwork: [String: DownloadStore.ArtworkEntry]
        /// The version this manifest was actually written at, which is what
        /// decides whether a load needs migrating. Not encoded: it describes the
        /// file being read, not the one being written.
        var loadedVersion: Int = DownloadStore.manifestVersion

        init(
            tracks: [String: DownloadStore.Entry],
            playlists: [String: DownloadStore.PlaylistRecord],
            artwork: [String: DownloadStore.ArtworkEntry]
        ) {
            version = DownloadStore.manifestVersion
            self.tracks = tracks
            self.playlists = playlists
            self.artwork = artwork
        }

        private enum CodingKeys: String, CodingKey {
            case version, tracks, playlists, artwork
            /// v1 only: the per-collection snapshots that are derived now.
            case collections
        }

        private enum WriteKeys: String, CodingKey {
            case version, tracks, playlists, artwork
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: WriteKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(tracks, forKey: .tracks)
            try container.encode(playlists, forKey: .playlists)
            try container.encode(artwork, forKey: .artwork)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            loadedVersion = version
            let tracks = try container.decodeIfPresent([String: DownloadStore.Entry].self, forKey: .tracks) ?? [:]
            var playlists = try container.decodeIfPresent([String: DownloadStore.PlaylistRecord].self, forKey: .playlists) ?? [:]
            let artwork = try container.decodeIfPresent([String: DownloadStore.ArtworkEntry].self, forKey: .artwork) ?? [:]
            // v1 stored a snapshot of every downloaded collection. Albums,
            // artists and genres are derived from the songs now, so only
            // playlists carry over — their membership becomes a record built
            // from the files that still reference them.
            if version < 2, let collections = try container.decodeIfPresent([String: BaseItemDto].self, forKey: .collections) {
                for (id, item) in collections where item.itemType == .playlist && playlists[id] == nil {
                    playlists[id] = DownloadStore.PlaylistRecord(
                        id: id,
                        title: item.displayName,
                        trackIDs: tracks.values
                            .filter { $0.sources.contains(id) }
                            .sorted { $0.order < $1.order }
                            .compactMap(\.track.id),
                        coverTag: item.primaryImageTag,
                        totalSongs: item.childCount
                    )
                }
            }
            self.version = DownloadStore.manifestVersion
            self.tracks = tracks
            self.playlists = playlists
            self.artwork = artwork
        }
    }

    /// `session` contributes its configuration — which is how a test's stubbed
    /// protocols reach the downloads — while the transfers themselves run on
    /// the store's own ``DownloadSession``, the one that can report progress.
    init(directory: URL? = nil, session: URLSession = .shared) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = directory ?? support.appending(path: "Downloads", directoryHint: .isDirectory)
        self.directory = dir
        self.artworkDirectory = dir.appending(path: "Artwork", directoryHint: .isDirectory)
        self.manifestURL = dir.appending(path: "manifest.json")
        self.downloadSession = DownloadSession(configuration: session.configuration)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL) {
            do {
                let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                entries = manifest.tracks
                playlists = manifest.playlists
                artworkEntries = manifest.artwork
                // Older manifests keyed artwork per image tag (v1) or per song
                // (v2), neither of which an album view can predict. Fold them onto
                // the album's own image pair and reclaim the duplicate files.
                if manifest.loadedVersion < Self.manifestVersion {
                    let migrated = migratingArtwork(manifest.artwork, tracks: manifest.tracks)
                    if migrated != manifest.artwork {
                        artworkEntries = migrated
                        persist()
                    }
                }
            } catch {
                // A manifest that will not read is every download the user has:
                // say so, rather than reopening as empty and quietly orphaning
                // the files on disk.
                downloadLog.error("Download manifest could not be read: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Re-keys legacy artwork entries onto ``artworkPair(for:)`'s` canonical
    /// album pair, one entry and one file per album.
    ///
    /// Songs are walked in save order so the first cover saved for an album is
    /// the one that survives; every later image of the same album is consumed
    /// and its file deleted. Entries no song claims — a playlist cover, or art
    /// for a song whose album pair the server never sent — are kept untouched.
    private func migratingArtwork(
        _ loaded: [String: ArtworkEntry],
        tracks: [String: Entry]
    ) -> [String: ArtworkEntry] {
        var rebuilt: [String: ArtworkEntry] = [:]
        var consumed: Set<String> = []

        for entry in tracks.values.sorted(by: { $0.order < $1.order }) {
            guard let trackId = entry.track.id,
                  let pair = Self.artworkPair(for: entry.track)
            else { continue }
            let canonical = Self.artworkKey(ownerID: pair.owner, tag: pair.tag)

            if var existing = rebuilt[canonical] {
                // The album's cover is already folded in; anything else this
                // song points at is a duplicate image of it.
                if let duplicate = firstUsableArtworkKey(Self.legacyArtworkKeys(for: entry.track), in: loaded, skipping: consumed),
                   duplicate != canonical {
                    consumed.insert(duplicate)
                    deleteArtworkFile(loaded[duplicate]?.filename)
                }
                existing.requiredBy.insert(trackId)
                rebuilt[canonical] = existing
                continue
            }

            // An entry already written canonically is adopted as-is; otherwise
            // the first legacy spelling this song could have been saved under
            // becomes the album's entry, keeping the file it already points at.
            if let already = loaded[canonical] {
                var adopted = already
                adopted.requiredBy.insert(trackId)
                rebuilt[canonical] = adopted
                consumed.insert(canonical)
                continue
            }
            let candidates = [canonical] + Self.legacyArtworkKeys(for: entry.track)
            if let legacy = firstUsableArtworkKey(candidates, in: loaded, skipping: consumed),
               var carried = loaded[legacy] {
                carried.ownerItemID = pair.owner
                carried.imageTag = pair.tag
                carried.requiredBy.insert(trackId)
                rebuilt[canonical] = carried
                consumed.insert(legacy)
            }
        }

        // Anything no song claimed stays exactly as it was; anything a song
        // claimed under a different key than the surviving one is gone.
        for (key, artwork) in loaded where !consumed.contains(key) && rebuilt[key] == nil {
            rebuilt[key] = artwork
        }
        return rebuilt
    }

    /// The keys a legacy manifest could have saved this song's artwork under,
    /// most album-like first and in a stable order: v2 paired the album id with
    /// the song's own image tag, v1 keyed files by tag alone.
    static func legacyArtworkKeys(for track: BaseItemDto) -> [String] {
        let owners = [track.albumID, track.id].compactNamed()
        let tags = [track.albumPrimaryImageTag, track.primaryImageTag].compactNamed()
        var keys: [String] = []
        for owner in owners {
            for tag in tags { keys.append(artworkKey(ownerID: owner, tag: tag)) }
        }
        keys.append(contentsOf: tags)
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// The first candidate key that has an entry and has not been folded away,
    /// preferring one whose file is still on disk so a lost duplicate cannot
    /// become an album's surviving entry.
    private func firstUsableArtworkKey(
        _ candidates: [String],
        in loaded: [String: ArtworkEntry],
        skipping consumed: Set<String>
    ) -> String? {
        let usable = candidates.filter { loaded[$0] != nil && !consumed.contains($0) }
        return usable.first { artworkFileExists(loaded[$0]?.filename) } ?? usable.first
    }

    private func artworkFileExists(_ filename: String?) -> Bool {
        guard let filename else { return false }
        return FileManager.default.fileExists(atPath: artworkDirectory.appending(path: filename).path)
    }

    private func deleteArtworkFile(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: artworkDirectory.appending(path: filename))
    }

    /// Removes every download: all files, entries and playlist records.
    func removeAll() {
        for entry in entries.values {
            try? FileManager.default.removeItem(at: directory.appending(path: entry.filename))
        }
        for artwork in artworkEntries.values {
            try? FileManager.default.removeItem(at: artworkDirectory.appending(path: artwork.filename))
        }
        entries = [:]
        playlists = [:]
        artworkEntries = [:]
        persist()
    }

    /// Points the store at a new session. Downloaded files are kept.
    func configure(client: JellyfinService?) {
        guard client !== self.client else { return }
        self.client = client
        errorMessage = nil
    }

    // MARK: - Queries

    /// Whether a downloaded copy of `item` is available: the file for a track,
    /// a saved membership record for a playlist, any saved file requiring this
    /// album or genre, and any explicitly downloaded album for an artist.
    ///
    /// Collections answer from *sources*, not from group membership: a song
    /// that surfaced an album by arriving in a playlist does not make that
    /// album downloaded — the toggle still offers to finish it.
    func isDownloaded(_ item: BaseItemDto) -> Bool {
        guard let id = item.id else { return false }
        switch item.itemType {
        case .audio:
            return entries[id] != nil
        case .playlist:
            return playlists[id] != nil
        case .musicArtist:
            return downloadedAlbums(forArtistID: id).contains { $0.isExplicit }
        default:
            return entries.values.contains { $0.sources.contains(id) }
        }
    }

    /// Whether a download for `item` is in flight.
    func isBusy(_ item: BaseItemDto) -> Bool {
        guard let id = item.id else { return false }
        return batches.contains { $0.id == id }
    }

    /// Song counts across every running batch, or `nil` while nothing is
    /// downloading. Totals grow as collections resolve their track lists.
    var activeDownloadProgress: DownloadProgress? {
        guard !batches.isEmpty else { return nil }
        return DownloadProgress(
            completed: batches.reduce(0) { $0 + $1.completed + $1.failed },
            total: batches.reduce(0) { $0 + $1.total }
        )
    }

    /// Live download throughput as of `now`, or `nil` when no bytes have
    /// landed within the tracker's window. Safe to call from any context so
    /// the status bar can re-read it on its own tick.
    nonisolated func downloadBytesPerSecond(asOf now: Date = Date()) -> Double? {
        downloadSession.bytesPerSecond(asOf: now)
    }

    /// The saved file for `itemId`, or `nil` when it has not been downloaded.
    func localURL(forItemId id: String) -> URL? {
        guard let filename = entries[id]?.filename else { return nil }
        return existingFile(in: directory, named: filename)
    }

    /// The saved artwork file for `item`, or `nil` when there is none.
    ///
    /// Resolution follows ``artworkPair(for:)``'s priority — a song and its
    /// album both land on the album's cover — then falls back to the spellings
    /// older manifests used, so artwork saved before a migration still shows
    /// instead of blanking.
    func localArtworkURL(for item: BaseItemDto) -> URL? {
        artworkURL(forAnyOf: Self.artworkKeys(for: item))
    }

    /// The saved artwork file for a downloaded group. Artists have no image of
    /// their own on disk, so a group carries the candidate keys of the album it
    /// borrowed its cover from, in the same order ``localArtworkURL(for:)``
    /// tries them.
    func localArtworkURL(for group: DownloadGroup) -> URL? {
        artworkURL(forAnyOf: group.artworkKeys)
    }

    /// The songs saved for a group: playlist order for a playlist, download
    /// order for everything else (album rows are disc/track sorted by the
    /// screen that shows them).
    func tracks(in group: DownloadGroup) -> [BaseItemDto] {
        switch group.kind {
        case .playlist:
            guard let record = playlists[group.id] else { return [] }
            return record.trackIDs.compactMap { entries[$0]?.track }
        case .album, .artist, .genre:
            return songsMatchingGroupID(group.id, kind: group.kind).sorted { $0.order < $1.order }.map(\.track)
        }
    }

    /// The songs saved for the group an item names, by its type and id. A song
    /// resolves to itself.
    func tracks(for item: BaseItemDto) -> [BaseItemDto] {
        guard let id = item.id else { return [] }
        guard let kind = Self.groupKind(of: item) else { return [item] }
        if kind == .playlist, let record = playlists[id] {
            return record.trackIDs.compactMap { entries[$0]?.track }
        }
        return songsMatchingGroupID(id, kind: kind).sorted { $0.order < $1.order }.map(\.track)
    }

    /// The playlists saved for offline listening, name-sorted. A record whose
    /// songs have all been deleted still lists, showing none downloaded — the
    /// membership is the download, and its cover came with it.
    func downloadedPlaylists() -> [DownloadGroup] {
        playlists.values.map { record in
            DownloadGroup(
                id: record.id,
                kind: .playlist,
                title: record.title,
                item: BaseItemDto(
                    childCount: record.totalSongs,
                    id: record.id,
                    imageTags: record.coverTag.map { [ImageType.primary.rawValue: $0] },
                    name: record.title,
                    type: .playlist
                ),
                downloadedSongs: record.trackIDs.filter { entries[$0] != nil }.count,
                totalSongs: record.totalSongs,
                isExplicit: true,
                artworkKeys: Self.artworkKeys(ownID: record.id, tag: record.coverTag),
                artistKeys: []
            )
        }
        .sorted { $0.title < $1.title }
    }

    /// The albums behind the downloaded songs, grouped from each track's own
    /// album attribution and name-sorted. Includes albums that surfaced from a
    /// single song, reported partially downloaded.
    func downloadedAlbums() -> [DownloadGroup] {
        var members: [String: [Entry]] = [:]
        for entry in entries.values {
            guard let key = Self.albumKey(of: entry.track) else { continue }
            members[key, default: []].append(entry)
        }
        return members.map { key, group in
            let sorted = group.sorted { $0.order < $1.order }
            let lead = sorted.first?.track ?? BaseItemDto()
            let total = group.compactMap(\.albumSongCount).max()
            let keys = Set(group.flatMap(\.artistKeys))
            return DownloadGroup(
                id: key,
                kind: .album,
                title: lead.album ?? key,
                item: Self.albumItem(key: key, members: sorted, total: total, artistKeys: keys),
                downloadedSongs: group.count,
                totalSongs: total,
                isExplicit: group.contains { $0.sources.contains(key) },
                artworkKeys: Self.artworkKeys(for: lead),
                artistKeys: keys.isEmpty ? Set([lead.albumArtist].compactNamed()) : keys
            )
        }
        .sorted { $0.title < $1.title }
    }

    /// The artists behind the downloaded songs, derived from each album's
    /// attribution rather than stored — so downloading any song of an artist's
    /// surfaces them here, and removing the last one drops them again.
    func downloadedArtists() -> [DownloadGroup] {
        var albumsByArtist: [String: [DownloadGroup]] = [:]
        for album in downloadedAlbums() {
            for key in album.artistKeys {
                albumsByArtist[key, default: []].append(album)
            }
        }
        return albumsByArtist.compactMap { key, albums in
            // An artist's artwork is one of their albums' covers: artists have
            // no image of their own saved, and borrowing one costs no request.
            // An artist's cover is one of their albums': the first album that
            // has anywhere to look, which after migration is every one of them.
            guard let lead = albums.first(where: { !$0.artworkKeys.isEmpty }) ?? albums.first else { return nil }
            let name = lead.item.artistNameForGroup ?? key
            return DownloadGroup(
                id: key,
                kind: .artist,
                title: name,
                item: BaseItemDto(id: key, name: name, type: .musicArtist),
                downloadedSongs: albums.reduce(0) { $0 + $1.downloadedSongs },
                totalSongs: nil,
                isExplicit: albums.contains { $0.isExplicit },
                artworkKeys: lead.artworkKeys,
                artistKeys: [key]
            )
        }
        .sorted { $0.title < $1.title }
    }

    /// The downloaded albums attributed to `artistID` — an id, or an artist name
    /// where the server attributed albums by name — name-sorted.
    func downloadedAlbums(forArtistID artistID: String) -> [DownloadGroup] {
        downloadedAlbums().filter { $0.artistKeys.contains(artistID) }
    }

    /// The groups of a kind the downloads section lists.
    func groups(kind: GroupKind) -> [DownloadGroup] {
        switch kind {
        case .album: downloadedAlbums()
        case .artist: downloadedArtists()
        case .playlist: downloadedPlaylists()
        case .genre: []
        }
    }

    /// A group by id and kind, or `nil` when nothing in it is downloaded any
    /// more (playlists by id always resolve while their record exists).
    func group(id: String, kind: GroupKind) -> DownloadGroup? {
        groups(kind: kind).first { $0.id == id }
    }

    /// Every downloaded song, newest download first.
    func downloadedSongs() -> [BaseItemDto] {
        entries.values.sorted { $0.order > $1.order }.map(\.track)
    }

    // MARK: - Downloading

    /// Downloads `item`: a track saves its file referencing itself; an artist
    /// downloads each of their albums; an album, genre or other collection
    /// resolves its tracks and saves each one referencing the collection; a
    /// playlist additionally saves its offline membership and cover. Files
    /// already on disk only gain the reference, which is how overlapping
    /// downloads dedupe.
    func download(_ item: BaseItemDto) {
        guard let client else {
            errorMessage = JellyfinError.notAuthenticated.errorDescription
            return
        }
        guard let id = item.id else {
            errorMessage = JellyfinError.missingItemIdentifier.errorDescription
            return
        }
        guard !isBusy(item) else { return }

        switch item.itemType {
        case .audio:
            var batch = Batch(id: id)
            batch.total = 1
            batches.append(batch)
            Task {
                await downloadOne(
                    item,
                    source: id,
                    batchId: id,
                    via: client,
                    albumSongCount: nil,
                    artistKeys: Self.artistKeys(of: item)
                )
                finishBatch(id)
            }
        case .musicArtist:
            batches.append(Batch(id: id))
            Task {
                do {
                    let albums = try await client.albums(forArtistId: id)
                    guard !albums.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
                    for album in albums {
                        await downloadCollection(album, into: id, via: client)
                    }
                } catch {
                    if !error.isCancellation {
                        errorMessage = "Couldn’t download “\(item.displayName)”. \(error.userFacingMessage)"
                    }
                }
                finishBatch(id)
            }
        case .playlist:
            batches.append(Batch(id: id))
            Task {
                do {
                    let tracks = try await client.tracks(for: item)
                    guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
                    updateBatch(id) { $0.total = tracks.count }
                    var trackIDs: [String] = []
                    for track in tracks {
                        if let trackId = track.id, !trackIDs.contains(trackId) { trackIDs.append(trackId) }
                        await downloadOne(
                            track,
                            source: id,
                            batchId: id,
                            via: client,
                            albumSongCount: nil,
                            artistKeys: Self.artistKeys(of: track)
                        )
                    }
                    playlists[id] = PlaylistRecord(
                        id: id,
                        title: item.displayName,
                        trackIDs: trackIDs,
                        // A re-download from the offline detail carries a
                        // stand-in item with no image tags; keep the cover that
                        // is already saved rather than dropping it.
                        coverTag: item.primaryImageTag ?? playlists[id]?.coverTag,
                        // Counted as the membership is stored, deduplicated, so
                        // "n of m" always compares like with like.
                        totalSongs: trackIDs.count
                    )
                    // The playlist's own cover, saved under the playlist id so
                    // the offline header never needs the server.
                    await downloadArtwork(
                        ownerID: id,
                        imageTag: item.primaryImageTag ?? playlists[id]?.coverTag,
                        holderID: id,
                        via: client
                    )
                    persist()
                } catch {
                    if !error.isCancellation {
                        errorMessage = "Couldn’t download “\(item.displayName)”. \(error.userFacingMessage)"
                    }
                }
                finishBatch(id)
            }
        default:
            batches.append(Batch(id: id))
            Task {
                await downloadCollection(item, into: id, via: client)
                finishBatch(id)
            }
        }
    }

    /// Re-pulls a downloaded playlist's membership: songs added since it was
    /// saved are downloaded, songs removed from the playlist give up their
    /// reference, and the record is replaced. Files another download still
    /// requires are kept.
    func refreshPlaylist(_ id: String) {
        guard let client, let existing = playlists[id] else { return }
        guard !batches.contains(where: { $0.id == id }) else { return }
        batches.append(Batch(id: id))
        Task {
            do {
                let stub = BaseItemDto(id: id, name: existing.title, type: .playlist)
                let tracks = try await client.tracks(for: stub)
                guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(existing.title) }
                updateBatch(id) { $0.total = tracks.count }
                var trackIDs: [String] = []
                for track in tracks {
                    if let trackId = track.id, !trackIDs.contains(trackId) { trackIDs.append(trackId) }
                    await downloadOne(
                        track,
                        source: id,
                        batchId: id,
                        via: client,
                        albumSongCount: nil,
                        artistKeys: Self.artistKeys(of: track)
                    )
                }
                for dropped in existing.trackIDs where !trackIDs.contains(dropped) {
                    unreference(dropped, source: id)
                }
                playlists[id] = PlaylistRecord(
                    id: id,
                    title: existing.title,
                    trackIDs: trackIDs,
                    coverTag: existing.coverTag,
                    totalSongs: trackIDs.count
                )
                deleteUnreferenced()
                persist()
            } catch {
                if !error.isCancellation {
                    errorMessage = "Couldn’t refresh “\(existing.title)”. \(error.userFacingMessage)"
                }
            }
            finishBatch(id)
        }
    }

    /// Removes the download for `item`. A song deletes its file everywhere it
    /// appeared. An artist removes every album downloaded for them; any other
    /// collection unreferences every song it required, and songs requiring
    /// nothing more are deleted in the sweep afterwards.
    func remove(_ item: BaseItemDto) {
        guard let id = item.id else { return }
        switch item.itemType {
        case .audio:
            deleteSong(id)
        case .musicArtist:
            for album in downloadedAlbums(forArtistID: id) {
                removeGroup(album.id, kind: .album)
            }
            deleteUnreferenced()
            persist()
        default:
            removeGroup(id, kind: Self.groupKind(of: item) ?? .album)
            deleteUnreferenced()
            persist()
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Internals

    /// Downloads every track of a collection (album, genre, anything else with
    /// children), each file referencing the collection. An album's songs also
    /// gain the album's track count and attribution, which is what lets the
    /// album view be derived from them later.
    private func downloadCollection(_ item: BaseItemDto, into batchId: String, via client: JellyfinService) async {
        guard let id = item.id else { return }
        do {
            let tracks = try await client.tracks(for: item)
            guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
            let isAlbum = item.itemType == .musicAlbum
            let collectionKeys = Self.artistKeys(of: item)
            updateBatch(batchId) { $0.total += tracks.count }
            for track in tracks {
                // An album's songs are stored with the album's own attribution
                // filled in, so the derived album view and the download
                // reference agree on the album's id.
                let stored = isAlbum ? Self.completingAlbumFields(of: track, from: item) : track
                // The song's own attribution wins: its id-bearing `AlbumArtists`
                // and a name-only `AlbumArtist` would otherwise surface the same
                // artist under two keys. The collection is the fallback for
                // songs that say nothing.
                let trackKeys = Self.artistKeys(of: stored)
                await downloadOne(
                    stored,
                    source: id,
                    batchId: batchId,
                    via: client,
                    albumSongCount: isAlbum ? tracks.count : nil,
                    artistKeys: trackKeys.isEmpty ? collectionKeys : trackKeys
                )
            }
        } catch {
            if !error.isCancellation {
                errorMessage = "Couldn’t download “\(item.displayName)”. \(error.userFacingMessage)"
            }
        }
    }

    /// Fills a song's album attribution from the album it was fetched with, when
    /// the server left it out. The album view is grouped from the saved snapshot,
    /// so a song stored without its album id would surface under a name-derived
    /// group its own download reference doesn't match — untoggleable and
    /// unremovable.
    static func completingAlbumFields(of track: BaseItemDto, from album: BaseItemDto) -> BaseItemDto {
        var completed = track
        if completed.albumID?.isEmpty != false { completed.albumID = album.id }
        if completed.album?.isEmpty != false { completed.album = album.name }
        if completed.albumPrimaryImageTag?.isEmpty != false, let tag = album.primaryImageTag {
            completed.albumPrimaryImageTag = tag
        }
        if completed.albumArtist?.isEmpty != false { completed.albumArtist = album.albumArtist }
        if (completed.albumArtists ?? []).isEmpty { completed.albumArtists = album.albumArtists }
        if completed.productionYear == nil { completed.productionYear = album.productionYear }
        return completed
    }

    private func downloadOne(
        _ track: BaseItemDto,
        source: String,
        batchId: String,
        via client: JellyfinService,
        albumSongCount: Int?,
        artistKeys: Set<String>
    ) async {
        guard let id = track.id else {
            updateBatch(batchId) { $0.failed += 1 }
            return
        }
        // Already saved: just gain the new reference, no second copy.
        if var entry = entries[id] {
            entry.sources.insert(source)
            if entry.albumSongCount == nil { entry.albumSongCount = albumSongCount }
            entry.artistKeys.formUnion(artistKeys)
            entries[id] = entry
            referenceArtwork(for: track, trackId: id)
            persist()
            updateBatch(batchId) { $0.completed += 1 }
            return
        }
        do {
            let remote = try client.streamURL(itemId: id, mediaSourceId: track.mediaSourceID)
            let (tempFile, response) = try await downloadSession.download(from: remote)
            // `URLSession` happily downloads an error page as if it were audio,
            // so an HTTP failure must be caught here.
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw JellyfinError.downloadFailed(
                    reason: (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "unknown response"
                )
            }
            // `AVURLAsset` leans on the file extension to pick a parser, so
            // the saved name carries the track's container.
            let ext = (track.container ?? track.mediaSources?.first?.container ?? "mp3")
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let filename = "\(id).\(ext.isEmpty ? "mp3" : ext)"
            let destination = directory.appending(path: filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempFile, to: destination)
            entries[id] = Entry(
                track: track,
                filename: filename,
                order: (entries.values.map(\.order).max() ?? 0) + 1,
                sources: [source],
                albumSongCount: albumSongCount,
                artistKeys: artistKeys
            )
            // The song's cover is the album's, and the same pair is used to
            // request it, key it and resolve it — so one file serves every song
            // of the album, and the album and artist views can predict the key.
            if let pair = Self.artworkPair(for: track) {
                await downloadArtwork(ownerID: pair.owner, imageTag: pair.tag, holderID: id, via: client)
            }
            persist()
            updateBatch(batchId) { $0.completed += 1 }
        } catch {
            if !error.isCancellation {
                playbackLogDownloadFailure(track, error)
            }
            updateBatch(batchId) { $0.failed += 1 }
        }
    }

    /// Downloads and saves one artwork file, deduplicated by the item that owns
    /// the image plus its tag. Awaited by the caller but fire-and-forget in
    /// spirit: failures are silent, because audio is the priority and the
    /// header falls back to a placeholder.
    private func downloadArtwork(
        ownerID: String?,
        imageTag: String?,
        holderID: String,
        via client: JellyfinService
    ) async {
        guard let imageTag, !imageTag.isEmpty else { return }

        // Already have this artwork — including a tag-only entry carried over
        // from a v1 manifest, which is the same picture: just add the reference
        // rather than saving a second copy.
        if referenceExistingArtwork(ownerID: ownerID, imageTag: imageTag, holderID: holderID) {
            persist()
            return
        }

        guard let artworkUrl = client.artworkURL(
            itemId: ownerID,
            tag: imageTag,
            maxWidth: 500,
            maxHeight: 500,
            quality: 90,
            type: .primary
        ) else { return }

        do {
            let (tempFile, response) = try await downloadSession.download(from: artworkUrl)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            // Saved as JPG (the format requested), namespaced by its owner so
            // two items sharing an image tag can't overwrite each other.
            let stem = ownerID.map { "\($0)-\(imageTag)" } ?? imageTag
            let filename = "\(stem).jpg"
            let destination = artworkDirectory.appending(path: filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempFile, to: destination)
            let entry = ArtworkEntry(
                filename: filename,
                ownerItemID: ownerID,
                imageTag: imageTag,
                requiredBy: [holderID]
            )
            artworkEntries[entry.key] = entry
            persist()
        } catch {
            // Artwork is optional; a missing cover is a placeholder, not an error.
        }
    }

    /// Adds a reference to artwork already on disk for this owner and tag: the
    /// owner-keyed entry first, then a bare-tag entry from a v1 manifest.
    /// Returns whether anything was found to reference.
    @discardableResult
    private func referenceExistingArtwork(ownerID: String?, imageTag: String, holderID: String) -> Bool {
        for key in [Self.artworkKey(ownerID: ownerID, tag: imageTag), imageTag] {
            guard var artworkEntry = artworkEntries[key] else { continue }
            artworkEntry.requiredBy.insert(holderID)
            artworkEntries[key] = artworkEntry
            return true
        }
        return false
    }

    /// Adds a reference to artwork already on disk, for a track that only gained
    /// a source. Every key the song's cover could be filed under is tried, most
    /// canonical first, so a legacy spelling gains its reference instead of a
    /// second file being saved beside it.
    private func referenceArtwork(for track: BaseItemDto, trackId: String) {
        for key in Self.artworkKeys(for: track) {
            guard var artworkEntry = artworkEntries[key] else { continue }
            artworkEntry.requiredBy.insert(trackId)
            artworkEntries[key] = artworkEntry
            return
        }
    }

    /// Removes a song's file, its artwork reference, and its place in every
    /// downloaded playlist — deleting a song is a deliberate, global act.
    private func deleteSong(_ id: String) {
        guard let entry = entries[id] else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: entry.filename))
        unreferenceArtwork(trackId: id)
        entries[id] = nil
        for (playlistID, record) in playlists where record.trackIDs.contains(id) {
            var updated = record
            updated.trackIDs.removeAll { $0 == id }
            playlists[playlistID] = updated
        }
        deleteUnreferenced()
        persist()
    }

    /// Drops one source from a song; the sweep afterwards deletes whatever
    /// nothing requires any more.
    private func unreference(_ trackId: String, source: String) {
        guard var entry = entries[trackId] else { return }
        entry.sources.remove(source)
        entries[trackId] = entry
    }

    /// Removes a group's reference from every song in it. A playlist also loses
    /// its record and its cover reference.
    private func removeGroup(_ id: String, kind: GroupKind) {
        switch kind {
        case .playlist:
            guard let record = playlists[id] else { return }
            for trackID in record.trackIDs {
                unreference(trackID, source: id)
            }
            unreferenceArtwork(holderID: id)
            playlists[id] = nil
        case .album, .artist, .genre:
            for trackID in songsMatchingGroupID(id, kind: kind).compactMap(\.track.id) {
                unreference(trackID, source: id)
            }
        }
    }

    /// Drops a song's reference from every entry its cover could be filed
    /// under, so a legacy duplicate cannot keep a stale reference that stops the
    /// sweep reclaiming it.
    private func unreferenceArtwork(trackId: String) {
        guard let entry = entries[trackId] else { return }
        for key in Self.artworkKeys(for: entry.track) {
            guard var artworkEntry = artworkEntries[key] else { continue }
            artworkEntry.requiredBy.remove(trackId)
            artworkEntries[key] = artworkEntry
        }
    }

    /// Drops a reference held by a non-track holder — a playlist's own cover.
    private func unreferenceArtwork(holderID: String) {
        for (key, var artworkEntry) in artworkEntries where artworkEntry.requiredBy.contains(holderID) {
            artworkEntry.requiredBy.remove(holderID)
            artworkEntries[key] = artworkEntry
        }
    }

    private func playbackLogDownloadFailure(_ track: BaseItemDto, _ error: Error) {
        errorMessage = "Couldn’t download “\(track.displayName)”. \(error.userFacingMessage)"
    }

    private func finishBatch(_ id: String) {
        if let batch = batches.first(where: { $0.id == id }), batch.failed > 0, errorMessage == nil {
            errorMessage = batch.total == 1
                ? nil // The per-file message already named the one track.
                : "Couldn’t download \(batch.failed) of \(batch.total) tracks."
        }
        batches.removeAll { $0.id == id }
        deleteUnreferenced()
        persist()
    }

    private func updateBatch(_ id: String, _ change: (inout Batch) -> Void) {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        change(&batches[index])
    }

    /// The sweep that follows a removal: delete the files and entries of songs
    /// no download requires any more, and the artwork no song or playlist cover
    /// references.
    private func deleteUnreferenced() {
        for (id, entry) in entries where entry.sources.isEmpty {
            try? FileManager.default.removeItem(at: directory.appending(path: entry.filename))
            unreferenceArtwork(trackId: id)
            entries[id] = nil
        }
        for (key, artworkEntry) in artworkEntries where artworkEntry.requiredBy.isEmpty {
            try? FileManager.default.removeItem(at: artworkDirectory.appending(path: artworkEntry.filename))
            artworkEntries[key] = nil
        }
    }

    // MARK: - Grouping

    /// The kind of group an item names, or `nil` for a plain song. An item of
    /// any other type is treated as a collection keyed by its own id.
    static func groupKind(of item: BaseItemDto) -> GroupKind? {
        switch item.itemType {
        case .audio: nil
        case .musicAlbum: .album
        case .musicArtist: .artist
        case .playlist: .playlist
        case let type? where type.isGenre: .genre
        default: .album
        }
    }

    /// The key a track's album groups under: the server's album id when it sent
    /// one, the album name otherwise.
    static func albumKey(of track: BaseItemDto) -> String? {
        if let albumID = track.albumID, !albumID.isEmpty { return albumID }
        if let album = track.album, !album.isEmpty { return album }
        return nil
    }

    /// The artist keys an item is attributed to: ids when the server sent them,
    /// otherwise album-artist or track-artist names. Album attribution wins, so
    /// a various-artists compilation groups under its album artist rather than
    /// exploding into one artist per song.
    static func artistKeys(of item: BaseItemDto) -> Set<String> {
        let albumPairs = item.albumArtists ?? []
        let pairs = albumPairs.isEmpty ? (item.artistItems ?? []) : albumPairs
        let named = Set(pairs.compactMap { $0.id ?? $0.name }.compactNamed())
        if !named.isEmpty { return named }
        return Set([item.albumArtist, item.artists?.first].compactNamed())
    }

    private func songsMatchingGroupID(_ id: String, kind: GroupKind) -> [Entry] {
        entries.values.filter { entry in
            switch kind {
            case .playlist, .genre:
                entry.sources.contains(id)
            case .album:
                Self.albumKey(of: entry.track) == id || entry.sources.contains(id)
            case .artist:
                entry.artistKeys.contains(id)
            }
        }
    }

    /// A display item for a downloaded album, assembled from its songs: name,
    /// attribution, year and the image tag its artwork was saved under.
    private static func albumItem(key: String, members: [Entry], total: Int?, artistKeys: Set<String>) -> BaseItemDto {
        guard let lead = members.first?.track else {
            return BaseItemDto(id: key, name: key, type: .musicAlbum)
        }
        let pairs = members.flatMap { $0.track.albumArtists ?? [] }
        let year = members.compactMap(\.track.productionYear).min()
        let tag = lead.albumPrimaryImageTag ?? lead.primaryImageTag
        let artistName = lead.albumArtist ?? members.compactMap(\.track.albumArtist).first
            ?? (pairs.isEmpty ? nil : pairs.first?.name)
        return BaseItemDto(
            album: lead.album,
            albumArtist: artistName,
            albumArtists: pairs.isEmpty ? artistName.map({ [NameIDPair(id: artistKeys.first, name: $0)] }) : pairs,
            childCount: total,
            id: key,
            imageTags: tag.map { [ImageType.primary.rawValue: $0] },
            name: lead.album ?? key,
            productionYear: year,
            type: .musicAlbum
        )
    }

    // MARK: - Artwork

    /// The one image that represents `track`, as the pair that owns it.
    ///
    /// Album cover wins: a song's own `ImageTags` entry is its embedded file
    /// art, which for lossless files differs from song to song and would give
    /// every track its own download and its own key. Pairing a track's tag with
    /// the album's id — which v2 did — is the same mistake from the other side,
    /// and is what left album and artist views with nothing to resolve.
    static func artworkPair(for track: BaseItemDto) -> (owner: String, tag: String)? {
        let albumID = track.albumID.nonEmpty
        let albumTag = track.albumPrimaryImageTag.nonEmpty
        if let albumID, let albumTag { return (albumID, albumTag) }
        let ownTag = track.primaryImageTag.nonEmpty ?? albumTag
        if let owner = track.id.nonEmpty ?? albumID, let ownTag { return (owner, ownTag) }
        return nil
    }

    /// Every key `track`'s artwork could be filed under, canonical first, then
    /// the spellings older manifests wrote.
    static func artworkKeys(for track: BaseItemDto) -> [String] {
        var keys: [String] = []
        if let pair = artworkPair(for: track) { keys.append(artworkKey(ownerID: pair.owner, tag: pair.tag)) }
        keys.append(contentsOf: legacyArtworkKeys(for: track))
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// The keys an item's own cover is filed under: its id with its tag, then
    /// the bare tag a v1 manifest used. For albums and playlists, whose artwork
    /// is saved against the item itself.
    static func artworkKeys(ownID: String?, tag: String?) -> [String] {
        let tag = tag.nonEmpty
        var keys: [String] = []
        if let id = ownID.nonEmpty, let tag { keys.append(artworkKey(ownerID: id, tag: tag)) }
        if let tag { keys.append(tag) }
        return keys
    }

    /// Finds the saved artwork file for the first of `keys` that has one.
    private func artworkURL(forAnyOf keys: [String]) -> URL? {
        for key in keys {
            if let url = artworkURL(forKey: key) { return url }
        }
        return nil
    }

    private func artworkURL(forKey key: String) -> URL? {
        guard let filename = artworkEntries[key]?.filename else { return nil }
        return existingFile(in: artworkDirectory, named: filename)
    }

    static func artworkKey(ownerID: String?, tag: String) -> String {
        guard let ownerID, !ownerID.isEmpty else { return tag }
        return "\(ownerID)|\(tag)"
    }

    private func existingFile(in directory: URL, named filename: String) -> URL? {
        let url = directory.appending(path: filename)
        #if os(macOS)
        if #available(macOS 13.0, *) {
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
        }
        #endif
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
        }
        #endif
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func persist() {
        let manifest = Manifest(tracks: entries, playlists: playlists, artwork: artworkEntries)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}

private extension Optional where Wrapped == String {
    /// The string when it holds something, `nil` when it is empty or absent, so
    /// a server's empty image tag reads as no image rather than as a key.
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

private extension Array where Element == String? {
    /// The values that are neither `nil` nor empty, in order.
    func compactNamed() -> [String] {
        compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }
}

extension BaseItemDto {
    /// The album-artist name a downloaded album or artist row shows.
    var artistNameForGroup: String? {
        albumArtists?.first?.name ?? albumArtist ?? artists?.first
    }
}
