#if os(iOS)
import AppIntents
import Foundation
import MediaIntents

extension AudioEntity {
    /// Resolves Siri's audio searches against the Jellyfin library.
    ///
    /// This is the entry point the system uses to fill
    /// ``PlayAudioIntent``'s `audioEntity` parameter: Siri classifies the
    /// request into an ``AudioSearch`` and calls ``values(for:)``, and the
    /// returned entities become the candidates Siri picks from.
    struct AudioSearchQuery {}
}

extension AudioEntity.AudioSearchQuery: IntentValueQuery {
    func values(for input: AudioSearch) async throws -> [AudioEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }

        switch input.criteria {
        case .searchQuery(let query):
            return try await SiriAudioSearch.search(matching: query, client: client)
        case .unspecified:
            // "Play Jelly Jams" with nothing named: offer the synthetic
            // favourites playlist, which the play intent turns into a
            // favourites shuffle.
            return [.playlist(FavouriteSongsPlaylist.entity())]
        case .url:
            return []
        @unknown default:
            return []
        }
    }
}
#endif
