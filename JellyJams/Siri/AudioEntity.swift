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

// MARK: - Shared-pipeline mapping

extension AudioEntity {
    /// The schema-free form the shared pipeline (``SiriAudioSearch``,
    /// ``SiriPlayback``, the classic-Siri handler) works in. The tvOS
    /// activity path uses that form directly; the schema intents map theirs
    /// onto it before playing.
    var candidate: SiriCandidate {
        switch self {
        case .song(let song):
            SiriCandidate(id: song.id, kind: .song, title: song.title, subtitle: song.artistName, artworkURL: song.artworkURL, item: song.item)
        case .album(let album):
            SiriCandidate(id: album.id, kind: .album, title: album.title, subtitle: album.artistName, artworkURL: album.artworkURL, item: album.item)
        case .artist(let artist):
            SiriCandidate(id: artist.id, kind: .artist, title: artist.name, artworkURL: artist.artworkURL, item: artist.item)
        case .playlist(let playlist):
            SiriCandidate(id: playlist.id, kind: .playlist, title: playlist.title, artworkURL: playlist.artworkURL, item: playlist.item)
        }
    }

    /// Rebuilds the schema union from a shared-pipeline candidate. Server
    /// candidates carry their ``SiriCandidate/item`` snapshot, so this needs
    /// no round-trip; a kind whose snapshot is missing (only the synthetic
    /// playlists ever are) keeps its identity in a minimal stand-in item —
    /// except playlists, which have a synthetic initializer of their own.
    init(candidate: SiriCandidate) {
        switch candidate.kind {
        case .song:
            self = .song(SongEntity(
                item: candidate.item ?? BaseItemDto(id: candidate.id, name: candidate.title, type: .audio),
                artworkURL: candidate.artworkURL
            ))
        case .album:
            self = .album(AlbumEntity(
                item: candidate.item ?? BaseItemDto(id: candidate.id, name: candidate.title, type: .musicAlbum),
                artworkURL: candidate.artworkURL
            ))
        case .artist:
            self = .artist(ArtistEntity(
                item: candidate.item ?? BaseItemDto(id: candidate.id, name: candidate.title, type: .musicArtist),
                artworkURL: candidate.artworkURL
            ))
        case .playlist:
            if let item = candidate.item {
                self = .playlist(PlaylistEntity(item: item, artworkURL: candidate.artworkURL))
            } else {
                self = .playlist(PlaylistEntity(id: candidate.id, title: candidate.title))
            }
        }
    }
}
#endif
