#if os(iOS)
import Foundation
import Intents

/// A resolved library candidate, in `Sendable` terms.
private struct Candidate: Sendable {
    let id: String
    let title: String
    let type: INMediaItemType
    let artworkURL: URL?
}

/// Bridges an ObjC completion block into a `Task`. Siri invokes these blocks
/// exactly once and never touches them afterwards, so the one-shot hand-off
/// is safe even though the block type itself is not `Sendable`.
private struct OneShot<Argument>: @unchecked Sendable {
    let call: (Argument) -> Void
}

/// The outcome of actor-isolated resolution, in `Sendable` terms.
private enum Resolution {
    case loginRequired
    case noMatch
    case items([Candidate])
}

/// Classic-Siri handling for media playback requests (the SiriKit Media
/// domain), which is how third-party audio apps get picked up without Apple
/// Intelligence: the "play music" app picker and free-form "Play Whiplash by
/// Architects in Jelly Jams" routing both come from `INPlayMediaIntent`.
///
/// The Apple-Intelligence-only machinery lives in the App Intents audio
/// schema (``PlayAudioIntent``); this handler mirrors it for classic Siri
/// and reuses the exact same search and playback pipeline
/// (``SiriAudioSearch``, ``SiriPlayback``), so both paths stay in sync.
///
/// The Intent types are not `Sendable`, so the actor-isolated resolution
/// works on `Sendable` snapshots only and the intent-facing objects are
/// built back on the caller's side.
final class MediaIntentHandler: NSObject, INPlayMediaIntentHandling {

    // MARK: Resolution

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let mediaType = intent.mediaSearch?.mediaType
        let name = intent.mediaSearch?.mediaName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = intent.mediaSearch?.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = OneShot(call: completion)

        Task {
            switch await Self.resolve(mediaType: mediaType, name: name, artist: artist) {
            case .loginRequired:
                done.call([.unsupported(forReason: .loginRequired)])
            case .noMatch:
                done.call([])
            case .items(let candidates):
                done.call(INPlayMediaMediaItemResolutionResult.successes(with: candidates.map(\.mediaItem)))
            }
        }
    }

    /// Maps the request's ``INMediaSearch`` onto library candidates:
    /// qualified requests go straight to the matching entity query,
    /// everything else flows through the shared mixed-kind search (which
    /// handles the "Title by Artist" split). An empty result array tells
    /// Siri nothing matched; `.loginRequired` covers the signed-out state.
    @MainActor
    private static func resolve(mediaType: INMediaItemType?, name: String?, artist: String?) async -> Resolution {
        let services = AppServices.shared
        guard let client = services.session.client else {
            return .loginRequired
        }

        let candidates: [Candidate]
        do {
            candidates = try await Self.libraryCandidates(mediaType: mediaType, name: name, artist: artist, client: client)
        } catch {
            // Search infrastructure hiccup: let Siri report that nothing
            // matched rather than failing the whole interaction.
            return .noMatch
        }
        return candidates.isEmpty ? .noMatch : .items(candidates)
    }

    @MainActor
    private static func libraryCandidates(
        mediaType: INMediaItemType?,
        name: String?,
        artist: String?,
        client: JellyfinService,
        limit: Int = 6
    ) async throws -> [Candidate] {
        let found: [AudioEntity] = try await Self.found(mediaType: mediaType, name: name, artist: artist, client: client)
        return found.prefix(limit).map(\.candidate)
    }

    @MainActor
    private static func found(
        mediaType: INMediaItemType?,
        name: String?,
        artist: String?,
        client: JellyfinService
    ) async throws -> [AudioEntity] {
        switch mediaType {
        case .playlist:
            return try await PlaylistQuery().entities(matching: name ?? "").map(AudioEntity.playlist)
        case .album:
            return try await AlbumQuery().entities(matching: name ?? "").map(AudioEntity.album)
        case .artist:
            return try await ArtistQuery().entities(matching: artist ?? name ?? "").map(AudioEntity.artist)
        case .song:
            return try await SongQuery().entities(matching: Self.titleQuery(name, artist: artist)).map(AudioEntity.song)
        default:
            if let name {
                return try await SiriAudioSearch.search(matching: Self.titleQuery(name, artist: artist), client: client)
            }
            if let artist {
                return try await ArtistQuery().entities(matching: artist).map(AudioEntity.artist)
            }
            // "Play some music" with nothing named: the synthetic favourites
            // playlist, matching the audio schema's unspecified request.
            return [.playlist(FavouriteSongsPlaylist.entity())]
        }
    }

    /// Joins the search parts the way the pipeline expects them: "Title by
    /// Artist" for the split, plain title otherwise.
    private static func titleQuery(_ name: String?, artist: String?) -> String {
        switch (name, artist) {
        case let (name?, artist?): "\(name) by \(artist)"
        case let (name?, nil): name
        case let (nil, artist?): artist
        case (nil, nil): ""
        }
    }

    // MARK: Handling

    func handle(
        intent: INPlayMediaIntent,
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        let identifier = intent.mediaItems?.first?.identifier
        let done = OneShot(call: completion)
        Task {
            let code = await Self.performHandle(identifier: identifier)
            done.call(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
    }

    @MainActor
    private static func performHandle(identifier: String?) async -> INPlayMediaIntentResponseCode {
        let services = AppServices.shared
        guard let client = services.session.client else {
            // Launching the app lets the person sign in, which is the only
            // way forward from here.
            return .failureRequiringAppLaunch
        }

        do {
            let entity = try await Self.entity(identifier: identifier, client: client)
            _ = try await SiriPlayback.play(
                entity,
                shuffleRequested: false,
                queueLocation: nil,
                player: services.player,
                client: client
            )
            return .success
        } catch {
            return .failure
        }
    }

    /// Turns the resolved media item's identifier back into a full
    /// ``AudioEntity``, rehydrating from the server so playback sees a fresh
    /// item. A missing or unresolvable identifier falls back to the
    /// favourites shuffle, which covers open-ended requests that skip
    /// resolution entirely.
    @MainActor
    private static func entity(identifier: String?, client: JellyfinService) async throws -> AudioEntity {
        guard let identifier,
              identifier != FavouriteSongsPlaylist.id,
              let item = try await client.item(byId: identifier)
        else {
            return .playlist(FavouriteSongsPlaylist.entity())
        }

        let artwork = client.artworkURL(for: item, size: 600)
        if item.itemType == .audio {
            return .song(SongEntity(item: item, artworkURL: artwork))
        }
        if item.itemType == .musicAlbum {
            return .album(AlbumEntity(item: item, artworkURL: artwork))
        }
        if item.itemType == .musicArtist {
            return .artist(ArtistEntity(item: item, artworkURL: artwork))
        }
        if item.itemType == .playlist {
            return .playlist(PlaylistEntity(item: item, artworkURL: artwork))
        }
        throw SiriIntentError.itemUnavailable
    }
}

// MARK: - Conversions

private extension AudioEntity {
    /// The `Sendable` stand-in for this entity.
    var candidate: Candidate {
        switch self {
        case .song(let song):
            .init(id: song.id, title: song.title, type: .song, artworkURL: song.artworkURL)
        case .album(let album):
            .init(id: album.id, title: album.title, type: .album, artworkURL: album.artworkURL)
        case .artist(let artist):
            .init(id: artist.id, title: artist.name, type: .artist, artworkURL: artist.artworkURL)
        case .playlist(let playlist):
            .init(id: playlist.id, title: playlist.title, type: .playlist, artworkURL: playlist.artworkURL)
        }
    }
}

private extension Candidate {
    /// The SiriKit-facing stand-in, carrying the same identifier back out of
    /// the intent on handle.
    var mediaItem: INMediaItem {
        INMediaItem(identifier: id, title: title, type: type, artwork: artworkURL.flatMap { INImage(url: $0) })
    }
}
#endif
