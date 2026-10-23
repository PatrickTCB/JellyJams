import Foundation
import JellyfinAPI

// MARK: - Artwork

extension DownloadStore {
    /// Downloads and saves one artwork file, deduplicated by the item that owns
    /// the image plus its tag. Awaited by the caller but fire-and-forget in
    /// spirit: failures are silent, because audio is the priority and the
    /// header falls back to a placeholder.
    func downloadArtwork(
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
    func downloadArtistArtwork(for item: BaseItemDto, via client: JellyfinService) async {
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
    func startArtistArtworkSync() {
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
    func referenceArtwork(for track: BaseItemDto, trackId: String) {
        for key in Self.artworkKeys(for: track) {
            guard var artworkEntry = artworkEntries[key] else { continue }
            artworkEntry.requiredBy.insert(trackId)
            artworkEntries[key] = artworkEntry
            return
        }
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

    static func artworkKey(ownerID: String?, tag: String) -> String {
        guard let ownerID, !ownerID.isEmpty else { return tag }
        return "\(ownerID)|\(tag)"
    }
}
