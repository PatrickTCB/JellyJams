#if os(iOS) || os(tvOS)
import Foundation

/// The pseudo-playlist handed to Siri for open-ended requests, the successor
/// to handing over ``FavouriteSongsPlaylist`` directly.
///
/// Like the favourites playlist it has no server-side counterpart, and the
/// identifier is what carries the meaning: the system rehydrates entities by
/// id between resolution and playback (and the SiriKit path only ever
/// returns an identifier), so an in-memory marker would be stripped. When
/// the id comes back, ``SiriPlayback`` loads the user's
/// ``DefaultPlaybackSetting`` and plays that instead — which is also what
/// keeps the setting's shuffle/repeat confined to open-ended requests: a
/// named request can never resolve to this id.
enum DefaultPlaybackPlaylist {
    static let id = "jellyjams.default-playback"

    static func title(setting: DefaultPlaybackSetting?) -> String {
        setting?.title ?? FavouriteSongsPlaylist.title
    }

    static func candidate(setting: DefaultPlaybackSetting?) -> SiriCandidate {
        SiriCandidate(id: id, kind: .playlist, title: title(setting: setting))
    }

    #if os(iOS)
    static func entity(setting: DefaultPlaybackSetting?) -> PlaylistEntity {
        PlaylistEntity(id: id, title: title(setting: setting))
    }
    #endif
}

/// The favourites shuffle, as a playlist Siri and Shortcuts can pick.
///
/// It has no server-side counterpart: ``SiriPlayback`` recognises the id and
/// plays a shuffle of the user's favourite songs (all songs when nothing is
/// favourited). Encoding this as a real entity means the behaviour survives
/// the system's identifier-based rehydration, which would strip any in-memory
/// marker. Open-ended requests now resolve through
/// ``DefaultPlaybackPlaylist`` instead; this remains what an unset default
/// plays, an explicit choice in the Shortcuts pickers, and the classic-Siri
/// handler's fallback for a missing or unresolvable identifier.
enum FavouriteSongsPlaylist {
    static let id = "jellyjams.favourite-songs"
    static let title = "Favourite Songs"

    static func candidate() -> SiriCandidate {
        SiriCandidate(id: id, kind: .playlist, title: title)
    }

    #if os(iOS)
    static func entity() -> PlaylistEntity {
        PlaylistEntity(id: id)
    }
    #endif
}
#endif
