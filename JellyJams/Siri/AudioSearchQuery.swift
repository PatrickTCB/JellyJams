#if os(iOS)
import AppIntents
import Foundation
import MediaIntents

extension AudioEntity {
    /// The structured search Siri uses to fill ``PlayAudioIntent``'s
    /// `audioEntity` parameter.
    ///
    /// The audio schema asks the app's ``IntentValueQuery`` for candidates by
    /// handing it an ``AudioSearch``; this query answers for the whole union,
    /// so one ranked candidate list serves every entity kind.
    ///
    /// An open-ended request (`.unspecified`) resolves to the
    /// ``DefaultPlaybackPlaylist`` sentinel, which ``SiriPlayback`` swaps for
    /// the user's configured default at play time (favourites shuffle when
    /// unset).
    struct AudioSearchQuery {}
}

extension AudioEntity.AudioSearchQuery: IntentValueQuery {
    func values(for input: AudioSearch) async throws -> [AudioEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }

        switch input.criteria {
        case .searchQuery(let query):
            let found = try await SiriAudioSearch.search(matching: query, client: client)
            if found.isEmpty, let fallback = await TextToTunesPlaylist.fallbackEntity(for: query) {
                // Nothing in the library answers these words, so they read
                // as a description rather than a name: the Text to Tunes
                // sentinel takes them to the backend at play time.
                return [fallback]
            }
            return found
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
#endif
