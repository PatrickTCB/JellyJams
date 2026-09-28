#if os(iOS)
import AppIntents
import Foundation
import MediaIntents

extension AudioEntity {
    /// Shared resolution of Siri's audio searches against the Jellyfin
    /// library.
    ///
    /// The system fills ``PlayAudioIntent``'s `audioEntity` by calling
    /// `values(for:)` on each concrete entity's default query (``SongQuery``,
    /// ``AlbumQuery``, ``ArtistQuery``, ``PlaylistQuery``). Each of those
    /// conforms to `IntentValueQuery` by delegating here and keeping its own
    /// kind, so all four draw on one ranked candidate list.
    ///
    /// An open-ended request (`.unspecified`) resolves to the
    /// ``DefaultPlaybackPlaylist`` sentinel, which ``SiriPlayback`` swaps for
    /// the user's configured default at play time (favourites shuffle when
    /// unset).
    struct AudioSearchQuery {
        static func entities(for input: AudioSearch) async throws -> [AudioEntity] {
            let client = await AppServices.shared.session.client
            guard let client else { return [] }

            switch input.criteria {
            case .searchQuery(let query):
                return try await SiriAudioSearch.search(matching: query, client: client)
            case .unspecified:
                // The sentinel stands in for whatever the user configured as
                // their default playback; `SiriPlayback` swaps it at play time.
                let setting = await AppServices.shared.preferences.defaultPlayback
                return [.playlist(DefaultPlaybackPlaylist.entity(setting: setting))]
            case .url:
                return []
            @unknown default:
                return []
            }
        }
    }
}
#endif
