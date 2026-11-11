import CryptoKit
import Foundation
import JellyfinAPI

// MARK: - Downloading

extension DownloadStore {
    /// One run of a batch. The id is the item the batch downloads — what its
    /// progress row and ``isBusy(_:)`` go by — and the token tells this run
    /// apart from a later one under the same id, so a cancelled run that is
    /// still unwinding can't update or finish the run that replaced it.
    struct BatchRun: Sendable, Equatable {
        let id: String
        let token = UUID()
    }

    /// One song to save: the track as it will be stored, the source id it is
    /// saved for, and the album and artist attribution the derived groups are
    /// built from.
    struct TrackDownload: Sendable {
        let track: BaseItemDto
        let source: String
        let albumSongCount: Int?
        let artistKeys: Set<String>
    }

    /// How many songs one batch transfers at a time. A background session
    /// (iOS) is handed every song at once: the system schedules them, and they
    /// keep going while the app is suspended — when it can't start new ones.
    /// A foreground session queues whatever exceeds its connection limit, and
    /// a queued transfer can time out waiting, so it runs a few at a time.
    private var transferConcurrency: Int {
        downloadSession.isBackground ? .max : 4
    }

    /// Batches a previous process persisted get started again at the first
    /// sign-in. ``download(_:)`` counts tracks already on disk as done without
    /// re-fetching them, so a resume downloads exactly what the interrupted
    /// run did not finish, in whatever order the files arrived.
    func resumeInterruptedBatches() {
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
            let run = startBatch(id, total: 1)
            let order = reserveOrders(count: 1)
            let song = TrackDownload(track: item, source: id, albumSongCount: nil, artistKeys: Self.artistKeys(of: item))
            batchTasks[id] = Task {
                await downloadOne(song, order: order, run: run, via: client)
                finishBatch(run)
            }
        case .musicArtist:
            let run = startBatch(id)
            batchTasks[id] = Task {
                do {
                    let albums = try await client.albums(forArtistId: id)
                    guard !albums.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
                    // Every album's songs are listed first and then downloaded
                    // together, so the whole catalogue is in flight at once
                    // rather than one album at a time.
                    var songs: [TrackDownload] = []
                    for album in albums {
                        try Task.checkCancellation()
                        songs += await collectionDownloads(album, via: client) ?? []
                    }
                    await downloadTracks(songs, run: run, via: client)
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
                finishBatch(run)
            }
        case .playlist:
            let run = startBatch(id)
            batchTasks[id] = Task {
                do {
                    let tracks = try await client.tracks(for: item)
                    guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
                    let trackIDs = try await downloadPlaylistTracks(tracks, source: id, run: run, via: client)
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
                finishBatch(run)
            }
        default:
            let run = startBatch(id)
            batchTasks[id] = Task {
                if let songs = await collectionDownloads(item, via: client) {
                    await downloadTracks(songs, run: run, via: client)
                }
                finishBatch(run)
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
        let run = startBatch(id)
        activeBatchItems[id] = BaseItemDto(id: id, name: existing.title, type: .playlist)
        persist()
        batchTasks[id] = Task {
            do {
                let stub = BaseItemDto(id: id, name: existing.title, type: .playlist)
                let tracks = try await client.tracks(for: stub)
                guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(existing.title) }
                let trackIDs = try await downloadPlaylistTracks(tracks, source: id, run: run, via: client)
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
            finishBatch(run)
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
    /// and a relaunch will not resume it. The cancelled run keeps unwinding
    /// for a moment — its transfers clear their own records as they fail —
    /// but its run token is retired here, so none of it can touch the batch
    /// that is gone, or one started again in its place.
    private func cancelBatch(_ id: String) {
        guard let task = batchTasks.removeValue(forKey: id) else { return }
        task.cancel()
        batches.removeAll { $0.id == id }
        batchRunTokens[id] = nil
        activeBatchItems[id] = nil
        // Records a previous launch left for this batch: its own cleanup
        // would have swept them, and a retired run no longer cleans up.
        dropPendingTransfers(forBatch: id)
        persist()
    }

    // MARK: - Internals

    /// Starts a run of the batch `id`: its progress row, and the token its
    /// progress updates and final cleanup are checked against.
    private func startBatch(_ id: String, total: Int = 0) -> BatchRun {
        let run = BatchRun(id: id)
        var batch = Batch(id: id)
        batch.total = total
        batches.append(batch)
        batchRunTokens[id] = run.token
        return run
    }

    /// Hands out `count` consecutive download orders, above every order saved
    /// or already handed out. A batch reserves its block when its track list
    /// is known, so its songs list in the order the server returned them
    /// however its side-by-side transfers happen to finish.
    func reserveOrders(count: Int) -> Int {
        let first = max(lastReservedOrder, entries.values.map(\.order).max() ?? 0) + 1
        lastReservedOrder = first + max(count, 1) - 1
        return first
    }

    /// The songs of a collection — an album, a genre, anything else with
    /// children — each referencing the collection. An album's songs also gain
    /// the album's track count and attribution, which is what lets the album
    /// view be derived from them later. A collection that can't be listed is
    /// reported and yields nothing.
    private func collectionDownloads(_ item: BaseItemDto, via client: JellyfinService) async -> [TrackDownload]? {
        guard let id = item.id else { return nil }
        do {
            let tracks = try await client.tracks(for: item)
            guard !tracks.isEmpty else { throw JellyfinError.emptyCollection(item.displayName) }
            let isAlbum = item.itemType == .musicAlbum
            let collectionKeys = Self.artistKeys(of: item)
            return tracks.map { track in
                // An album's songs are stored with the album's own attribution
                // filled in, so the derived album view and the download
                // reference agree on the album's id.
                let stored = isAlbum ? Self.completingAlbumFields(of: track, from: item) : track
                // The song's own attribution wins: its id-bearing `AlbumArtists`
                // and a name-only `AlbumArtist` would otherwise surface the same
                // artist under two keys. The collection is the fallback for
                // songs that say nothing.
                let trackKeys = Self.artistKeys(of: stored)
                return TrackDownload(
                    track: stored,
                    source: id,
                    albumSongCount: isAlbum ? tracks.count : nil,
                    artistKeys: trackKeys.isEmpty ? collectionKeys : trackKeys
                )
            }
        } catch {
            if !error.isCancellation {
                errorMessage = "Couldn’t download “\(item.displayName)”. \(error.userFacingMessage)"
            }
            return nil
        }
    }

    /// Downloads `songs` side by side, ``transferConcurrency`` at a time, each
    /// saved under the order it holds in the list whatever order the
    /// transfers finish in. A song listed twice is fetched once.
    private func downloadTracks(_ songs: [TrackDownload], run: BatchRun, via client: JellyfinService) async {
        var seen = Set<String>()
        let unique = songs.filter { song in song.track.id.map { seen.insert($0).inserted } ?? true }
        guard !unique.isEmpty else { return }
        updateBatch(run) { $0.total += unique.count }
        let firstOrder = reserveOrders(count: unique.count)
        let limit = transferConcurrency
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for (offset, song) in unique.enumerated() {
                guard !Task.isCancelled else { break }
                if running >= limit {
                    await group.next()
                    running -= 1
                }
                group.addTask {
                    await self.downloadOne(song, order: firstOrder + offset, run: run, via: client)
                }
                running += 1
            }
        }
    }

    /// Fills a song's album attribution from the album it was fetched with, when
    /// the server left it out. The album view is grouped from the saved snapshot,
    /// so a song stored without its album id would surface under a name-derived
    /// group its own download reference doesn't match — untoggleable and
    /// unremovable.
    static func completingAlbumFields(of track: BaseItemDto, from album: BaseItemDto) -> BaseItemDto {
        // The album carries its name and image tag where a song carries its
        // album's name and album image tag.
        completingMissingAlbumFields(
            of: track,
            from: BaseItemDto(
                album: album.name,
                albumArtist: album.albumArtist,
                albumArtists: album.albumArtists,
                albumID: album.id,
                albumPrimaryImageTag: album.primaryImageTag,
                productionYear: album.productionYear
            )
        )
    }

    /// Fills the album attribution a song's snapshot lacks from another item
    /// that carries it. Only empty fields are filled, so the richer of two
    /// snapshots of the same song always survives.
    static func completingMissingAlbumFields(of track: BaseItemDto, from other: BaseItemDto) -> BaseItemDto {
        var completed = track
        if completed.albumID?.isEmpty != false { completed.albumID = other.albumID }
        if completed.album?.isEmpty != false { completed.album = other.album }
        if completed.albumPrimaryImageTag?.isEmpty != false {
            completed.albumPrimaryImageTag = other.albumPrimaryImageTag
        }
        if completed.albumArtist?.isEmpty != false { completed.albumArtist = other.albumArtist }
        if (completed.albumArtists ?? []).isEmpty { completed.albumArtists = other.albumArtists }
        if completed.productionYear == nil { completed.productionYear = other.productionYear }
        return completed
    }

    /// Saves each of a playlist's tracks under the playlist's id and returns
    /// the deduplicated track ids in playlist order — what the membership
    /// record names. Shared by the playlist download and its refresh.
    ///
    /// A playlist payload can lack a song's album attribution — a file without
    /// album tags reports its album's id but no name — so each song is
    /// completed from its album item, the way an album download completes its
    /// songs, and the album's server-side song count becomes the total an
    /// album the playlist fully covers is complete by.
    private func downloadPlaylistTracks(
        _ tracks: [BaseItemDto],
        source: String,
        run: BatchRun,
        via client: JellyfinService
    ) async throws -> [String] {
        let albums = await albumMetadata(for: tracks, via: client)
        try Task.checkCancellation()
        var trackIDs: [String] = []
        var seen = Set<String>()
        var songs: [TrackDownload] = []
        for track in tracks {
            if let trackId = track.id, seen.insert(trackId).inserted { trackIDs.append(trackId) }
            let album = track.albumID.flatMap { albums[$0] }
            let stored = album.map { Self.completingAlbumFields(of: track, from: $0) } ?? track
            songs.append(TrackDownload(
                track: stored,
                source: source,
                albumSongCount: album?.childCount,
                artistKeys: Self.artistKeys(of: stored)
            ))
        }
        await downloadTracks(songs, run: run, via: client)
        try Task.checkCancellation()
        return trackIDs
    }

    /// The album items behind a set of tracks, keyed by album id, resolved in
    /// one batched lookup. Best effort: a failed lookup leaves the tracks
    /// storing whatever album attribution their own payloads carried, and the
    /// next playlist refresh tries again.
    private func albumMetadata(
        for tracks: [BaseItemDto],
        via client: JellyfinService
    ) async -> [String: BaseItemDto] {
        let ids = Set(tracks.compactMap { $0.albumID.nonEmpty })
        guard !ids.isEmpty, let albums = try? await client.albums(byIds: Array(ids)) else { return [:] }
        return Dictionary(uniqueKeysWithValues: albums.compactMap { album in album.id.map { ($0, album) } })
    }

    private func downloadOne(
        _ song: TrackDownload,
        order: Int,
        run: BatchRun,
        via client: JellyfinService
    ) async {
        guard !Task.isCancelled else { return }
        let track = song.track
        guard let id = track.id else {
            updateBatch(run) { $0.failed += 1 }
            return
        }
        // Another batch is already fetching this song — an album and a
        // playlist sharing it, started together: wait for that transfer
        // rather than fetch and file a second copy over the first.
        let transferKey = "audio|\(id)"
        await waitForTransfer(transferKey)
        guard !Task.isCancelled else { return }
        // Already saved: just gain the new reference, no second copy.
        if addReference(to: id, for: song) {
            updateBatch(run) { $0.completed += 1 }
            return
        }
        beginTransfer(transferKey)
        defer { endTransfer(transferKey) }
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
                source: song.source,
                batchId: run.id,
                albumSongCount: song.albumSongCount,
                artistKeys: song.artistKeys
            )
            persistSoon()
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
            // The song can have been filed while this transfer ran — a copy
            // the system kept across a relaunch, adopted meanwhile. That copy
            // stays; this one only adds its reference.
            if addReference(to: id, for: song) {
                try? FileManager.default.removeItem(at: tempFile)
                updateBatch(run) { $0.completed += 1 }
                return
            }
            let destination = directory.appending(path: filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempFile, to: destination)
            entries[id] = Entry(
                track: track,
                filename: filename,
                fileSize: Self.byteSize(of: destination),
                order: order,
                sources: [song.source],
                albumSongCount: song.albumSongCount,
                artistKeys: song.artistKeys
            )
            // The song's cover is the album's, and the same pair is used to
            // request it, key it and resolve it — so one file serves every song
            // of the album, and the album and artist views can predict the key.
            if let pair = Self.artworkPair(for: track) {
                await downloadArtwork(ownerID: pair.owner, imageTag: pair.tag, holderID: id, via: client)
            }
            persistSoon()
            updateBatch(run) { $0.completed += 1 }
        } catch {
            if let pendingKey { pendingTransfers[pendingKey] = nil }
            if !error.isCancellation {
                reportDownloadFailure(track, error)
            }
            updateBatch(run) { $0.failed += 1 }
        }
    }

    /// Adds `song`'s reference to the saved copy of `id`, when there is one,
    /// and reports whether there was. A song saved from a bare payload — one
    /// that landed before its album was resolved — is healed by what this
    /// fetch knows; only the attribution its snapshot lacks is filled.
    private func addReference(to id: String, for song: TrackDownload) -> Bool {
        guard var entry = entries[id] else { return false }
        entry.sources.insert(song.source)
        if entry.albumSongCount == nil { entry.albumSongCount = song.albumSongCount }
        entry.artistKeys.formUnion(song.artistKeys)
        entry.track = Self.completingMissingAlbumFields(of: entry.track, from: song.track)
        entries[id] = entry
        referenceArtwork(for: entry.track, trackId: id)
        persistSoon()
        return true
    }

    // MARK: - Transfers in flight

    /// Waits while another download fetches what `key` names — a song or a
    /// cover — and returns at once when nothing is fetching it. The caller
    /// re-checks what is saved afterwards: the transfer it waited on can have
    /// failed, or been cancelled with its batch.
    func waitForTransfer(_ key: String) async {
        while transfersInFlight[key] != nil {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                transfersInFlight[key, default: []].append(waiter)
            }
        }
    }

    /// Marks `key` as being fetched. Paired with ``endTransfer(_:)`` in a
    /// `defer`, so every path out of the transfer releases its waiters.
    func beginTransfer(_ key: String) {
        transfersInFlight[key] = []
    }

    func endTransfer(_ key: String) {
        for waiter in transfersInFlight.removeValue(forKey: key) ?? [] {
            waiter.resume()
        }
    }

    // MARK: - Orphaned transfers

    /// The key a transfer is recorded under: a hash of its request URL, which
    /// is what the system echoes back with a completion it kept across a
    /// process death. Hashed because stream URLs carry the access token, and
    /// the manifest must not.
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
                    order: reserveOrders(count: 1),
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

    // MARK: - Removal

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

    /// Drops a reference held by a non-track holder — a playlist's own cover
    /// or an artist's own picture.
    private func unreferenceArtwork(holderID: String) {
        for (key, var artworkEntry) in artworkEntries where artworkEntry.requiredBy.contains(holderID) {
            artworkEntry.requiredBy.remove(holderID)
            artworkEntries[key] = artworkEntry
        }
    }

    // MARK: - Batch bookkeeping

    private func reportDownloadFailure(_ track: BaseItemDto, _ error: Error) {
        errorMessage = "Couldn’t download “\(track.displayName)”. \(error.userFacingMessage)"
    }

    private func finishBatch(_ run: BatchRun) {
        // A cancelled run only now unwinding has nothing left to finish: the
        // cancel already tidied up after it, and the batch may since have
        // started again under the same id — a run whose row and task are not
        // this one's to remove.
        guard batchRunTokens[run.id] == run.token else { return }
        batchRunTokens[run.id] = nil
        if let batch = batches.first(where: { $0.id == run.id }), batch.failed > 0, errorMessage == nil {
            errorMessage = batch.total == 1
                ? nil // The per-file message already named the one track.
                : "Couldn’t download \(batch.failed) of \(batch.total) tracks."
        }
        batches.removeAll { $0.id == run.id }
        batchTasks[run.id] = nil
        activeBatchItems[run.id] = nil
        // Transfers recorded for this batch are done with it: whatever is
        // still listed belonged to a task that failed or was cancelled before
        // it could clear its own record, or to a previous launch's run.
        dropPendingTransfers(forBatch: run.id)
        deleteUnreferenced()
        persist()
    }

    private func dropPendingTransfers(forBatch id: String) {
        for (key, transfer) in pendingTransfers {
            if case let .audio(_, _, _, batchID, _, _) = transfer, batchID == id {
                pendingTransfers[key] = nil
            }
        }
    }

    /// Applies `change` to the run's progress row — unless the run has been
    /// cancelled, in which case the row is gone or belongs to a newer run.
    private func updateBatch(_ run: BatchRun, _ change: (inout Batch) -> Void) {
        guard batchRunTokens[run.id] == run.token,
              let index = batches.firstIndex(where: { $0.id == run.id })
        else { return }
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
}
