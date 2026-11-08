import SwiftUI

/// A downloaded collection opened from the Downloads section: the songs saved
/// for it, entirely from the manifest — browsing involves no server and no
/// artwork request, the offline playlist's refresh button being the one
/// deliberate exception. Playback resolves each track to its saved file via
/// ``DownloadStore/localURL(forItemId:)``.
///
/// Albums and playlists render the way their Library pages do: a header built
/// from the group's own metadata over a list of the songs on disk. Playlists
/// keep their saved membership order; albums are disc/track sorted by
/// ``TrackListDetail``. A downloaded artist renders the way the Library artist
/// page does — see ``DownloadedArtistDetail``.
///
/// Pushed as its own value type (not the bare `BaseItemDto`) so it can share a
/// navigation stack with library destinations without both claiming to resolve
/// `BaseItemDto` pushes.
struct DownloadedCollectionDetail: View {
    let group: DownloadStore.DownloadGroup

    var body: some View {
        TrackListDetail(
            headerItem: group.item,
            subtitle: group.item.artistNameForGroup,
            showArtworkInRows: group.kind == .playlist,
            downloaded: true
        )
        .downloadsBrowsing()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Navigation value for a downloaded group. Distinct from `BaseItemDto` so
/// ``ItemDetailRouter`` doesn't claim pushes that should open the offline detail
/// instead, and carries the kind because albums, artists and playlists can share
/// an id space.
struct DownloadedGroupRef: Hashable {
    let id: String
    let kind: DownloadStore.GroupKind
    let title: String

    init(_ group: DownloadStore.DownloadGroup) {
        id = group.id
        kind = group.kind
        title = group.title
    }
}

/// A downloaded artist opened from the Downloads section: the same layout the
/// Library artist page shows — a circular header over an adaptive grid of
/// their albums — built entirely from the manifest, with no server involved.
/// The header's cover is the artist's own picture when one was saved with the
/// download (or filled in by the sign-in sync), else one of their albums'; its
/// Play and Shuffle buttons start the songs on disk with playback resolving
/// each to its saved file, and each album opens the same offline album detail a
/// downloaded album does.
struct DownloadedArtistDetail: View {
    let artist: DownloadStore.DownloadGroup

    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var player: PlayerController

    private var albums: [DownloadStore.DownloadGroup] {
        downloads.downloadedAlbums(forArtistID: artist.id)
    }

    /// The artist's songs on disk, album by album and each album in the order
    /// its detail lists — what the header's Play and Shuffle buttons start.
    private var songs: [BaseItemDto] {
        albums.flatMap { downloads.tracks(in: $0).inAlbumOrder() }
    }

    /// The header's count lines with the artist's whole disk usage under
    /// them: albums, songs, and the space they take up. The group overload
    /// sizes the artist — their stand-in item carries no image tag, so the
    /// group is what knows their picture's key.
    private var subtitle: String {
        let counts = Format.albumAndSongCount(albums.count, songs.count)
        let bytes = downloads.byteCount(for: artist)
        return bytes > 0 ? "\(counts)\n\(Format.byteCount(bytes))" : counts
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CollectionHeader(
                    item: artist.item,
                    subtitle: subtitle,
                    isCircular: true,
                    localArtworkURL: downloads.localArtworkURL(for: artist),
                    canPlay: !songs.isEmpty,
                    onPlay: { player.play(songs) },
                    onShuffle: { player.play(songs, shuffled: true) }
                )

                if !albums.isEmpty {
                    Text("Albums")
                        .font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(value: DownloadedGroupRef(album)) {
                                DownloadedGroupCell(group: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
        }
        .downloadsBrowsing()
        .overlay {
            if albums.isEmpty {
                ContentUnavailableView("No downloaded albums", systemImage: "square.stack")
            }
        }
        .navigationTitle(artist.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
