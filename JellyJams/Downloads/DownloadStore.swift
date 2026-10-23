import Foundation
import JellyfinAPI

/// Offline playback: saves audio files under Application Support/Downloads,
/// keyed by track id.
///
/// Songs are the only content ever downloaded — artwork rides alongside them.
/// Everything the downloads section browses is a *view* over the songs on disk:
///
/// - **Albums and artists are derived**, grouped from the metadata each track
///   snapshot carries (`albumID`, `album`, album-artist attribution). No album
///   or artist record is stored, so downloading one track surfaces its album at
///   "1 of 12" and its artist, and removing a song can never leave an empty
///   collection behind.
/// - **Playlists** are the one grouping a song's own metadata cannot express,
///   so a downloaded playlist also saves a small membership record: title,
///   ordered track ids, cover tag, song count.
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
    /// The kinds a downloaded collection can have. Albums, artists and
    /// playlists are the views the downloads section browses; a genre is a
    /// download source and reference key with no browsing view of its own.
    /// Songs are not a kind: they are what every kind is made of.
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
        /// Artist attribution for an album group, the artist's own key for an
        /// artist group; empty for playlists.
        let artistKeys: Set<String>
        /// The newest fetch order among the group's songs on disk — what the
        /// Downloads grids' "Recently Downloaded" sort orders groups by. An
        /// artist is as recent as its newest album; a group whose songs have
        /// all been deleted holds 0.
        let mostRecentOrder: Int

        /// Every song the group has on the server is on disk.
        ///
        /// An unknown total — an album that surfaced from a song downloaded on
        /// its own, or from a playlist whose album lookup never resolved —
        /// cannot be claimed complete. That is what lets the Downloads
        /// "complete albums" filter hide a one-song album rather than present
        /// it as finished.
        var isFullyDownloaded: Bool {
            guard let totalSongs, totalSongs > 0 else { return false }
            return downloadedSongs >= totalSongs
        }
    }

    @Published var entries: [String: Entry] = [:]
    /// Downloaded playlists by id — the only stored grouping, because playlist
    /// membership is the one thing a song's metadata cannot say.
    @Published var playlists: [String: PlaylistRecord] = [:]
    @Published var batches: [Batch] = []
    @Published var errorMessage: String?

    @Published var artworkEntries: [String: ArtworkEntry] = [:]

    /// Whether an artist-artwork sync is running — the sign-in one or the one
    /// the Downloads artist tab's refresh button starts. Drives that button's
    /// spinner and disabled state.
    @Published var isSyncingArtistArtwork = false

    /// Every file transfer, feeding the throughput the downloads status bar
    /// shows.
    let downloadSession: DownloadSession

    /// The task running each batch, keyed by batch id, so removals can cancel
    /// them: a download the user has deleted must not keep landing tracks.
    var batchTasks: [String: Task<Void, Never>] = [:]
    /// The task running ``syncArtistArtwork()``, held so a manual refresh
    /// never overlaps the sign-in sync or an earlier press, and so a wipe can
    /// cancel a run that would otherwise keep landing pictures after it.
    var artistArtworkTask: Task<Void, Never>?
    /// The item each running batch was started for, persisted so a relaunch
    /// can resume batches whose process died mid-download.
    var activeBatchItems: [String: BaseItemDto] = [:]
    /// Transfers in flight, keyed by ``pendingKey(for:)`` of their request URL.
    var pendingTransfers: [String: PendingTransfer] = [:]
    /// Whether the batches a previous process persisted have been resumed
    /// this launch.
    var hasResumedInterruptedBatches = false

    var client: JellyfinService?
    let directory: URL
    let manifestURL: URL
    let artworkDirectory: URL

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

    func dismissError() {
        errorMessage = nil
    }

    func persist() {
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

extension Optional where Wrapped == String {
    /// The string when it holds something, `nil` when it is empty or absent, so
    /// a server's empty image tag reads as no image rather than as a key.
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

extension Array where Element == String? {
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
