#if os(iOS)
import Foundation

/// The pseudo-playlist handed to Siri for open-ended requests, the successor
/// to handing over ``FavouriteSongsPlaylist`` directly.
///
/// Like the favourites playlist it has no server-side counterpart, and the
/// identifier is what carries the meaning: the system rehydrates entities by
/// id between resolution and playback (and the SiriKit path only ever returns
/// an identifier), so an in-memory marker would be stripped. When the id
/// comes back, ``SiriPlayback`` loads the user's ``DefaultPlaybackSetting``
/// and plays that instead — which is also what keeps the setting's
/// shuffle/repeat confined to open-ended requests: a named request can never
/// resolve to this id.
enum DefaultPlaybackPlaylist {
    static let id = "jellyjams.default-playback"

    static func entity(setting: DefaultPlaybackSetting?) -> PlaylistEntity {
        PlaylistEntity(id: id, title: setting?.title ?? FavouriteSongsPlaylist.title)
    }
}
#endif
