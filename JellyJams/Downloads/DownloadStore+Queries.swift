import Foundation
import JellyfinAPI

// MARK: - Queries

extension DownloadStore {
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
        return Self.existingFile(in: directory, named: filename)
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
            // is the first album that has anywhere to look; the fallback
            // covers an album whose songs carried no image tag at all.
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

    /// The songs saved for the group an id and kind name. A song resolves to
    /// itself only through ``tracks(for:)``.
    func songsMatchingGroupID(_ id: String, kind: GroupKind) -> [Entry] {
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

    // MARK: - Artwork lookup

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
        return Self.existingFile(in: artworkDirectory, named: filename)
    }

}
