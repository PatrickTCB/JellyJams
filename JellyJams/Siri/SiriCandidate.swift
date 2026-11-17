#if os(iOS) || os(tvOS)
import Foundation
import JellyfinAPI

/// A resolved library candidate, in schema-free terms.
///
/// This is the currency of the shared Siri pipeline — ``SiriAudioSearch``
/// produces these, ``SiriPlayback`` plays them, and the classic-Siri handler
/// resolves them — on both platforms that have the SiriKit Media domain.
/// The audio schema's ``AudioEntity`` union and its `@AppEntity` types cannot
/// compile for tvOS (the schema domains are unavailable there), so the iOS
/// schema layer maps to and from this type at its edge instead.
///
/// The server ``item`` snapshot rides along so the schema layer can rebuild
/// its entities without another round-trip; it is nil only for the synthetic
/// playlists (the favourites shuffle, the default-playback sentinel and the
/// Text to Tunes fallback), whose meaning lives in the identifier.
struct SiriCandidate: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case song, album, artist, playlist
    }

    let id: String
    let kind: Kind
    let title: String
    /// The artist name for songs and albums; nil for the other kinds.
    let subtitle: String?
    let artworkURL: URL?
    let item: BaseItemDto?

    init(
        id: String,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        item: BaseItemDto? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.item = item
    }

    /// A candidate standing in for a server item, taking its identity and
    /// display strings the same way the schema entities do.
    init(item: BaseItemDto, kind: Kind, artworkURL: URL?) {
        self.init(
            id: item.id ?? item.displayName,
            kind: kind,
            title: item.displayName,
            subtitle: kind == .song ? item.subtitleArtist : (kind == .album ? item.subtitleAlbumArtist : nil),
            artworkURL: artworkURL,
            item: item
        )
    }
}

/// Where in the queue a play request's tracks should land, in schema-free
/// terms. The audio schema's `QueueInsertionLocation` maps onto this at the
/// iOS edge; the classic-Siri paths always replace the queue (nil).
enum SiriQueueLocation: Sendable {
    case next
    case tail
}
#endif
