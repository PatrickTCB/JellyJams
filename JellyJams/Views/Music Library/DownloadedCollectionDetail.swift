import SwiftUI

/// A downloaded collection opened from the Downloads section: the tracks
/// saved for it, entirely from the manifest — no server involved. Playback
/// resolves each track to its saved file via ``DownloadStore/localURL(forItemId:)``.
///
/// Pushed as its own value type (not the bare `BaseItemDto`) so it can share
/// a navigation stack with library destinations without both claiming to
/// resolve `BaseItemDto` pushes.
struct DownloadedCollectionDetail: View {
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var player: PlayerController
    let collection: BaseItemDto
    
    var body: some View {
        if collection.type == .musicAlbum {
            TrackListDetail(
                headerItem: collection,
                subtitle: collection.subtitleArtist,
                showsGenres: false,
                showsSimilarAlbums: false,
                downloaded: true
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } else if collection.type == .playlist {
            TrackListDetail(headerItem: collection, showArtworkInRows: true)
        } else {
            var tracks: [BaseItemDto] {
                downloads.tracks(forItemId: collection.id ?? "")
            }
            
            List {
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track) {
                            player.play(tracks, startAt: index)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if tracks.isEmpty {
                    ContentUnavailableView("No songs", systemImage: "music.note")
                }
            }
            .navigationTitle(collection.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

/// Navigation value for a downloaded collection. Distinct from `BaseItemDto`
/// so ``ItemDetailRouter`` doesn't claim pushes that should open the offline
/// detail instead.
struct DownloadedCollectionRef: Hashable {
    let id: String
    let name: String
    let isArtist: Bool

    init?(_ item: BaseItemDto) {
        guard let id = item.id else { return nil }
        self.id = id
        self.name = item.displayName
        self.isArtist = item.itemType == .musicArtist
    }
}

/// A downloaded artist opened from the Downloads section: their downloaded
/// albums, entirely from the manifest — no server involved. Each album opens
/// the same offline album detail a downloaded album does.
struct DownloadedArtistDetail: View {
    let artist: BaseItemDto

    @EnvironmentObject private var downloads: DownloadStore

    private var albums: [BaseItemDto] { downloads.downloadedAlbums(forArtistId: artist.id ?? "") }

    var body: some View {
        List {
            Section {
                ForEach(albums) { album in
                    if let ref = DownloadedCollectionRef(album) {
                        NavigationLink(value: ref) {
                            row(for: album)
                        }
                    } else {
                        row(for: album)
                    }
                }
            } header: {
                Text(Format.albumCount(albums.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .overlay {
            if albums.isEmpty {
                ContentUnavailableView("No downloaded albums", systemImage: "square.stack")
            }
        }
        .navigationTitle(artist.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(for album: BaseItemDto) -> some View {
        ItemRow(item: album)
    }
}
