#if os(iOS) || os(tvOS)
import AppIntents
import Foundation

/// Shared queue-building for every Siri play path: one candidate in, one
/// `PlayerController` call out, with the app's play semantics. The audio
/// schema's intents, the classic-Siri handler and the tvOS activity path
/// all funnel through here.
enum SiriPlayback {

    /// Resolves the candidate to tracks and starts them on `player`.
    ///
    /// Songs play alone, albums and playlists play from their first track,
    /// and an artist shuffles their whole catalogue. The
    /// ``DefaultPlaybackPlaylist`` sentinel expands to the user's configured
    /// default, transport settings included. A plain play request replaces
    /// whatever is currently playing; `queueLocation` moves the tracks
    /// elsewhere in the queue when the request said so.
    ///
    /// Returns what is now playing, for the caller's dialog.
    @MainActor
    static func play(
        _ candidate: SiriCandidate,
        shuffleRequested: Bool,
        repeatRequested: Bool = false,
        queueLocation: SiriQueueLocation?,
        player: PlayerController,
        client: JellyfinService
    ) async throws -> String {
        let tracks: [BaseItemDto]
        var alwaysShuffle = false
        // Repeat is only touched when something asked for it: an explicit
        // "on repeat", or the default-playback setting. Otherwise the
        // player's current mode is left alone.
        var repeatOverride: RepeatMode?
        var nowPlaying: String
        if repeatRequested { repeatOverride = .repeatAll }
        switch candidate.kind {
        case .song:
            guard let item = try await client.item(byId: candidate.id) else {
                throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
            }
            tracks = [item]
            nowPlaying = candidate.subtitle.map { "\(candidate.title) by \($0)" } ?? candidate.title
        case .album:
            guard let item = try await client.item(byId: candidate.id) else {
                throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
            }
            tracks = try await client.tracks(for: item)
            nowPlaying = candidate.title
        case .artist:
            guard let item = try await client.item(byId: candidate.id) else {
                throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
            }
            // "Play <artist>" means "shuffle their catalogue", not an
            // alphabetical run-through.
            tracks = try await client.tracks(for: item)
            alwaysShuffle = true
            nowPlaying = candidate.title
        case .playlist:
            if let phrase = TextToTunesPlaylist.query(in: candidate.id) {
                // The Text to Tunes fallback: these words found nothing in
                // the library, so the backend picks the songs instead — the
                // sheet's own pipeline, played like any other queue. Every
                // failure along the way reads as "nothing matched", because
                // to the listener that is what happened.
                // The fallback hinges on a configured backend (resolution
                // offered the sentinel on that gate); a destination that
                // went away since says so, rather than pretending it searched.
                guard let destination = TextToTunes.currentDestination() else {
                    throw AppIntentError(wrapping: SiriIntentError.backendUnavailable)
                }
                do {
                    tracks = try await TextToTunes.tracks(
                        description: phrase,
                        limit: TextToTunes.defaultSongLimit,
                        destination: destination,
                        client: client
                    )
                } catch {
                    throw AppIntentError(wrapping: SiriIntentError.noMatch(phrase))
                }
            } else if candidate.id == DefaultPlaybackPlaylist.id {
                let setting = AppServices.shared.preferences.defaultPlayback
                let resolved = try await DefaultPlaybackResolver.resolve(setting: setting, client: client)
                tracks = resolved.tracks
                alwaysShuffle = resolved.shuffled
                // The setting supplies repeat only when the request didn't
                // ask for its own.
                if !repeatRequested { repeatOverride = resolved.repeatMode }
            } else if candidate.id == FavouriteSongsPlaylist.id {
                tracks = try await PlayerController.fallbackQueue(client: client)
            } else {
                guard let item = try await client.item(byId: candidate.id) else {
                    throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
                }
                tracks = try await client.tracks(for: item)
            }
            nowPlaying = candidate.title
        }
        guard !tracks.isEmpty else {
            throw AppIntentError(wrapping: SiriIntentError.itemUnavailable)
        }

        if let repeatOverride { player.repeatMode = repeatOverride }
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
    /// Text to Tunes and lyric matches are Jelly Jams Backend features, and
    /// the backend is optional — a request for one with no backend
    /// configured is a setup gap, not a sign-in gap.
    case backendUnavailable
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
        case .backendUnavailable:
            LocalizedStringResource(
                "That feature needs the Jelly Jams Backend. Set it up in the Jelly Jams settings first.",
                comment: "Spoken when a Text to Tunes or lyric match request arrives with no Jelly Jams Backend configured."
            )
        }
    }
}
#endif
