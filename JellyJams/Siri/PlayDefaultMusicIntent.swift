#if os(iOS)
import AppIntents
import Foundation

/// Starts the user's configured default playback for open-ended requests like
/// "Play some music in Jelly Jams".
///
/// This intent exists because ``PlayAudioIntent`` cannot answer a
/// parameterless phrase: its `audioEntity` is a `@UnionValue` that App
/// Shortcut phrases cannot interpolate, so Siri stops and asks what to play
/// instead of running the request. A dedicated parameterless intent lets the
/// phrase go straight into playback on every device, including ones without
/// Apple Intelligence, where the audio schema's free-form routing isn't
/// available.
struct PlayDefaultMusicIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription(
        LocalizedStringResource(
            "Starts playback with your default playback item.",
            comment: "Description of the open-ended Play Music intent shown in the Shortcuts gallery."
        ),
        categoryName: LocalizedStringResource(
            "Audio",
            comment: "Shortcuts gallery category name for Jelly Jams audio intents."
        ),
        searchKeywords: [
            LocalizedStringResource("play music", comment: "Shortcuts search keyword for the open-ended Play Music intent."),
        ]
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = AppServices.shared
        guard let client = services.session.client else {
            throw AppIntentError(wrapping: SiriIntentError.notSignedIn)
        }

        // The sentinel makes `SiriPlayback` read the setting itself, so the
        // same default-playback resolution serves Siri and the system play
        // button.
        _ = try await SiriPlayback.play(
            .playlist(DefaultPlaybackPlaylist.entity(setting: services.preferences.defaultPlayback)),
            shuffleRequested: false,
            queueLocation: nil,
            player: services.player,
            client: client
        )

        return .result()
    }
}
#endif