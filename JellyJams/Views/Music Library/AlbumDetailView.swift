import SwiftUI

struct AlbumDetailView: View {
    let album: BaseItemDto

    var body: some View {
        TrackListDetail(
            headerItem: album,
            subtitle: album.subtitleAlbumArtist,
            subtitleItem: artistItem,
            showsGenres: true,
            showsSimilarAlbums: true
        )
    }

    /// A minimal artist dto so the header's subtitle can push the artist
    /// page; its id is what routing loads by. Fails when the album carries no
    /// album-artist ids, in which case the subtitle stays plain text.
    private var artistItem: BaseItemDto? {
        album.albumArtists?.first.flatMap { pair in
            pair.id.map { BaseItemDto(id: $0, name: pair.name, type: .musicArtist) }
        }
    }
}
