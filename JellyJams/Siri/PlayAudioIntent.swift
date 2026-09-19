#if os(iOS)
import AppIntents
import Foundation

/// Plays a song, album, artist or playlist from the Jellyfin library.
///
/// Siri fills ``audioEntity`` by resolving the request through
/// ``AudioEntity/AudioSearchQuery``, then this intent decides what the
/// queue looks like: a single song plays alone, an album or playlist plays
/// from its first track, and an artist shuffles their whole catalogue. A
/// plain "play" request replaces whatever is currently playing.
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription(
        LocalizedStringResource(
            "Plays a song, album, artist or playlist from your Jellyfin library.",
            comment: "Description of the Play Music intent shown in the Shortcuts gallery and Siri suggestion sheets."
        ),
        categoryName: LocalizedStringResource(
            "Audio",
            comment: "Shortcuts gallery category name for Jelly Jams audio intents."
        ),
        searchKeywords: [
            LocalizedStringResource("play music", comment: "Shortcuts search keyword for the Play Music intent."),
            LocalizedStringResource("play song", comment: "Shortcuts search keyword for the Play Music intent."),
        ]
    )

    // MARK: Parameters

    // Filled by the system from the AudioSearch resolution in
    // `AudioSearchQuery`; schema intents expect this slot to be populated
    // before `perform()` runs.
    var audioEntity: AudioEntity
    @Parameter(default: [])
    var playbackAttributes: Set<PlaybackAttributes>
    var queueLocation: QueueInsertionLocation?
    var warmupAudioQueueResult: WarmupAudioQueueResult?

    // MARK: Perform

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = AppServices.shared
        guard let client = services.session.client else {
            throw AppIntentError(wrapping: SiriIntentError.notSignedIn)
        }

        _ = try await SiriPlayback.play(
            audioEntity,
            shuffleRequested: playbackAttributes.contains(.shuffle),
            queueLocation: queueLocation,
            player: services.player,
            client: client
        )

        return .result()
    }
}
#endif
