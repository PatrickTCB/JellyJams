import SwiftUI

struct AlbumDetailView: View {
    let album: BaseItemDto

    var body: some View {
        TrackListDetail(
            headerItem: album,
            subtitle: album.subtitleArtist,
            showsGenres: true,
            showsSimilarAlbums: true
        )
    }
}
