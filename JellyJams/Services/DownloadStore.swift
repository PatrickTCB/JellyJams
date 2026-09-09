import Foundation

/// Offline playback: saves audio files under Application Support/Downloads,
/// keyed by track id, and remembers which collections reference each file.
///
/// A file is downloaded once no matter how many collections ask for it. The
/// manifest maps every track id to the set of *reference ids* that require it
/// — an album, artist, playlist or genre id, or the track's own id when it was
/// downloaded as a song. Removing a collection first unlinks it from every
/// track it required; tracks then requiring nothing are deleted from disk in a
/// second pass. That reference counting is what keeps "download album, then a
/// playlist overlapping it" from duplicating bytes or orphaning files.
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

    private var client: JellyfinService?
    private let directory: URL
    private let session: URLSession
    private let manifestURL: URL

    private struct Manifest: Codable, Sendable {
        var tracks: [String: Entry]
        var collections: [String: BaseItemDto]
    }

    init(directory: URL? = nil, session: URLSession = .shared) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = directory ?? support.appending(path: "Downloads", directoryHint: .isDirectory)
        self.directory = dir
        self.manifestURL = dir.appending(path: "manifest.json")
        self.session = session
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            entries = manifest.tracks
            collections = manifest.collections
        }
    }

    /// Points the store at a new session. Downloaded files are kept.
    func configure(client: JellyfinService?) {
        guard client !== self.client else { return }
        self.client = client
        errorMessage = nil
    }

    // MARK: - Queries

    /// Whether a downloaded copy of `item` is available: the file for a track,
    /// or any saved track for a collection.
    func isDownloaded(_ item: BaseItemDto) -> Bool {
        guard let id = item.id else { return false }
        if item.itemType == .audio {
            return entries[id] != nil
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
        return FileManager.default.fileExists(atPath: url.path()) ? url : nil
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

    /// Tracks downloaded as songs (as opposed to via a collection), so the
    /// downloads section can show them under "Songs".
    func downloadedSongs() -> [BaseItemDto] {
        entries.values
            .filter { entry in entry.track.id.map { entry.requiredBy.contains($0) } ?? false }
            .sorted { $0.order < $1.order }
            .map(\.track)
    }

    // MARK: - Downloading

    /// Downloads `item`: a track saves its file referencing itself; a
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

    /// Removes the download for `item`. A track unreferences itself; a
    /// collection unreferences every track it required. Tracks left requiring
    /// nothing are deleted from disk in a second pass.
    func remove(_ item: BaseItemDto) {
        guard let id = item.id else { return }
        if item.itemType == .audio {
            entries[id]?.requiredBy.remove(id)
        } else {
            for var entry in entries.values where entry.requiredBy.contains(id) {
                entry.requiredBy.remove(id)
                entries[entry.track.id ?? ""] = entry
            }
            collections[id] = nil
        }
        deleteUnreferenced()
        persist()
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
            persist()
            updateBatch(batchId) { $0.completed += 1 }
        } catch {
            if !error.isCancellation {
                playbackLogDownloadFailure(track, error)
            }
            updateBatch(batchId) { $0.failed += 1 }
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
    /// that no collection or song download requires any more.
    private func deleteUnreferenced() {
        for (id, entry) in entries where entry.requiredBy.isEmpty {
            try? FileManager.default.removeItem(at: directory.appending(path: entry.filename))
            entries[id] = nil
        }
    }

    private func persist() {
        let manifest = Manifest(tracks: entries, collections: collections)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}