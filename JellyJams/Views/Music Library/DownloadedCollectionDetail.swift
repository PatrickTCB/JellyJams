import SwiftUI

/// A downloaded collection opened from the Downloads section: the songs saved
/// for it, entirely from the manifest — no server involved, and no artwork
/// request either. Playback resolves each track to its saved file via
/// ``DownloadStore/localURL(forItemId:)``.
///
/// Albums, artists and playlists all render the same way: a header built from
/// the group's own metadata over a list of the songs on disk. Playlists keep
/// their saved membership order; albums are disc/track sorted by
/// ``TrackListDetail``.
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

/// A downloaded artist opened from the Downloads section: the albums of theirs
/// with songs on disk, entirely from the manifest — no server involved. Each
/// album opens the same offline album detail a downloaded album does.
struct DownloadedArtistDetail: View {
    let artist: DownloadStore.DownloadGroup

    @EnvironmentObject private var downloads: DownloadStore

    private var albums: [DownloadStore.DownloadGroup] {
        downloads.downloadedAlbums(forArtistID: artist.id)
    }

    var body: some View {
        List {
            Section {
                ForEach(albums) { album in
                    // The row owns its link and its remove swipe, so an artist's
                    // albums behave exactly like the Albums tab's.
                    DownloadedItemRow(group: album)
                }
            } header: {
                Text(Format.albumCount(albums.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
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
