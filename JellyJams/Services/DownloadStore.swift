import CryptoKit
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
/// as a song. That reference counting is what keeps "download album, then a
/// playlist overlapping it" from duplicating bytes, and what ``isDownloaded``
/// answers from. Removal deliberately ignores it: removing a download deletes
/// the songs it stands for, whatever else required them. The collections left
/// behind keep listing and report what they still have — a playlist keeps its
/// membership record, and its offline detail warns it is incomplete until its
/// refresh re-pulls the missing songs — so "Remove Download" behaves the same
/// whether the item was downloaded itself or surfaced through another
/// collection.
///
/// Album artwork is downloaded alongside tracks under ``artworkPair(for:)``: the
/// album's id with the *album's* image tag, so one file serves every song of the
/// album and the album, artist and song views all ask for the same key. A song's
/// own `ImageTags` entry is its embedded file art — a different value per song on
/// lossless files — and pairing it with the album id would give each song its own
/// file and leave the album views with nothing to resolve. Artwork follows the
/// same reference counting as audio.
///
/// An artist's picture is saved the same way — under the artist's own id, when
/// the artist is downloaded — and the artist views prefer it, with the borrowed
/// album cover as the fallback for an artist surfaced by songs alone. The
/// sign-in pass ``syncArtistArtwork()`` keeps the pictures honest both ways:
/// downloads saved before pictures came with artists gain theirs, and a picture
/// whose artist is no longer downloaded is reclaimed.
///
/// Nothing in the browse path (`groups`, `tracks`, `localURL`, `localArtworkURL`)
/// touches the network or needs a signed-in session: the manifest holds every
/// byte of metadata those screens render. It is rewritten after every change, so
/// downloads survive relaunches, and deliberately survives sign-out too —
/// offline listening is the point.
///
/// Transfers survive the app too. On iOS they run on a background session:
/// they continue while the app is suspended, and the system finishes them even
/// if the app dies, delivering the files to the next launch, which adopts them
/// and resumes every batch the manifest recorded as active. Removals always
/// win against downloads: deleting cancels the batches it covers, and a
/// cancelled transfer's file is discarded rather than resurrecting what was
/// just deleted.
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
        /// The saved file's size in bytes, measured as it landed — what the
        /// space totals report, so browsing never stats the disk. `nil` in a
        /// manifest saved before sizes were recorded; the load-time backfill
        /// measures those files once.
        var fileSize: Int64?
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
            case track, filename, fileSize, order, albumSongCount, artistKeys
            case sources = "requiredBy"
        }

        init(
            track: BaseItemDto,
            filename: String,
            fileSize: Int64? = nil,
            order: Int,
            sources: Set<String>,
            albumSongCount: Int? = nil,
            artistKeys: Set<String> = []
        ) {
            self.track = track
            self.filename = filename
            self.fileSize = fileSize
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
            fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
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
        /// for a playlist cover, the artist for their picture. `nil` for
        /// artwork saved by a v1 manifest, which keyed files by tag alone.
        var ownerItemID: String?
        var imageTag: String
        /// Track ids — and playlist or artist ids, for a collection's own
        /// cover or picture — that require this artwork.
        var requiredBy: Set<String>
        /// The saved image's size in bytes; see ``Entry/fileSize``.
        var fileSize: Int64? = nil

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

    /// One transfer in flight, recorded so a completion nobody is waiting for
    /// can still be filed.
    ///
    /// iOS runs transfers on a background session: the system finishes them
    /// even if the app dies, and delivers the file when the store next creates
    /// its session — by which point no `downloadOne` is left to receive it.
    /// The record carries everything needed to file the delivered file the way
    /// the transfer would have. It is keyed by a hash of the request URL — the
    /// one thing the system echoes back that identifies the transfer — because
    /// stream and image URLs carry the access token and the manifest must not.
    enum PendingTransfer: Codable, Sendable {
        case audio(
            track: BaseItemDto,
            filename: String,
            source: String,
            batchId: String,
            albumSongCount: Int?,
            artistKeys: Set<String>
        )
        case artwork(ownerID: String?, imageTag: String, filename: String, holderID: String)
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
        /// album's own pair, an artist their saved picture with the borrowed
        /// pair of one of their albums behind it, a playlist its saved cover —
        /// followed by the spellings older manifests used, so artwork saved
        /// before a migration still shows.
        let artworkKeys: [String]
        /// Artist attribution for an album group; empty for playlists.
        let artistKeys: Set<String>
        /// The newest fetch order among the group's songs on disk — what the
        /// Downloads grids' "Recently Downloaded" sort orders groups by. An
        /// artist is as recent as its newest album; a group whose songs have
        /// all been deleted holds 0.
        let mostRecentOrder: Int

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

    /// Whether an artist-artwork sync is running — the sign-in one or the one
    /// the Downloads artist tab's refresh button starts. Drives that button's
    /// spinner and disabled state.
    @Published private(set) var isSyncingArtistArtwork = false

    /// Every file transfer, feeding the throughput the downloads status bar
    /// shows.
    private let downloadSession: DownloadSession

    /// The task running each batch, keyed by batch id, so removals can cancel
    /// them: a download the user has deleted must not keep landing tracks.
    private var batchTasks: [String: Task<Void, Never>] = [:]
    /// The task running ``syncArtistArtwork()``, held so a manual refresh
    /// never overlaps the sign-in sync or an earlier press, and so a wipe can
    /// cancel a run that would otherwise keep landing pictures after it.
    private var artistArtworkTask: Task<Void, Never>?
    /// The item each running batch was started for, persisted so a relaunch
    /// can resume batches whose process died mid-download.
    private var activeBatchItems: [String: BaseItemDto] = [:]
    /// Transfers in flight, keyed by ``pendingKey(for:)`` of their request URL.
    private var pendingTransfers: [String: PendingTransfer] = [:]
    /// Whether the batches a previous process persisted have been resumed
    /// this launch.
    private var hasResumedInterruptedBatches = false

    private var client: JellyfinService?
    private let directory: URL
    private let manifestURL: URL
    private let artworkDirectory: URL

    private nonisolated static let manifestVersion = 4

    private struct Manifest: Codable, Sendable {
        var version: Int
        var tracks: [String: DownloadStore.Entry]
        var playlists: [String: DownloadStore.PlaylistRecord]
        var artwork: [String: DownloadStore.ArtworkEntry]
        var pendingTransfers: [String: DownloadStore.PendingTransfer]
        var activeBatches: [String: BaseItemDto]
        /// The version this manifest was actually written at, which is what
        /// decides whether a load needs migrating. Not encoded: it describes
        /// the file being read, not the one being written.
        var loadedVersion: Int = DownloadStore.manifestVersion

        init(
            tracks: [String: DownloadStore.Entry],
            playlists: [String: DownloadStore.PlaylistRecord],
            artwork: [String: DownloadStore.ArtworkEntry],
            pendingTransfers: [String: DownloadStore.PendingTransfer],
            activeBatches: [String: BaseItemDto]
        ) {
            version = DownloadStore.manifestVersion
            self.tracks = tracks
            self.playlists = playlists
            self.artwork = artwork
            self.pendingTransfers = pendingTransfers
            self.activeBatches = activeBatches
        }

        private enum CodingKeys: String, CodingKey {
            case version, tracks, playlists, artwork, pendingTransfers, activeBatches
            /// v1 only: the per-collection snapshots that are derived now.
            case collections
        }

        private enum WriteKeys: String, CodingKey {
            case version, tracks, playlists, artwork, pendingTransfers, activeBatches
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: WriteKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(tracks, forKey: .tracks)
            try container.encode(playlists, forKey: .playlists)
            try container.encode(artwork, forKey: .artwork)
            try container.encode(pendingTransfers, forKey: .pendingTransfers)
            try container.encode(activeBatches, forKey: .activeBatches)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            loadedVersion = version
            let tracks = try container.decodeIfPresent([String: DownloadStore.Entry].self, forKey: .tracks) ?? [:]
            var playlists = try container.decodeIfPresent([String: DownloadStore.PlaylistRecord].self, forKey: .playlists) ?? [:]
            let artwork = try container.decodeIfPresent([String: DownloadStore.ArtworkEntry].self, forKey: .artwork) ?? [:]
            pendingTransfers = try container.decodeIfPresent([String: DownloadStore.PendingTransfer].self, forKey: .pendingTransfers) ?? [:]
            activeBatches = try container.decodeIfPresent([String: BaseItemDto].self, forKey: .activeBatches) ?? [:]
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

    /// Transfers run on the store's own ``DownloadSession``, the one that can
    /// report progress. An injected `session` contributes its configuration on
    /// every platform — which is how a test's stubbed protocols reach the
    /// downloads, and how the tests run on iOS too. With none injected, iOS
    /// builds a background session, so transfers survive the app being
    /// suspended, and macOS uses the shared configuration.
    init(directory: URL? = nil, session: URLSession? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = directory ?? support.appending(path: "Downloads", directoryHint: .isDirectory)
        self.directory = dir
        self.artworkDirectory = dir.appending(path: "Artwork", directoryHint: .isDirectory)
        self.manifestURL = dir.appending(path: "manifest.json")
        if let session {
            downloadSession = DownloadSession(configuration: session.configuration)
        } else {
            #if os(iOS)
            // Recreating the session under its fixed identifier is what
            // reconnects to transfers the system kept running — or finished —
            // while no store existed to receive them.
            downloadSession = DownloadSession(backgroundIdentifier: DownloadSession.backgroundIdentifier)
            #else
            downloadSession = DownloadSession(configuration: URLSession.shared.configuration)
            #endif
        }
        downloadSession.setOrphanedTransferHandler { [weak self] requestURL, file, statusCode in
            Task { @MainActor in
                self?.adoptOrphanedTransfer(requestURL: requestURL, file: file, statusCode: statusCode)
            }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        loadManifest()
    }

    private func loadManifest() {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            // Nothing has ever been saved.
            return
        } catch {
            quarantineUnreadableManifest(error)
            return
        }
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            entries = manifest.tracks
            playlists = manifest.playlists
            artworkEntries = manifest.artwork
            pendingTransfers = manifest.pendingTransfers
            activeBatchItems = manifest.activeBatches
            var changed = false
            if manifest.loadedVersion < Self.manifestVersion {
                // Albums saved before the manifest carried totals were downloaded
                // whole, so without a backfilled total they would read as forever
                // partial — and the default "complete albums" filter would hide
                // every album an upgraded install has.
                let backfilled = Self.backfillingAlbumTotals(entries)
                if backfilled != entries {
                    entries = backfilled
                    changed = true
                }
                // Older manifests keyed artwork per image tag (v1) or per song
                // (v2), neither of which an album view can predict. Fold them onto
                // the album's own image pair and reclaim the duplicate files.
                let migrated = migratingArtwork(artworkEntries, tracks: entries)
                if migrated != artworkEntries {
                    artworkEntries = migrated
                    changed = true
                }
            }
            // Runs even for a current-version manifest: files saved by an older
            // *build* can sit under a name playback refuses, whatever schema
            // version recorded them.
            if repairingUnplayableFilenames() {
                changed = true
            }
            // Sizes a manifest saved before they were recorded never carried:
            // measured off the files themselves, once.
            if backfillingFileSizes() {
                changed = true
            }
            if changed {
                persist()
            }
        } catch {
            quarantineUnreadableManifest(error)
        }
    }

    /// What a user is told when their downloads record could not be read.
    private nonisolated static let manifestUnreadableMessage =
        "The record of your downloads could not be read, so the library reopened empty. "
        + "The old record was set aside as “manifest.corrupt.json”, and the audio files are "
        + "still on disk — “Delete All” in Downloads clears them."

    /// A manifest that will not read is every download the user has, and the
    /// next download would otherwise persist an empty manifest over it and
    /// destroy the record for good. Move it aside instead — the files stay on
    /// disk and the record stays recoverable by hand — start empty, and say so.
    private func quarantineUnreadableManifest(_ error: Error) {
        downloadLog.error("Download manifest could not be read: \(error.localizedDescription, privacy: .public)")
        let quarantine = directory.appending(path: "manifest.corrupt.json")
        try? FileManager.default.removeItem(at: quarantine)
        try? FileManager.default.moveItem(at: manifestURL, to: quarantine)
        errorMessage = Self.manifestUnreadableMessage
    }

    /// Gives downloaded albums the total a pre-total manifest never carried:
    /// every album downloaded before totals were stored was downloaded as a
    /// whole album, so its songs on disk are the total it was downloaded with.
    /// Only albums that were downloaded as albums gain a total — one that
    /// surfaced because a playlist carried a song of it stays unknown, which
    /// is what keeps the "complete albums" filter honest about borrowed songs.
    private static func backfillingAlbumTotals(_ tracks: [String: Entry]) -> [String: Entry] {
        var members: [String: [String]] = [:]
        var explicit: Set<String> = []
        for (id, entry) in tracks {
            guard let key = albumKey(of: entry.track) else { continue }
            members[key, default: []].append(id)
            if entry.sources.contains(key) { explicit.insert(key) }
        }
        var updated = tracks
        for key in explicit {
            guard let ids = members[key] else { continue }
            for id in ids where updated[id]?.albumSongCount == nil {
                updated[id]?.albumSongCount = ids.count
            }
        }
        return updated
    }

    /// The single filename extension a track is saved under.
    ///
    /// The server reports ffprobe's container name, which for an ambiguous
    /// container is the whole comma-joined family — an Apple Lossless song
    /// arrives as `mov,mp4,m4a,3gp,3g2,mj2`. `AVURLAsset` picks its parser
    /// from the file extension and refuses to open a name it cannot map to a
    /// known format (`kAudioFileEndOfFileError`, "This media format is not
    /// supported") even though the bytes are fine, so the saved name carries
    /// exactly one extension, preferring the family's audio spelling.
    static func fileExtension(forContainer container: String?) -> String {
        let tokens = (container ?? "")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !tokens.isEmpty else { return "mp3" }
        // The audio spellings of the container families, most preferred first;
        // a single-token container always passes through unchanged.
        let audioFirst = [
            "m4a", "m4b", "aac", "mp3", "flac", "ogg", "oga", "opus",
            "wav", "aiff", "aif", "caf", "webm", "mp4", "mov",
        ]
        return audioFirst.first(where: tokens.contains) ?? tokens[0]
    }

    /// Renames saved songs their filename makes unplayable. Downloads saved
    /// before ``fileExtension(forContainer:)`` took the server's container
    /// verbatim, so a song whose container was an ambiguous family list sits
    /// on disk under an extension `AVURLAsset` refuses to open — the bytes
    /// are fine, only the name is wrong. Every entry is re-derived from its
    /// track snapshot and a mismatch is renamed, so an installed album plays
    /// again without a re-download. Pending transfers are rewritten the same
    /// way, so a delivery the system kept across the upgrade is filed under
    /// the playable name. Idempotent: matching names are left alone.
    private func repairingUnplayableFilenames() -> Bool {
        var repaired = false
        for (id, var entry) in entries {
            let expected = Self.filename(trackID: id, container: entry.track.container ?? entry.track.mediaSources?.first?.container)
            guard entry.filename != expected else { continue }
            let saved = directory.appending(path: entry.filename)
            guard FileManager.default.fileExists(atPath: saved.path) else { continue }
            let destination = directory.appending(path: expected)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: saved, to: destination)
            } catch {
                continue
            }
            entry.filename = expected
            entries[id] = entry
            repaired = true
        }
        for (key, transfer) in pendingTransfers {
            guard case let .audio(track, filename, source, batchId, albumSongCount, artistKeys) = transfer,
                  let id = track.id
            else { continue }
            let expected = Self.filename(trackID: id, container: track.container ?? track.mediaSources?.first?.container)
            guard filename != expected else { continue }
            pendingTransfers[key] = .audio(
                track: track,
                filename: expected,
                source: source,
                batchId: batchId,
                albumSongCount: albumSongCount,
                artistKeys: artistKeys
            )
            repaired = true
        }
        return repaired
    }

    /// The name a track's file is saved under: its id with the extension
    /// ``fileExtension(forContainer:)`` derives from its container.
    private static func filename(trackID: String, container: String?) -> String {
        "\(trackID).\(fileExtension(forContainer: container))"
    }

    /// Measures the files a manifest recorded without sizes — the shape every
    /// manifest saved before sizes were recorded has — so the space totals
    /// report honestly after an upgrade without a re-download. A file that is
    /// not on disk keeps `nil` and counts as nothing. Idempotent: entries that
    /// carry a size are left alone.
    private func backfillingFileSizes() -> Bool {
        var backfilled = false
        for (id, var entry) in entries where entry.fileSize == nil {
            guard let size = Self.byteSize(of: directory.appending(path: entry.filename)) else { continue }
            entry.fileSize = size
            entries[id] = entry
            backfilled = true
        }
        for (key, var artwork) in artworkEntries where artwork.fileSize == nil {
            guard let size = Self.byteSize(of: artworkDirectory.appending(path: artwork.filename)) else { continue }
            artwork.fileSize = size
            artworkEntries[key] = artwork
            backfilled = true
        }
        return backfilled
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

    /// Removes every download — always available, even mid-download: running
    /// batches are cancelled first, so nothing they have not finished can land
    /// after the wipe, and batches a relaunch would otherwise resume are
    /// forgotten. Files are deleted by enumeration rather than by record, so
    /// orphans no entry knows about — a quarantined manifest's audio, a
    /// half-adopted transfer — cannot outlive the wipe either.
    func removeAll() {
        for task in batchTasks.values { task.cancel() }
        batchTasks = [:]
        artistArtworkTask?.cancel()
        artistArtworkTask = nil
        isSyncingArtistArtwork = false
        batches = []
        activeBatchItems = [:]
        pendingTransfers = [:]
        entries = [:]
        playlists = [:]
        artworkEntries = [:]
        empty(directory)
        empty(artworkDirectory)
        persist()
    }

    /// Deletes everything inside `directory` and ensures the directory itself
    /// still exists afterwards — `persist` writes its manifest into it.
    private func empty(_ directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Points the store at a new session. Downloaded files are kept.
    func configure(client: JellyfinService?) {
        guard client !== self.client else { return }
        self.client = client
        // Signing in or out clears a stale error — except the manifest
        // warning, which is about the disk, not the session, and which the
        // wiring at launch would otherwise dismiss before any alert showed it.
        if errorMessage != Self.manifestUnreadableMessage {
            errorMessage = nil
        }
        if client != nil {
            resumeInterruptedBatches()
            // Reconciles artist pictures with what is downloaded: fills in the
            // ones saved before pictures came with artists, reclaims the ones
            // whose artist is gone. A no-op once the pictures are in order;
            // retried at the next sign-in if it failed (offline, say).
            startArtistArtworkSync()
        }
    }

    /// Batches a previous process persisted get started again at the first
    /// sign-in. ``download(_:)`` counts tracks already on disk as done without
    /// re-fetching them, so a resume downloads exactly what the interrupted
    /// run did not finish, in whatever order the files arrived.
    private func resumeInterruptedBatches() {
        guard !hasResumedInterruptedBatches else { return }
        hasResumedInterruptedBatches = true
        guard !activeBatchItems.isEmpty else { return }
        let items = Array(activeBatchItems.values)
        // Cleared up front: `download` re-registers every batch it actually
        // starts, so an item it rejects cannot linger as forever-interrupted.
        activeBatchItems = [:]
        for item in items {
            download(item)
        }
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

    /// Whether a downloaded playlist's songs are not all on disk: some were
    /// removed after the membership was saved, or the record knows of more
    /// songs than were ever filed. The offline playlist detail warns while
    /// this is true; its refresh button is what re-pulls the missing songs.
    func isPlaylistIncomplete(_ item: BaseItemDto) -> Bool {
        guard let id = item.id, let record = playlists[id] else { return false }
        let present = record.trackIDs.filter { entries[$0] != nil }.count
        return present < record.trackIDs.count || present < (record.totalSongs ?? 0)
    }

    /// Every byte the downloads occupy on disk: each saved song plus each
    /// saved artwork file, counted once however many collections reference
    /// it. Every Downloads tab's header reports this same total — the tabs
    /// are views over one shared set of files, and per-tab sizes would
    /// double-count a song two collections share.
    var totalByteCount: Int64 {
        entries.values.reduce(0) { $0 + ($1.fileSize ?? 0) }
            + artworkEntries.values.reduce(0) { $0 + ($1.fileSize ?? 0) }
    }

    /// The bytes one downloaded item's files occupy: the songs on disk saved
    /// for it plus the artwork they resolve to. A plain song counts only its
    /// own file — a cover belongs to its album. A song shared with another
    /// collection counts towards both, the way it lists in both.
    func byteCount(for item: BaseItemDto) -> Int64 {
        guard let id = item.id else { return 0 }
        guard let kind = Self.groupKind(of: item) else {
            return entries[id]?.fileSize ?? 0
        }
        var songs: [Entry]
        if kind == .playlist, let record = playlists[id] {
            songs = record.trackIDs.compactMap { entries[$0] }
        } else {
            songs = songsMatchingGroupID(id, kind: kind)
        }
        return songs.reduce(0) { $0 + ($1.fileSize ?? 0) }
            + artworkByteCount(forKeys: Self.artworkKeys(for: item))
    }

    /// The bytes one downloaded group occupies: its songs on disk plus the
    /// cover its artwork keys resolve to. An artist's detail reads this
    /// rather than ``byteCount(for:)`` — the artist's stand-in item carries
    /// no image tag, so only the group knows the picture's key.
    func byteCount(for group: DownloadGroup) -> Int64 {
        tracks(in: group).reduce(Int64(0)) { total, track in
            guard let id = track.id, let entry = entries[id] else { return total }
            return total + (entry.fileSize ?? 0)
        } + artworkByteCount(forKeys: group.artworkKeys)
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

    /// The saved artwork file for a downloaded group. An artist carries its own
    /// picture's keys first — an artist downloaded with a picture has one on
    /// disk — with the album it borrowed its cover from behind them, in the
    /// same order ``localArtworkURL(for:)`` tries them.
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
                artistKeys: [],
                mostRecentOrder: record.trackIDs.compactMap { entries[$0]?.order }.max() ?? 0
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
                artistKeys: keys.isEmpty ? Set([lead.albumArtist].compactNamed()) : keys,
                mostRecentOrder: sorted.last?.order ?? 0
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
            // An artist's artwork is their own picture when one has been
            // saved — it arrived with the artist download, or with the
            // sign-in sync — with the cover of one of their albums behind
            // it: the fallback for an artist surfaced by songs alone. `lead`
            // is the first album that has anywhere to look, which after
            // migration is every one of them.
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
                artworkKeys: artistArtworkKeys(forArtistID: key) + lead.artworkKeys,
                artistKeys: [key],
                mostRecentOrder: albums.map(\.mostRecentOrder).max() ?? 0
            )
        }
        .sorted { $0.title < $1.title }
    }

    /// The manifest keys the artist's own picture is filed under: every entry
    /// the artist item owns, sorted for a deterministic order. Superseding
    /// keeps an artist to one picture, so this is normally empty or a single
    /// key.
    private func artistArtworkKeys(forArtistID id: String) -> [String] {
        artworkEntries
            .filter { $0.value.ownerItemID == id }
            .map { $0.key }
            .sorted()
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

        // Recorded before the first track, so a relaunch can resume the batch
        // even if the process dies immediately.
        activeBatchItems[id] = item
        persist()

        switch item.itemType {
        case .audio:
            var batch = Batch(id: id)
            batch.total = 1
            batches.append(batch)
            batchTasks[id] = Task {
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
            batchTasks[id] = Task {
                do {
                    let albums = try await client.albums(forArtistId: id)
                    guard !albums.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
                    for album in albums {
                        try Task.checkCancellation()
                        await downloadCollection(album, into: id, via: client)
                    }
                    // The artist's own picture, saved under the artist's id —
                    // one request, so their rows never need the server for it
                    // and an album cover stays what an artist *without* a
                    // picture falls back to.
                    try Task.checkCancellation()
                    await downloadArtistArtwork(for: item, via: client)
                } catch {
                    if !error.isCancellation {
                        errorMessage = "Couldn’t download “\(item.displayName)”. \(error.userFacingMessage)"
                    }
                }
                finishBatch(id)
            }
        case .playlist:
            batches.append(Batch(id: id))
            batchTasks[id] = Task {
                do {
                    let tracks = try await client.tracks(for: item)
                    guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
                    updateBatch(id) { $0.total = tracks.count }
                    var trackIDs: [String] = []
                    for track in tracks {
                        try Task.checkCancellation()
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
                    // A removal while the tracks were landing wins over the
                    // membership: saving the record now would resurrect the
                    // playlist the user just deleted.
                    try Task.checkCancellation()
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
            batchTasks[id] = Task {
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
        activeBatchItems[id] = BaseItemDto(id: id, name: existing.title, type: .playlist)
        persist()
        batchTasks[id] = Task {
            do {
                let stub = BaseItemDto(id: id, name: existing.title, type: .playlist)
                let tracks = try await client.tracks(for: stub)
                guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(existing.title) }
                updateBatch(id) { $0.total = tracks.count }
                var trackIDs: [String] = []
                for track in tracks {
                    try Task.checkCancellation()
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
                try Task.checkCancellation()
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

    /// Removes the download for `item` by deleting the songs it stands for:
    /// the song's own file, an artist's catalogue, a collection's songs.
    /// Whatever else required those songs keeps listing and reports what it
    /// still has — a playlist keeps its membership record and its detail
    /// warns it is incomplete until its refresh re-pulls the missing songs —
    /// so removal behaves the same whether the item was downloaded itself or
    /// surfaced through another collection. A playlist additionally loses its
    /// record and cover, since the membership was the download.
    func remove(_ item: BaseItemDto) {
        guard let id = item.id else { return }
        // A download of this item is pointless the moment it is being removed
        // — and worse than pointless: every track still queued for it would
        // re-save itself after the removal.
        cancelBatch(id)
        switch Self.groupKind(of: item) {
        case nil:
            deleteSongs([id])
        case .playlist?:
            deletePlaylist(id)
        case .artist?:
            deleteSongs(songsMatchingGroupID(id, kind: .artist).compactMap(\.track.id))
            // The artist's picture was saved with the download, so its claim
            // goes with it — the sweep reclaims the file rather than keeping
            // it for an artist that no longer lists.
            unreferenceArtwork(holderID: id)
            deleteUnreferenced()
            persist()
        case let kind?:
            deleteSongs(songsMatchingGroupID(id, kind: kind).compactMap(\.track.id))
        }
    }

    /// Stops a running batch: the task is cancelled, the progress row goes,
    /// and a relaunch will not resume it. The cancelled task's own
    /// ``finishBatch(_:)`` still runs when it unwinds, which is a no-op sweep
    /// over state this already cleared.
    private func cancelBatch(_ id: String) {
        guard let task = batchTasks.removeValue(forKey: id) else { return }
        task.cancel()
        batches.removeAll { $0.id == id }
        activeBatchItems[id] = nil
        persist()
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
                try Task.checkCancellation()
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
        guard !Task.isCancelled else { return }
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
        var pendingKey: String?
        do {
            let remote = try client.streamURL(itemId: id, mediaSourceId: track.mediaSourceID)
            // `AVURLAsset` leans on the file extension to pick a parser, so
            // the saved name carries the track's container — reduced to the
            // one extension it can actually open.
            let filename = Self.filename(trackID: id, container: track.container ?? track.mediaSources?.first?.container)
            // Recorded before the transfer starts: if the process dies
            // mid-flight, the system finishes it anyway, and this record is
            // what lets the next launch file the delivered file.
            let key = Self.pendingKey(for: remote)
            pendingKey = key
            pendingTransfers[key] = .audio(
                track: track,
                filename: filename,
                source: source,
                batchId: batchId,
                albumSongCount: albumSongCount,
                artistKeys: artistKeys
            )
            persist()
            let (tempFile, response) = try await downloadSession.download(from: remote)
            pendingTransfers[key] = nil
            // The transfer can finish just before a removal cancels it; the
            // removal wins, or the file would resurrect what was just deleted.
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: tempFile)
                return
            }
            // `URLSession` happily downloads an error page as if it were audio,
            // so an HTTP failure must be caught here.
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: tempFile)
                throw JellyfinError.downloadFailed(
                    reason: (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "unknown response"
                )
            }
            let destination = directory.appending(path: filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempFile, to: destination)
            entries[id] = Entry(
                track: track,
                filename: filename,
                fileSize: Self.byteSize(of: destination),
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
            if let pendingKey { pendingTransfers[pendingKey] = nil }
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

        // Saved as JPG (the format requested), namespaced by its owner so
        // two items sharing an image tag can't overwrite each other.
        let stem = ownerID.map { "\($0)-\(imageTag)" } ?? imageTag
        let filename = "\(stem).jpg"
        // Recorded like an audio transfer: a cover the system finishes across
        // a process death is filed by the same adoption path.
        let key = Self.pendingKey(for: artworkUrl)
        pendingTransfers[key] = .artwork(ownerID: ownerID, imageTag: imageTag, filename: filename, holderID: holderID)
        persist()

        do {
            let (tempFile, response) = try await downloadSession.download(from: artworkUrl)
            pendingTransfers[key] = nil
            // A removal while the cover was in flight wins over the file.
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: tempFile)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: tempFile)
                return
            }
            let destination = artworkDirectory.appending(path: filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempFile, to: destination)
            let entry = ArtworkEntry(
                filename: filename,
                ownerItemID: ownerID,
                imageTag: imageTag,
                requiredBy: [holderID],
                fileSize: Self.byteSize(of: destination)
            )
            artworkEntries[entry.key] = entry
            persist()
        } catch {
            pendingTransfers[key] = nil
            // Artwork is optional; a missing cover is a placeholder, not an error.
        }
    }

    /// Saves the artist's own picture — the image the artist item carries —
    /// under the artist's id, so the artist views resolve it without the
    /// server. An earlier picture whose tag the server has replaced is
    /// superseded: this artist's claim on it goes, and the sweep that follows
    /// reclaims the file. An artist without a picture keeps falling back to
    /// one of their albums' covers.
    private func downloadArtistArtwork(for item: BaseItemDto, via client: JellyfinService) async {
        guard let id = item.id, let tag = item.primaryImageTag.nonEmpty else { return }
        for (key, var entry) in artworkEntries where entry.ownerItemID == id && entry.imageTag != tag {
            if entry.requiredBy.remove(id) != nil {
                artworkEntries[key] = entry
            }
        }
        await downloadArtwork(ownerID: id, imageTag: tag, holderID: id, via: client)
    }

    /// Runs ``syncArtistArtwork()`` on demand — what the Downloads artist
    /// tab's refresh button calls. A no-op while signed out or while a sync
    /// is already running.
    func refreshArtistArtwork() {
        guard client != nil else { return }
        startArtistArtworkSync()
    }

    /// Starts the sync pass unless one is already running. The flag flips
    /// synchronously so a caller — or a test — watching
    /// ``isSyncingArtistArtwork`` sees the run begin before its task does.
    private func startArtistArtworkSync() {
        guard artistArtworkTask == nil else { return }
        isSyncingArtistArtwork = true
        artistArtworkTask = Task {
            await syncArtistArtwork()
            isSyncingArtistArtwork = false
            artistArtworkTask = nil
        }
    }

    /// Reconciles artist pictures with what is actually downloaded, at sign-in.
    ///
    /// Two halves, both about the artist's own picture saved under the artist's
    /// id:
    ///
    /// - **Fills the gap** left by downloads saved before pictures came with
    ///   artist downloads: those surface their artists with album covers,
    ///   because no picture of the artist's own was ever saved. One request
    ///   resolves every downloaded artist still missing a picture, and each
    ///   one's image is saved under the artist's id. Best effort — a failure
    ///   leaves the album-cover fallback in place and the next sign-in tries
    ///   again.
    /// - **Reclaims the leftovers**: a picture is claimed by the artist's own
    ///   id, so it outlives the songs that showed it — removing every album of
    ///   an artist one by one drops the group without dropping the picture,
    ///   which nothing else would ever reclaim. See
    ///   ``reclaimOrphanedArtistPictures()``.
    ///
    /// Internal rather than private so tests can drive it directly — in
    /// production the callers are ``configure(client:)``, at sign-in, and
    /// ``refreshArtistArtwork()``, from the Downloads artist tab's button.
    func syncArtistArtwork() async {
        // Local, and worth doing even when there is nothing to fetch.
        reclaimOrphanedArtistPictures()
        guard let client, !Task.isCancelled else { return }
        let missing = downloadedArtists().map(\.id).filter { !artistPictureFileExists(for: $0) }
        guard !missing.isEmpty else { return }
        guard let found = try? await client.getItems(includeItemTypes: [.musicArtist], ids: missing).items else { return }
        for artist in found {
            // A wipe mid-run cancels the task; pictures landing after it would
            // resurrect artwork the user has just deleted everything of.
            guard !Task.isCancelled else { return }
            await downloadArtistArtwork(for: artist, via: client)
        }
        persist()
    }

    /// Deletes the pictures of artists that are no longer downloaded.
    ///
    /// A leftover is an entry claimed by its own owner — the shape an artist's
    /// picture is saved in — whose owner is nothing that is still here: not a
    /// song on disk, not a saved playlist, not an artist the downloaded songs
    /// still surface. That last check is the one that makes this safe: album
    /// covers are claimed by their *tracks* rather than by themselves, a song's
    /// own embedded art and a playlist's cover are self-claimed too but by ids
    /// that are still live, so an artist's id with no group behind it is the
    /// only thing left standing.
    private func reclaimOrphanedArtistPictures() {
        let artistIDs = Set(downloadedArtists().map(\.id))
        var reclaimed = false
        for (key, entry) in artworkEntries {
            guard let owner = entry.ownerItemID,
                  entry.requiredBy == [owner],
                  entries[owner] == nil,
                  playlists[owner] == nil,
                  !artistIDs.contains(owner)
            else { continue }
            deleteArtworkFile(entry.filename)
            artworkEntries[key] = nil
            reclaimed = true
        }
        if reclaimed { persist() }
    }

    /// Whether the artist has a picture of their own on disk.
    private func artistPictureFileExists(for id: String) -> Bool {
        artworkEntries.contains { entry in
            entry.value.ownerItemID == id && artworkFileExists(entry.value.filename)
        }
    }

    /// The key a transfer is recorded under: a hash of its request URL, which
    /// is what the system echoes back with a completion it kept across a
    /// process death. Hashed because stream and image URLs carry the access
    /// token, and the manifest must not.
    static func pendingKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A completion the system kept across a process death: iOS's background
    /// session finishes in-flight transfers with the app gone and delivers
    /// them when the store recreates its session at the next launch, by which
    /// point no caller is waiting. The pending record says what the file was
    /// for, and it is filed exactly the way the transfer would have filed it.
    /// Internal rather than private so tests can drive the delivery directly —
    /// in production the only caller is the session's orphaned-transfer
    /// handler, wired in `init`.
    func adoptOrphanedTransfer(requestURL: URL?, file: URL?, statusCode: Int?) {
        guard let requestURL, let pending = pendingTransfers[Self.pendingKey(for: requestURL)] else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        pendingTransfers[Self.pendingKey(for: requestURL)] = nil
        guard let file, let statusCode, (200..<300).contains(statusCode) else {
            if let file { try? FileManager.default.removeItem(at: file) }
            persist()
            return
        }
        switch pending {
        case let .audio(track, filename, source, _, albumSongCount, artistKeys):
            guard let id = track.id else { break }
            if entries[id] != nil {
                // A resumed batch already re-fetched this song; the kept copy
                // is the duplicate.
                try? FileManager.default.removeItem(at: file)
            } else {
                let destination = directory.appending(path: filename)
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.moveItem(at: file, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    break
                }
                entries[id] = Entry(
                    track: track,
                    filename: filename,
                    fileSize: Self.byteSize(of: destination),
                    order: (entries.values.map(\.order).max() ?? 0) + 1,
                    sources: [source],
                    albumSongCount: albumSongCount,
                    artistKeys: artistKeys
                )
                // The transfer died before its cover was fetched, and a
                // resumed batch only references artwork that already exists:
                // pull the cover the way `downloadOne` would have.
                if let client, let pair = Self.artworkPair(for: track) {
                    Task {
                        await self.downloadArtwork(ownerID: pair.owner, imageTag: pair.tag, holderID: id, via: client)
                    }
                }
            }
        case let .artwork(ownerID, imageTag, filename, holderID):
            var entry = ArtworkEntry(
                filename: filename,
                ownerItemID: ownerID,
                imageTag: imageTag,
                requiredBy: [holderID]
            )
            if artworkEntries[entry.key] != nil {
                try? FileManager.default.removeItem(at: file)
            } else {
                let destination = artworkDirectory.appending(path: filename)
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.moveItem(at: file, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    break
                }
                entry.fileSize = Self.byteSize(of: destination)
                artworkEntries[entry.key] = entry
            }
        }
        persist()
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

    /// Deletes many songs' files and entries in one sweep. A deleted song
    /// keeps its place in any playlist's membership record: a record naming a
    /// song with no file is the incompleteness the offline playlist detail
    /// warns about, and the record's refresh is what fills it back in.
    private func deleteSongs(_ ids: [String]) {
        var deleted = false
        for id in ids {
            guard let entry = entries[id] else { continue }
            try? FileManager.default.removeItem(at: directory.appending(path: entry.filename))
            unreferenceArtwork(trackId: id)
            entries[id] = nil
            deleted = true
        }
        guard deleted else { return }
        deleteUnreferenced()
        persist()
    }

    /// Deletes a downloaded playlist: the songs its membership required, then
    /// the record and cover themselves.
    private func deletePlaylist(_ id: String) {
        guard let record = playlists[id] else { return }
        deleteSongs(record.trackIDs)
        unreferenceArtwork(holderID: id)
        playlists[id] = nil
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
        batchTasks[id] = nil
        activeBatchItems[id] = nil
        // Transfers recorded for this batch are done with it: whatever is
        // still listed belonged to a task that failed or was cancelled before
        // it could clear its own record.
        for (key, transfer) in pendingTransfers {
            if case let .audio(_, _, _, batchID, _, _) = transfer, batchID == id {
                pendingTransfers[key] = nil
            }
        }
        deleteUnreferenced()
        persist()
    }

    private func updateBatch(_ id: String, _ change: (inout Batch) -> Void) {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        change(&batches[index])
    }

    /// The sweep that follows a removal: delete the files and entries of songs
    /// no download requires any more, and the artwork no song, playlist cover
    /// or artist picture references.
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
    /// attribution, year and the image tag its artwork was saved under. The
    /// album's own Date Added is never on disk — only the songs' are — so the
    /// earliest of theirs stands in: an album entered the library when its
    /// first song did, which is what the Downloads grid's Date Added sort reads.
    private static func albumItem(key: String, members: [Entry], total: Int?, artistKeys: Set<String>) -> BaseItemDto {
        guard let lead = members.first?.track else {
            return BaseItemDto(id: key, name: key, type: .musicAlbum)
        }
        let pairs = members.flatMap { $0.track.albumArtists ?? [] }
        let year = members.compactMap(\.track.productionYear).min()
        let added = members.compactMap(\.track.dateCreated).min()
        let tag = lead.albumPrimaryImageTag ?? lead.primaryImageTag
        let artistName = lead.albumArtist ?? members.compactMap(\.track.albumArtist).first
            ?? (pairs.isEmpty ? nil : pairs.first?.name)
        return BaseItemDto(
            album: lead.album,
            albumArtist: artistName,
            albumArtists: pairs.isEmpty ? artistName.map({ [NameIDPair(id: artistKeys.first, name: $0)] }) : pairs,
            childCount: total,
            dateCreated: added,
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

    /// The size of the artwork file the keys resolve to — the same one
    /// ``artworkURL(forAnyOf:)`` shows — or 0 when none is saved.
    private func artworkByteCount(forKeys keys: [String]) -> Int64 {
        for key in keys {
            guard let entry = artworkEntries[key] else { continue }
            if artworkFileExists(entry.filename) { return entry.fileSize ?? 0 }
        }
        return 0
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
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// A saved file's size in bytes, or `nil` when it is not on disk.
    private static func byteSize(of file: URL) -> Int64? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    private func persist() {
        let manifest = Manifest(
            tracks: entries,
            playlists: playlists,
            artwork: artworkEntries,
            pendingTransfers: pendingTransfers,
            activeBatches: activeBatchItems
        )
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
