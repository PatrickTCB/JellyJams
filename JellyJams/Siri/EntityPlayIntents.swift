#if os(iOS)
import AppIntents
import Foundation

/// Play intents whose parameters are concrete entities, which is what makes
/// their names usable as placeholders inside App Shortcut phrases.
///
/// App Shortcut phrases can only interpolate `AppEntity`/`AppEnum`
/// parameters — ``PlayAudioIntent``'s `audioEntity` is a `@UnionValue`, so a
/// spoken span cannot be bound to it inside a phrase. These intents pair
/// each entity kind with qualified phrases ("Play my playlist …", "Play
/// album …"), and ``PlaySongIntent``'s unqualified phrase covers bare
/// requests like "Play Whiplash by Architects in Jelly Jams". Siri resolves
/// the spoken span through each entity's string query and the intents funnel
/// into the same pipeline as ``PlayAudioIntent`` via ``SiriPlayback``.

/// Plays a single song named in the request, e.g. "Play Whiplash by
/// Architects in Jelly Jams".
struct PlaySongIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription(
        LocalizedStringResource(
            "Plays a song from your Jellyfin library.",
            comment: "Description of the Play Song intent shown in the Shortcuts gallery."
        ),
        categoryName: LocalizedStringResource(
            "Audio",
            comment: "Shortcuts gallery category name for Jelly Jams audio intents."
        ),
        searchKeywords: [
            LocalizedStringResource("play song", comment: "Shortcuts search keyword for the Play Song intent."),
        ]
    )

    @Parameter(title: "Song")
    var song: SongEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await playReplacingQueue(.song(song))
        return .result()
    }
}

/// Plays an album from its first track, e.g. "Play the album For All Kings
/// in Jelly Jams".
struct PlayAlbumIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription(
        LocalizedStringResource(
            "Plays an album from your Jellyfin library from its first track.",
            comment: "Description of the Play Album intent shown in the Shortcuts gallery."
        ),
        categoryName: LocalizedStringResource(
            "Audio",
            comment: "Shortcuts gallery category name for Jelly Jams audio intents."
        ),
        searchKeywords: [
            LocalizedStringResource("play album", comment: "Shortcuts search keyword for the Play Album intent."),
        ]
    )

    @Parameter(title: "Album")
    var album: AlbumEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await playReplacingQueue(.album(album))
        return .result()
    }
}

/// Shuffles an artist's catalogue, e.g. "Play music by Architects in Jelly
/// Jams". Only qualified phrases are offered: an unqualified "Play X in …"
/// pattern would collide with ``PlaySongIntent``'s.
struct PlayArtistIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription(
        LocalizedStringResource(
            "Shuffles an artist's catalogue from your Jellyfin library.",
            comment: "Description of the Play Artist intent shown in the Shortcuts gallery."
        ),
        categoryName: LocalizedStringResource(
            "Audio",
            comment: "Shortcuts gallery category name for Jelly Jams audio intents."
        ),
        searchKeywords: [
            LocalizedStringResource("play artist", comment: "Shortcuts search keyword for the Play Artist intent."),
        ]
    )

    @Parameter(title: "Artist")
    var artist: ArtistEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await playReplacingQueue(.artist(artist))
        return .result()
    }
}

/// Plays a playlist, e.g. "Play my playlist Top 40 in Jelly Jams".
struct PlayPlaylistIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription(
        LocalizedStringResource(
            "Plays a playlist from your Jellyfin library.",
            comment: "Description of the Play Playlist intent shown in the Shortcuts gallery."
        ),
        categoryName: LocalizedStringResource(
            "Audio",
            comment: "Shortcuts gallery category name for Jelly Jams audio intents."
        ),
        searchKeywords: [
            LocalizedStringResource("play playlist", comment: "Shortcuts search keyword for the Play Playlist intent."),
        ]
    )

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await playReplacingQueue(.playlist(playlist))
        return .result()
    }
}

// MARK: - Shared plumbing

/// Starts playback with the same semantics as ``PlayAudioIntent``: a plain
/// play request replaces whatever is currently playing. (Artists shuffle
/// their catalogue regardless — that lives in ``SiriPlayback``.)
@MainActor
private func playReplacingQueue(_ entity: AudioEntity) async throws {
    let services = AppServices.shared
    guard let client = services.session.client else {
        throw AppIntentError(wrapping: SiriIntentError.notSignedIn)
    }

    _ = try await SiriPlayback.play(
        entity,
        shuffleRequested: false,
        queueLocation: nil,
        player: services.player,
        client: client
    )
}
#endif
