import Foundation
import JellyfinAPI
import OSLog

private let downloadLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "net.aseriesoftubes.JellyJams",
    category: "Downloads"
)

// MARK: - Manifest

extension DownloadStore {
    private nonisolated static let manifestVersion = 4

    struct Manifest: Codable, Sendable {
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

    func loadManifest() {
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
    nonisolated static let manifestUnreadableMessage =
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
    static func filename(trackID: String, container: String?) -> String {
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

}
