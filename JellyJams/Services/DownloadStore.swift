import Foundation

/// Offline playback: saves audio files under Application Support/Downloads,
/// keyed by track id, and remembers which collections reference each file.
///
/// A file is downloaded once no matter how many collections ask for it. The
/// manifest maps every track id to the set of *reference ids* that require it
/// — an album, playlist or genre id, or the track's own id when it was
/// downloaded as a song. Removing a collection first unlinks it from every
/// track it required; tracks then requiring nothing are deleted from disk in a
/// second pass. That reference counting is what keeps "download album, then a
/// playlist overlapping it" from duplicating bytes or orphaning files.
///
/// Artists are not stored at all: downloading one downloads each of their
/// albums as a normal album download, and the Artists list is derived from
/// the downloaded albums' `albumArtists` metadata.
///
/// Album artwork is downloaded alongside tracks and deduplicated by its image
/// tag — tracks from the same album share one artwork file. The artwork
/// manifest uses the same reference counting scheme as tracks.
///
/// The manifest — including the track and collection metadata the downloads
/// section browses — is rewritten after every change, so downloads survive
/// relaunches. Track ids are server-unique, so it deliberately survives
/// sign-out too: offline listening is the point.
@MainActor
final class DownloadStore: ObservableObject {
    /// One downloaded file, and the reference ids that require it.
    struct Entry: Codable, Sendable, Equatable {
        var track: BaseItemDto
        var filename: String
        /// Fetch order, preserved so collections list their tracks in the
        /// order the server returned them.
        var order: Int
        var requiredBy: Set<String>
    }

    /// One downloaded artwork file, and the track ids that reference it.
    /// Keyed by the image tag (e.g. the album's `primaryImageTag`), so all
    /// tracks from the same album share one artwork file.
    struct ArtworkEntry: Codable, Sendable, Equatable {
        var filename: String
        /// The image tag this artwork represents (e.g. "abc123" from primaryImageTag).
        var imageTag: String
        /// Track ids that require this artwork.
        var requiredBy: Set<String>
    }

    /// One in-flight download batch, keyed by the id of the item that started
    /// it — which is also what progress UIs group by.
    struct Batch: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        var completed = 0
        var failed = 0
        var total = 0
    }

    @Published private(set) var entries: [String: Entry] = [:]
    /// Collections (albums, artists, playlists, genres) as downloaded, so the
    /// downloads section can show them with their own metadata.
    @Published private(set) var collections: [String: BaseItemDto] = [:]
    @Published private(set) var batches: [Batch] = []
    @Published private(set) var errorMessage: String?

    @Published private(set) var artworkEntries: [String: ArtworkEntry] = [:]

    private var client: JellyfinService?
    private let directory: URL
    private let session: URLSession
    private let manifestURL: URL
    private let artworkDirectory: URL

    private struct Manifest: Codable, Sendable {
        var tracks: [String: Entry]
        var collections: [String: BaseItemDto]
        var artwork: [String: ArtworkEntry]
    }

    init(directory: URL? = nil, session: URLSession = .shared) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = directory ?? support.appending(path: "Downloads", directoryHint: .isDirectory)
        self.directory = dir
        self.artworkDirectory = dir.appending(path: "Artwork", directoryHint: .isDirectory)
        self.manifestURL = dir.appending(path: "manifest.json")
        self.session = session
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            entries = manifest.tracks
            collections = manifest.collections
            artworkEntries = manifest.artwork
        }
    }

    /// Removes every download: all files, entries and collection metadata.
    func removeAll() {
        for entry in entries.values {
            try? FileManager.default.removeItem(at: directory.appending(path: entry.filename))
        }
        for artwork in artworkEntries.values {
            try? FileManager.default.removeItem(at: artworkDirectory.appending(path: artwork.filename))
        }
        entries = [:]
        collections = [:]
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
    /// any saved track for an album, playlist or genre, or any downloaded
    /// album for an artist.
    func isDownloaded(_ item: BaseItemDto) -> Bool {
        guard let id = item.id else { return false }
        if item.itemType == .audio {
            return entries[id] != nil
        }
        if item.itemType == .musicArtist {
            return downloadedArtists().contains { $0.id == id }
        }
        return entries.values.contains { $0.requiredBy.contains(id) }
    }

    /// Whether a download for `item` is in flight.
    func isBusy(_ item: BaseItemDto) -> Bool {
        guard let id = item.id else { return false }
        return batches.contains { $0.id == id }
    }

    /// The saved file for `itemId`, or `nil` when it has not been downloaded.
    func localURL(forItemId id: String) -> URL? {
        guard let filename = entries[id]?.filename else { return nil }
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

    /// The saved artwork file for `imageTag`, or `nil` when it has not been downloaded.
    func localArtworkURL(forImageTag imageTag: String) -> URL? {
        guard let filename = artworkEntries[imageTag]?.filename else { return nil }
        let url = artworkDirectory.appending(path: filename)
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

    /// Tracks saved for `referenceId`, in the order they were downloaded.
    func tracks(forItemId referenceId: String) -> [BaseItemDto] {
        entries.values
            .filter { $0.requiredBy.contains(referenceId) }
            .sorted { $0.order < $1.order }
            .map(\.track)
    }

    /// Collections of a given type that have saved tracks, name-sorted.
    func downloadedCollections(ofType type: ItemType) -> [BaseItemDto] {
        collections.values
            .filter { $0.itemType == type }
            .sorted { $0.displayName < $1.displayName }
    }

    /// The saved metadata for a downloaded collection, by id.
    func collection(id: String) -> BaseItemDto? {
        collections[id]
    }

    /// Artists behind the downloaded albums, derived from each album's
    /// `albumArtists` metadata rather than stored — so downloading any album
    /// surfaces its artist, and removing the last one drops the artist again.
    /// Albums the server didn't attribute fall back to their name-only
    /// `albumArtist` string.
    func downloadedArtists() -> [BaseItemDto] {
        var byId: [String: BaseItemDto] = [:]
        for album in collections.values where album.itemType == .musicAlbum {
            let pairs = album.albumArtists ?? []
            // Albums the server didn't attribute carry at most a name-only
            // `albumArtist` string; that name stands in as the artist key.
            let named = pairs.isEmpty && !(album.albumArtist ?? "").isEmpty
                ? [NameIDPair(id: nil, name: album.albumArtist)]
                : pairs
            for artist in named {
                let key = artist.id ?? artist.name ?? ""
                guard !key.isEmpty else { continue }
                byId[key] = BaseItemDto(id: key, name: artist.name, type: .musicArtist)
            }
        }
        return byId.values.sorted { $0.displayName < $1.displayName }
    }

    /// The downloaded albums attributed to `artistId`, name-sorted.
    func downloadedAlbums(forArtistId artistId: String) -> [BaseItemDto] {
        collections.values
            .filter { album in
                guard album.itemType == .musicAlbum else { return false }
                let pairIds = (album.albumArtists ?? []).map { $0.id ?? $0.name ?? "" }
                return pairIds.contains(artistId)
                    || (album.albumArtists ?? []).isEmpty && album.albumArtist == artistId
            }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Tracks downloaded as songs (as opposed to via a collection), so the
    /// downloads section can show them under "Songs".
    func downloadedSongs() -> [BaseItemDto] {
        entries.values
            .filter { entry in entry.track.id.map { entry.requiredBy.contains($0) } ?? false }
            .sorted { $0.order < $1.order }
            .map(\.track)
    }

    // MARK: - Downloading

    /// Downloads `item`: a track saves its file referencing itself; an artist
    /// downloads each of its albums as a normal album download; any other
    /// collection resolves its tracks and saves each one referencing the
    /// collection. Files already on disk only gain the reference, which is how
    /// overlapping downloads dedupe.
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

        if item.itemType == .audio {
            var batch = Batch(id: id, label: item.displayName)
            batch.total = 1
            batches.append(batch)
            Task {
                await downloadOne(item, referencing: id, in: id, via: client)
                finishBatch(id)
            }
        } else if item.itemType == .musicArtist {
            batches.append(Batch(id: id, label: item.displayName))
            Task {
                do {
                    let albums = try await client.albums(forArtistId: id)
                    guard !albums.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
                    for album in albums {
                        guard let albumId = album.id else { continue }
                        collections[albumId] = album
                        let tracks = try await client.tracks(for: album)
                        guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(album.displayName) }
                        updateBatch(id) { $0.total += tracks.count }
                        for track in tracks {
                            await downloadOne(track, referencing: albumId, in: id, via: client)
                        }
                    }
                } catch {
                    if !error.isCancellation {
                        errorMessage = "Couldn’t download “\(item.displayName)”. \(error.userFacingMessage)"
                    }
                }
                finishBatch(id)
            }
        } else {
            collections[id] = item
            batches.append(Batch(id: id, label: item.displayName))
            Task {
                do {
                    let tracks = try await client.tracks(for: item)
                    guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
                    updateBatch(id) { $0.total = tracks.count }
                    for track in tracks {
                        await downloadOne(track, referencing: id, in: id, via: client)
                    }
                } catch {
                    if !error.isCancellation {
                        errorMessage = "Couldn’t download “\(item.displayName)”. \(error.userFacingMessage)"
                    }
                }
                finishBatch(id)
            }
        }
    }

    /// Removes the download for `item`. A track unreferences itself; an artist
    /// removes every album downloaded for it; any other collection unreferences
    /// every track it required. Tracks left requiring nothing are deleted from
    /// disk in a second pass. Artwork no longer referenced by any track is also removed.
    func remove(_ item: BaseItemDto) {
        guard let id = item.id else { return }
        if item.itemType == .audio {
            // Unreference artwork for this track before potentially deleting it.
            if let entry = entries[id] {
                unreferencedArtwork(for: entry.track, trackId: id)
            }
            entries[id]?.requiredBy.remove(id)
        } else if item.itemType == .musicArtist {
            for album in downloadedAlbums(forArtistId: id) {
                remove(album)
            }
            return
        } else {
            // For collections, we need to find all tracks that were referenced by this collection
            // and unreference their artwork.
            let trackIdsToUnreference = entries.values
                .filter { $0.requiredBy.contains(id) }
                .compactMap { $0.track.id }
            for trackId in trackIdsToUnreference {
                if let entry = entries[trackId] {
                    unreferencedArtwork(for: entry.track, trackId: trackId)
                }
            }
            for var entry in entries.values where entry.requiredBy.contains(id) {
                entry.requiredBy.remove(id)
                entries[entry.track.id ?? ""] = entry
            }
            collections[id] = nil
        }
        deleteUnreferenced()
        persist()
    }

    /// Removes a track reference from artwork entries. If an artwork entry has no more references, it will be cleaned up by deleteUnreferenced.
    private func unreferencedArtwork(for track: BaseItemDto, trackId: String) {
        let imageTag = track.primaryImageTag ?? track.albumPrimaryImageTag
        guard let imageTag, !imageTag.isEmpty else { return }
        if var artworkEntry = artworkEntries[imageTag] {
            artworkEntry.requiredBy.remove(trackId)
            artworkEntries[imageTag] = artworkEntry
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Internals

    private func downloadOne(
        _ track: BaseItemDto,
        referencing referenceId: String,
        in batchId: String,
        via client: JellyfinService
    ) async {
        guard let id = track.id else {
            updateBatch(batchId) { $0.failed += 1 }
            return
        }
        // Already saved: just gain the new reference, no second copy.
        if var entry = entries[id] {
            entry.requiredBy.insert(referenceId)
            entries[id] = entry
            // Also reference the artwork if this track has one.
            await referenceArtwork(for: track, trackId: id)
            persist()
            updateBatch(batchId) { $0.completed += 1 }
            return
        }
        do {
            let remote = try client.streamURL(itemId: id, mediaSourceId: track.mediaSourceID)
            let (tempFile, response) = try await session.download(from: remote)
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
                requiredBy: [referenceId]
            )
            // Download artwork for this track (deduplicated by image tag).
            await downloadArtwork(for: track, trackId: id, via: client)
            persist()
            updateBatch(batchId) { $0.completed += 1 }
        } catch {
            if !error.isCancellation {
                playbackLogDownloadFailure(track, error)
            }
            updateBatch(batchId) { $0.failed += 1 }
        }
    }

    /// Downloads and saves artwork for a track, deduplicated by image tag.
    /// Uses the track's primaryImageTag, or falls back to albumPrimaryImageTag.
    private func downloadArtwork(
        for track: BaseItemDto,
        trackId: String,
        via client: JellyfinService
    ) async {
        // Determine the image tag to use for deduplication.
        // Primary: track's own primaryImageTag (album artwork).
        // Fallback: album's primaryImageTag via albumPrimaryImageTag.
        let imageTag = track.primaryImageTag ?? track.albumPrimaryImageTag
        guard let imageTag, !imageTag.isEmpty else { return }

        // Already have this artwork: just add the track reference.
        if var artworkEntry = artworkEntries[imageTag] {
            artworkEntry.requiredBy.insert(trackId)
            artworkEntries[imageTag] = artworkEntry
            persist()
            return
        }

        // Need to download the artwork.
        // The artwork URL uses the item that owns the image (album for album art).
        let artworkItemId = track.albumID ?? track.id
        guard let artworkUrl = client.artworkURL(
            itemId: artworkItemId,
            tag: imageTag,
            maxWidth: 500,
            maxHeight: 500,
            quality: 90,
            type: .primary
        ) else { return }

        do {
            let (tempFile, response) = try await session.download(from: artworkUrl)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return // Silently ignore artwork download failures
            }
            // Save as JPG (the format we requested).
            let filename = "\(imageTag).jpg"
            let destination = artworkDirectory.appending(path: filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempFile, to: destination)
            artworkEntries[imageTag] = ArtworkEntry(
                filename: filename,
                imageTag: imageTag,
                requiredBy: [trackId]
            )
            persist()
        } catch {
            // Silently ignore artwork download failures - audio is the priority.
        }
    }

    /// Adds a track reference to existing artwork entry (when track was already downloaded).
    private func referenceArtwork(for track: BaseItemDto, trackId: String) async {
        let imageTag = track.primaryImageTag ?? track.albumPrimaryImageTag
        guard let imageTag, !imageTag.isEmpty else { return }
        if var artworkEntry = artworkEntries[imageTag] {
            artworkEntry.requiredBy.insert(trackId)
            artworkEntries[imageTag] = artworkEntry
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
        persist()
    }

    private func updateBatch(_ id: String, _ change: (inout Batch) -> Void) {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        change(&batches[index])
    }

    /// The second pass of a removal: delete the files (and entries) of tracks
    /// that no collection or song download requires any more. Also deletes artwork
    /// files that are no longer referenced by any track.
    private func deleteUnreferenced() {
        for (id, entry) in entries where entry.requiredBy.isEmpty {
            try? FileManager.default.removeItem(at: directory.appending(path: entry.filename))
            entries[id] = nil
        }
        // Clean up unreferenced artwork.
        for (imageTag, artworkEntry) in artworkEntries where artworkEntry.requiredBy.isEmpty {
            try? FileManager.default.removeItem(at: artworkDirectory.appending(path: artworkEntry.filename))
            artworkEntries[imageTag] = nil
        }
    }

    private func persist() {
        let manifest = Manifest(tracks: entries, collections: collections, artwork: artworkEntries)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}
