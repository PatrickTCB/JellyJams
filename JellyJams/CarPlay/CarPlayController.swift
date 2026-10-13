#if os(iOS)
import CarPlay
import UIKit

/// Builds and drives the CarPlay interface.
///
/// A single shared instance is configured from the SwiftUI app — which owns the
/// service objects — and connected from ``CarPlaySceneDelegate`` when CarPlay
/// attaches. The root is a ``CPTabBarTemplate`` with Favourites (the default
/// tab), Downloads and Library, mirroring the iOS Music app. Each tab is a
/// ``CPListTemplate`` whose rows push item lists; selecting a track starts
/// playback and presents the system Now Playing template.
@MainActor
final class CarPlayController {
    static let shared = CarPlayController()

    private weak var interfaceController: CPInterfaceController?

    private var session: SessionStore?
    private var player: PlayerController?
    private var downloads: DownloadStore?

    private init() {}

    /// Captures the app's service objects. Called from the SwiftUI app; the
    /// references are read lazily by the handlers, so a template can be built
    /// before or after this runs.
    func configure(session: SessionStore, player: PlayerController, downloads: DownloadStore) {
        self.session = session
        self.player = player
        self.downloads = downloads
    }

    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(rootTemplate(), animated: false, completion: nil)
    }

    func disconnect(_ interfaceController: CPInterfaceController) {
        if self.interfaceController === interfaceController {
            self.interfaceController = nil
        }
    }

    // MARK: - Root

    private func rootTemplate() -> CPTabBarTemplate {
        let favourites = CPListTemplate(title: "Favourites", sections: [
            CPListSection(items: [
                shuffleItem("Shuffle Favourite Songs") { [weak self] in
                    self?.shuffleOnline(LibraryQuery(list: .favouriteSongs))
                },
            ]),
            CPListSection(items: [
                navItem("Albums", systemImage: "record.circle") { [weak self] in
                    self?.pushOnlineList(title: "Favourite Albums", query: LibraryQuery(list: .favouriteAlbums))
                },
                navItem("Artists", systemImage: "music.mic") { [weak self] in
                    self?.pushOnlineList(title: "Favourite Artists", query: LibraryQuery(list: .favouriteArtists))
                },
                navItem("Playlists", systemImage: "music.note.list") { [weak self] in
                    self?.pushOnlineList(title: "Favourite Playlists", query: LibraryQuery(list: .favouritePlaylists))
                },
            ]),
        ])

        let downloads = CPListTemplate(title: "Downloads", sections: [
            CPListSection(items: [
                shuffleItem("Shuffle All Downloads") { [weak self] in
                    self?.shuffleDownloads()
                },
            ]),
            CPListSection(items: [
                navItem("Albums", systemImage: "record.circle") { [weak self] in
                    self?.pushDownloadedGroups(kind: .album, title: "Albums")
                },
                navItem("Artists", systemImage: "music.mic") { [weak self] in
                    self?.pushDownloadedGroups(kind: .artist, title: "Artists")
                },
                navItem("Playlists", systemImage: "music.note.list") { [weak self] in
                    self?.pushDownloadedGroups(kind: .playlist, title: "Playlists")
                },
            ]),
        ])

        let library = CPListTemplate(title: "Library", sections: [
            CPListSection(items: [
                shuffleItem("Shuffle All Songs") { [weak self] in
                    self?.shuffleOnline(LibraryQuery(list: .songs))
                },
            ]),
            CPListSection(items: [
                navItem("Playlists", systemImage: "music.note.list") { [weak self] in
                    self?.pushOnlineList(title: "Playlists", query: LibraryQuery(list: .playlists))
                },
                navItem("Albums", systemImage: "record.circle") { [weak self] in
                    self?.pushOnlineList(title: "Albums", query: LibraryQuery(list: .albums))
                },
                navItem("Artists", systemImage: "music.mic") { [weak self] in
                    self?.pushOnlineList(title: "Artists", query: LibraryQuery(list: .artists))
                },
                navItem("Songs", systemImage: "music.note") { [weak self] in
                    self?.pushOnlineSongs()
                },
            ]),
        ])

        return CPTabBarTemplate(templates: [favourites, downloads, library])
    }

    // MARK: - Row builders

    /// A "Shuffle" row shown at the top of each tab, above the navigation rows.
    private func shuffleItem(_ title: String, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: "shuffle"))
        item.handler = { _, completion in
            action()
            completion()
        }
        return item
    }

    /// A row that pushes another list template when tapped.
    private func navItem(_ title: String, systemImage: String, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: systemImage))
        item.accessoryType = .disclosureIndicator
        item.handler = { _, completion in
            action()
            completion()
        }
        return item
    }

    /// A collection row (album/artist/playlist) with artwork and a detail push.
    private func collectionItem(_ item: BaseItemDto, onTap: @escaping () -> Void) -> CPListItem {
        let listItem = CPListItem(text: item.displayName, detailText: detailText(for: item))
        listItem.accessoryType = .disclosureIndicator
        listItem.handler = { _, completion in
            onTap()
            completion()
        }
        loadArtwork(item, into: listItem)
        return listItem
    }

    /// Rows for a track list: tapping a row plays the list from that index.
    private func trackItems(_ tracks: [BaseItemDto]) -> [CPListItem] {
        tracks.enumerated().map { index, track in
            let item = CPListItem(text: track.displayName, detailText: track.subtitleArtist)
            item.handler = { [weak self] _, completion in
                self?.play(tracks, startAt: index)
                completion()
            }
            return item
        }
    }

    private func detailText(for item: BaseItemDto) -> String? {
        switch item.itemType {
        case .musicAlbum: return item.subtitleAlbumArtist
        default: return nil
        }
    }

    // MARK: - Online (favourites & library)

    private func pushOnlineList(title: String, query: LibraryQuery) {
        guard session != nil else { return }
        let template = pushLoadingTemplate(title: title)
        Task {
            let items = await fetchOnline(query, limit: 500)
            template.updateSections([CPListSection(items: items.map { item in
                self.collectionItem(item) {
                    self.pushOnlineCollection(item)
                }
            })])
            template.emptyViewTitleVariants = ["Nothing here"]
        }
    }

    private func pushOnlineSongs() {
        guard session != nil else { return }
        let template = pushLoadingTemplate(title: "Songs")
        Task {
            let songs = await fetchOnline(LibraryQuery(list: .songs), limit: 1000)
            template.updateSections([CPListSection(items: trackItems(songs))])
            template.emptyViewTitleVariants = ["No songs"]
        }
    }

    private func pushOnlineCollection(_ item: BaseItemDto) {
        if item.itemType == .musicArtist {
            pushOnlineAlbums(for: item)
        } else {
            pushOnlineTracks(for: item)
        }
    }

    private func pushOnlineTracks(for item: BaseItemDto) {
        guard let session else { return }
        let template = pushLoadingTemplate(title: item.displayName)
        Task {
            do {
                let tracks = try await session.library.tracks(for: item)
                template.updateSections([CPListSection(items: trackItems(tracks))])
                template.emptyViewTitleVariants = ["No songs"]
            } catch {
                template.emptyViewTitleVariants = ["Couldn’t load songs"]
            }
        }
    }

    private func pushOnlineAlbums(for artist: BaseItemDto) {
        guard let session, let artistId = artist.id else { return }
        let template = pushLoadingTemplate(title: artist.displayName)
        Task {
            do {
                let albums = try await session.client?.albums(forArtistId: artistId) ?? []
                template.updateSections([CPListSection(items: albums.map { album in
                    self.collectionItem(album) {
                        self.pushOnlineTracks(for: album)
                    }
                })])
                template.emptyViewTitleVariants = ["No albums"]
            } catch {
                template.emptyViewTitleVariants = ["Couldn’t load albums"]
            }
        }
    }

    private func fetchOnline(_ query: LibraryQuery, limit: Int) async -> [BaseItemDto] {
        guard let session else { return [] }
        do {
            let result = try await session.library.page(query, startIndex: 0, limit: limit)
            return result.items ?? []
        } catch {
            return []
        }
    }

    private func shuffleOnline(_ query: LibraryQuery) {
        guard let player else { return }
        Task {
            let songs = await fetchOnline(query, limit: 1000)
            guard !songs.isEmpty else { return }
            player.play(songs, shuffled: true)
            pushNowPlaying()
        }
    }

    // MARK: - Downloads

    /// A downloaded group row. Everything about it comes from the manifest and
    /// the saved artwork file: browsing downloads in CarPlay issues no request
    /// either, so a missing cover stays a missing cover rather than a fetch.
    private func downloadedItem(_ group: DownloadStore.DownloadGroup, onTap: @escaping () -> Void) -> CPListItem {
        let listItem = CPListItem(text: group.title, detailText: downloadedDetail(for: group))
        listItem.accessoryType = .disclosureIndicator
        listItem.handler = { _, completion in
            onTap()
            completion()
        }
        if let url = downloads?.localArtworkURL(for: group), let image = CarPlayArtwork.image(fileAt: url) {
            listItem.setImage(image)
        }
        return listItem
    }

    private func downloadedDetail(for group: DownloadStore.DownloadGroup) -> String? {
        switch group.kind {
        case .artist:
            return Format.albumCount(downloads?.downloadedAlbums(forArtistID: group.id).count ?? 0)
        case .album, .playlist, .genre:
            guard let total = group.totalSongs, total > group.downloadedSongs else {
                return Format.songCount(group.downloadedSongs)
            }
            return "\(Format.songCount(group.downloadedSongs)) of \(total)"
        }
    }

    private func pushDownloadedGroups(kind: DownloadStore.GroupKind, title: String) {
        guard let downloads else { return }
        let groups = downloads.groups(kind: kind)
        let template = CPListTemplate(title: title, sections: [
            CPListSection(items: groups.map { group in
                self.downloadedItem(group) {
                    self.pushDownloadedGroup(group)
                }
            }),
        ])
        template.emptyViewTitleVariants = ["Nothing downloaded"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func pushDownloadedGroup(_ group: DownloadStore.DownloadGroup) {
        switch group.kind {
        case .artist:
            pushDownloadedAlbums(for: group)
        case .album, .playlist, .genre:
            pushDownloadedTracks(for: group)
        }
    }

    private func pushDownloadedAlbums(for artist: DownloadStore.DownloadGroup) {
        guard let downloads else { return }
        let albums = downloads.downloadedAlbums(forArtistID: artist.id)
        let template = CPListTemplate(title: artist.title, sections: [
            CPListSection(items: albums.map { album in
                self.downloadedItem(album) {
                    self.pushDownloadedTracks(for: album)
                }
            }),
        ])
        template.emptyViewTitleVariants = ["No albums"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func pushDownloadedTracks(for group: DownloadStore.DownloadGroup) {
        guard let downloads else { return }
        let tracks = downloads.tracks(in: group)
        let template = CPListTemplate(title: group.title, sections: [
            CPListSection(items: trackItems(tracks)),
        ])
        template.emptyViewTitleVariants = ["No songs"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func shuffleDownloads() {
        guard let player, let downloads else { return }
        let songs = downloads.downloadedSongs()
        guard !songs.isEmpty else { return }
        player.play(songs, shuffled: true)
        pushNowPlaying()
    }

    // MARK: - Playback

    private func play(_ tracks: [BaseItemDto], startAt index: Int) {
        guard let player else { return }
        player.play(tracks, startAt: index)
        pushNowPlaying()
    }

    /// Presents the system Now Playing template (also reached via the top-right
    /// Now Playing button CarPlay shows automatically for audio apps).
    private func pushNowPlaying() {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController.topTemplate !== nowPlaying {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    // MARK: - Helpers

    /// Pushes an empty template with a "Loading…" empty view; callers fill in
    /// its sections when their data arrives.
    private func pushLoadingTemplate(title: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        return template
    }

    private func loadArtwork(_ item: BaseItemDto, into listItem: CPListItem) {
        guard let url = session?.library.artworkURL(for: item, size: 200) else { return }
        Task {
            if let image = await CarPlayArtwork.image(from: url) {
                listItem.setImage(image)
            }
        }
    }
}

/// Loads artwork for CarPlay rows, reusing the app's memory cache.
enum CarPlayArtwork {
    /// A saved artwork file, for rows that must not ask the server — a
    /// downloaded group's cover is on disk or absent.
    static func image(fileAt url: URL) -> UIImage? {
        if let cached = ImageCache.shared.image(for: url) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        ImageCache.shared.set(image, for: url)
        return image
    }

    static func image(from url: URL) async -> UIImage? {
        if let cached = ImageCache.shared.image(for: url) { return cached }
        do {
            let (data, response) = try await ArtworkLoader.session.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let image = UIImage(data: data)
            else { return nil }
            ImageCache.shared.set(image, for: url)
            return image
        } catch {
            return nil
        }
    }
}
#endif
