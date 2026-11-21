#if os(iOS)
import AppIntents
import Foundation

/// Plays the song a remembered lyric line belongs to — "Play the song
/// that goes 'when the rush kicks in I must get out' using Jelly Jams" —
/// by sending the line to the Jelly Jams Backend's lyric search and
/// playing its best match.
///
/// This is the explicit face of `/lyric-search`, the way
/// ``PlayDescribedMusicIntent`` is the explicit face of `/text-to-tunes`:
/// the spoken line goes straight to the backend with no library search
/// first. Only the best match plays: a remembered line names one song,
/// not a queue — the search screen's Lyric Matches section is the other
/// face of the same endpoint, and it shows a handful instead. Both run
/// ``LyricSearch``; a plain play request replaces whatever is currently
/// playing.
///
/// The backend is optional, and the request needs it: with none configured
/// the intent refuses with ``SiriIntentError/backendUnavailable``, pointing
/// at the settings — exactly like Text to Tunes, and for the same reason:
/// App Shortcut phrases are build-time metadata, the shortcut builder
/// rejects any runtime condition that is not `#available`, and
/// `isDiscoverable` is exported as a compile-time constant from a context
/// that cannot read the app's state. So the shortcut exists on installs
/// without a backend and says so clearly rather than hiding.
struct PlayLyricMatchIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Lyric Match"
    static let description = IntentDescription(
        LocalizedStringResource(
            "Plays the song whose lyrics match a line you remember, with the Jelly Jams Backend.",
            comment: "Description of the lyric match intent shown in the Shortcuts gallery and Siri suggestion sheets."
        ),
        categoryName: LocalizedStringResource(
            "Audio",
            comment: "Shortcuts gallery category name for Jelly Jams audio intents."
        ),
        searchKeywords: [
            LocalizedStringResource("play lyric match", comment: "Shortcuts search keyword for the lyric match intent."),
            LocalizedStringResource("song that goes", comment: "Shortcuts search keyword for the lyric match intent."),
            LocalizedStringResource("play song by lyrics", comment: "Shortcuts search keyword for the lyric match intent."),
        ]
    )

    // MARK: Parameters

    /// The remembered line. No default: a phrase with no words is not a
    /// request, and Siri asks for the line instead. The free-text vessel
    /// is the one Text to Tunes uses — spoken words need an entity to
    /// arrive in, and this one echoes whatever it is handed, so no line
    /// can fail to resolve.
    @Parameter(title: "Lyric Line")
    var lyrics: MusicDescriptionEntity

    // MARK: Perform

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = AppServices.shared
        guard let client = services.session.client else {
            throw AppIntentError(wrapping: SiriIntentError.notSignedIn)
        }
        let phrase = lyrics.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            throw AppIntentError(wrapping: SiriIntentError.noMatch(lyrics.id))
        }
        guard let destination = BackendDestination.current() else {
            // Signed in to Jellyfin but no backend address — the feature
            // this request is for does not exist on this install.
            throw AppIntentError(wrapping: SiriIntentError.backendUnavailable)
        }

        do {
            let matches = try await LyricSearch.tracks(
                query: phrase,
                limit: LyricSearch.bestMatchLimit,
                destination: destination,
                client: client
            )
            guard let best = matches.first else {
                throw AppIntentError(wrapping: SiriIntentError.noMatch(phrase))
            }
            services.player.play([best])
        } catch {
            // Whatever went wrong at either end, the listener hears that
            // this line found no song — which is the truth of it.
            throw AppIntentError(wrapping: SiriIntentError.noMatch(phrase))
        }

        return .result()
    }
}
#endif
