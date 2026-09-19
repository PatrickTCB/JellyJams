#if os(iOS)
import AppIntents

/// The value Siri fills ``PlayAudioIntent``'s `audioEntity` parameter with:
/// whatever the person named, be it a song, an album, an artist or a
/// playlist.
@UnionValue
enum AudioEntity {
    case song(SongEntity)
    case album(AlbumEntity)
    case artist(ArtistEntity)
    case playlist(PlaylistEntity)

    var title: String {
        switch self {
        case .song(let song): song.title
        case .album(let album): album.title
        case .artist(let artist): artist.name
        case .playlist(let playlist): playlist.title
        }
    }
}
#endif
