#if os(iOS)
import AppIntents
import Foundation

/// Shared queue-building for the audio intents: one entity in, one
/// `PlayerController` call out, with the app's play semantics.
enum SiriPlayback {

    /// Resolves the entity to tracks and starts them on `player`.
    ///
    /// Songs play alone, albums and playlists play from their first track,
    /// and an artist shuffles their whole catalogue. A plain play request
    /// replaces whatever is currently playing; `queueLocation` moves the
    /// tracks elsewhere in the queue when the request said so.
    ///
    /// Returns what is now playing, for the caller's dialog.
    @MainActor
    static func play(
        _ entity: AudioEntity,
        shuffleRequested: Bool,
        queueLocation: QueueInsertionLocation?,
        player: PlayerController,
        client: JellyfinService
    ) async throws -> String {
        let tracks: [BaseItemDto]
        var alwaysShuffle = false
        var nowPlaying: String
        switch entity {
        case .song(let song):
            guard let item = try await client.item(byId: song.id) else {
                throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
            }
            tracks = [item]
            nowPlaying = "\(song.title) by \(song.artistName)"
        case .album(let album):
            guard let item = try await client.item(byId: album.id) else {
                throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
            }
            tracks = try await client.tracks(for: item)
            nowPlaying = album.title
        case .artist(let artist):
            guard let item = try await client.item(byId: artist.id) else {
                throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
            }
            // "Play <artist>" means "shuffle their catalogue", not an
            // alphabetical run-through.
            tracks = try await client.tracks(for: item)
            alwaysShuffle = true
            nowPlaying = artist.name
        case .playlist(let playlist):
            if playlist.id == FavouriteSongsPlaylist.id {
                tracks = try await PlayerController.fallbackQueue(client: client)
            } else {
                guard let item = try await client.item(byId: playlist.id) else {
                    throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
                }
                tracks = try await client.tracks(for: item)
            }
            nowPlaying = playlist.title
        }
        guard !tracks.isEmpty else {
            throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
        }

        let shuffled = alwaysShuffle || shuffleRequested
        switch queueLocation {
        case .none:
            player.play(tracks, shuffled: shuffled)
        case .some(.next):
            player.playNext(tracks)
        case .some(.tail):
            player.addToQueue(tracks)
        }
        return nowPlaying
    }
}

// MARK: - Errors

enum SiriIntentError: Error {
    case notSignedIn
    case noMatch(String)
    case itemUnavailable
}

extension SiriIntentError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn:
            LocalizedStringResource(
                "You need to be signed in to Jelly Jams first. Open the app to sign in.",
                comment: "Spoken by Siri when a play request arrives while the user is signed out."
            )
        case .noMatch(let query):
            LocalizedStringResource(
                "Nothing matched '\(query)' on your Jellyfin server.",
                comment: "Spoken when a search or play request finds no results."
            )
        case .itemUnavailable:
            LocalizedStringResource(
                "That couldn't be found on your Jellyfin server.",
                comment: "Spoken when the requested audio isn't on the user's server."
            )
        }
    }
}
#endif
