#if os(iOS) || os(tvOS)
import Foundation
import Intents

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
    case items([SiriCandidate])
}

/// The outcome of a one-shot spoken request, for the surfaces that answer
/// the request themselves rather than through Siri's own dialogs.
enum SiriRequestOutcome: Sendable, Equatable {
    case success
    case failure(String)
}

/// Classic-Siri handling for media playback requests (the SiriKit Media
/// domain), which is how third-party audio apps get picked up without Apple
/// Intelligence: the "play music" app picker and free-form "Play Whiplash by
/// Architects in Jelly Jams" routing both come from `INPlayMediaIntent`.
///
/// On iOS the app handles these in-app (see ``AppDelegate``); the
/// Apple-Intelligence-only machinery lives in the App Intents audio schema
/// (``PlayAudioIntent``). On tvOS neither exists — in-app intent handling is
/// iOS-only and the audio schema is unavailable there — so a lightweight
/// Intents extension (the JellyJamsSiri target) resolves a pass-through item
/// and hands the request to the app as a user activity, which arrives at
/// ``play(_:)`` below. All paths reuse the exact same search and playback
/// pipeline (``SiriAudioSearch``, ``SiriPlayback``), so they stay in sync.
///
/// The Intent types are not `Sendable`, so the actor-isolated resolution
/// works on `Sendable` snapshots only and the intent-facing objects are
/// built back on the caller's side.
final class MediaIntentHandler: NSObject, INPlayMediaIntentHandling {

    // MARK: One-shot requests (tvOS)

    /// Answers a whole spoken request in one call: resolve it against the
    /// library, then play the best match. This is the tvOS entry point —
    /// the extension foregrounds the app with the request and the app does
    /// the work in its own process, where the session and player live.
    ///
    /// A request carrying a real library identifier (a donated interaction,
    /// say) plays it directly; the extension's pass-through identifiers and
    /// search-bearing requests resolve fresh.
    @MainActor
    static func play(_ request: SiriMediaRequest) async -> SiriRequestOutcome {
        if let identifier = request.concreteIdentifier {
            return await outcome(of: performHandle(identifier: identifier))
        }
        switch await resolve(mediaType: request.mediaType, name: request.name, artist: request.artist) {
        case .loginRequired:
            return .failure(Self.message(for: .notSignedIn))
        case .noMatch:
            return .failure(Self.message(for: .noMatch(request.name ?? request.artist ?? "")))
        case .items(let candidates):
            return await outcome(of: performHandle(identifier: candidates.first?.id))
        }
    }

    @MainActor
    private static func outcome(of code: INPlayMediaIntentResponseCode) -> SiriRequestOutcome {
        switch code {
        case .success:
            return .success
        case .failureRequiringAppLaunch:
            return .failure(message(for: .notSignedIn))
        default:
            return .failure(message(for: .itemUnavailable))
        }
    }

    private static func message(for error: SiriIntentError) -> String {
        String(localized: error.localizedStringResource)
    }

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
    /// qualified requests go straight to the matching kind's search,
    /// everything else flows through the shared mixed-kind search (which
    /// handles the "Title by Artist" split). An empty result array tells
    /// Siri nothing matched; `.loginRequired` covers the signed-out state.
    @MainActor
    private static func resolve(mediaType: INMediaItemType?, name: String?, artist: String?) async -> Resolution {
        let services = AppServices.shared
        guard let client = services.session.client else {
            return .loginRequired
        }

        let candidates: [SiriCandidate]
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
    ) async throws -> [SiriCandidate] {
        let found = try await Self.found(mediaType: mediaType, name: name, artist: artist, client: client)
        return Array(found.prefix(limit))
    }

    @MainActor
    private static func found(
        mediaType: INMediaItemType?,
        name: String?,
        artist: String?,
        client: JellyfinService
    ) async throws -> [SiriCandidate] {
        // A remembered lyric line ("that goes …", "with the lyrics …") is
        // not a name: the markers ride along when Siri binds the request
        // to a play template, and only the backend's lyric search can
        // answer them — so they go straight to the lyric sentinel, ahead
        // of any library search.
        let lyricLine = name.flatMap(LyricMatchPlaylist.phrase(in:))
        switch mediaType {
        case .playlist:
            var found = try await SiriAudioSearch.search(kind: .playlist, matching: name ?? "", client: client)
            // "Play my favourites" names the synthetic playlist rather than
            // a server one — the same nicety the playlist picker offers.
            let phrase = name ?? ""
            if phrase.localizedCaseInsensitiveContains("favourite") || phrase.localizedCaseInsensitiveContains("favorite") {
                found.insert(FavouriteSongsPlaylist.candidate(), at: 0)
            }
            return found
        case .album:
            return try await SiriAudioSearch.search(kind: .album, matching: name ?? "", client: client)
        case .artist:
            return try await SiriAudioSearch.search(kind: .artist, matching: artist ?? name ?? "", client: client)
        case .song:
            if let lyricLine, let fallback = LyricMatchPlaylist.fallbackCandidate(for: lyricLine) {
                return [fallback]
            }
            return try await SiriAudioSearch.search(kind: .song, matching: Self.titleQuery(name, artist: artist), client: client)
        default:
            if let name {
                if let lyricLine, let fallback = LyricMatchPlaylist.fallbackCandidate(for: lyricLine) {
                    return [fallback]
                }
                let phrase = Self.titleQuery(name, artist: artist)
                let found = try await SiriAudioSearch.search(matching: phrase, client: client)
                if found.isEmpty, let fallback = TextToTunesPlaylist.fallbackCandidate(for: phrase) {
                    // The library has nothing for these free-form words, so
                    // they read as a description rather than a name — the
                    // Text to Tunes sentinel takes them to the backend. A
                    // request qualified by media type is a named item, and
                    // a miss there stays a miss.
                    return [fallback]
                }
                return found
            }
            if let artist {
                return try await SiriAudioSearch.search(kind: .artist, matching: artist, client: client)
            }
            // "Play some music" with nothing named: the default-playback
            // sentinel, matching the audio schema's unspecified request.
            let setting = AppServices.shared.preferences.defaultPlayback
            return [DefaultPlaybackPlaylist.candidate(setting: setting)]
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
            let candidate = try await Self.candidate(identifier: identifier, client: client)
            _ = try await SiriPlayback.play(
                candidate,
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

    /// Turns a resolved identifier back into a full ``SiriCandidate``,
    /// rehydrating from the server so playback sees a fresh item. The
    /// synthetic items pass through untouched — ``SiriPlayback`` applies
    /// the user's setting when it sees the default id, decodes the phrase
    /// when it sees the Text to Tunes prefix, and decodes the lyric line
    /// when it sees the lyric-match prefix. A missing or unresolvable
    /// identifier falls back to the favourites shuffle, which covers
    /// open-ended requests that skip resolution entirely.
    @MainActor
    private static func candidate(identifier: String?, client: JellyfinService) async throws -> SiriCandidate {
        if identifier == DefaultPlaybackPlaylist.id {
            return DefaultPlaybackPlaylist.candidate(setting: AppServices.shared.preferences.defaultPlayback)
        }
        if let identifier, let phrase = TextToTunesPlaylist.query(in: identifier) {
            return TextToTunesPlaylist.candidate(query: phrase)
        }
        if let identifier, let phrase = LyricMatchPlaylist.query(in: identifier) {
            return LyricMatchPlaylist.candidate(query: phrase)
        }
        guard let identifier,
              identifier != FavouriteSongsPlaylist.id,
              let item = try await client.item(byId: identifier)
        else {
            return FavouriteSongsPlaylist.candidate()
        }

        let artwork = client.artworkURL(for: item, size: 600)
        if item.itemType == .audio {
            return SiriCandidate(item: item, kind: .song, artworkURL: artwork)
        }
        if item.itemType == .musicAlbum {
            return SiriCandidate(item: item, kind: .album, artworkURL: artwork)
        }
        if item.itemType == .musicArtist {
            return SiriCandidate(item: item, kind: .artist, artworkURL: artwork)
        }
        if item.itemType == .playlist {
            return SiriCandidate(item: item, kind: .playlist, artworkURL: artwork)
        }
        throw SiriIntentError.itemUnavailable
    }
}

// MARK: - Authorization

extension MediaIntentHandler {
    /// Asks for Siri permission the first time it is needed. Classic Siri
    /// routes every request through this handler, and SiriKit won't use the
    /// app at all until the person has allowed it — so without the prompt,
    /// "Play Night Is Calling in Jelly Jams" quietly goes elsewhere on devices
    /// without Apple Intelligence. A no-op once the person has answered.
    @MainActor
    static func requestAuthorizationIfNeeded() {
        guard INPreferences.siriAuthorizationStatus() == .notDetermined else { return }
        INPreferences.requestSiriAuthorization { _ in }
    }
}

// MARK: - Conversions

extension SiriCandidate {
    /// The SiriKit-facing stand-in, carrying the same identifier back out of
    /// the intent on handle.
    var mediaItem: INMediaItem {
        INMediaItem(
            identifier: id,
            title: title,
            type: kind.mediaItemType,
            artwork: artworkURL.flatMap { INImage(url: $0) }
        )
    }
}

private extension SiriCandidate.Kind {
    var mediaItemType: INMediaItemType {
        switch self {
        case .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        }
    }
}
#endif
