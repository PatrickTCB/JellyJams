#if os(iOS)
import AppIntents
import Foundation

/// Plays whatever best matches a typed search.
///
/// Siri resolves spoken requests through ``AudioEntity/AudioSearchQuery``;
/// the Shortcuts editor instead deals in concrete entities. This intent puts
/// the same search-and-play pipeline behind a plain string parameter, so the
/// whole flow — the "Title by Artist" parsing, the library search, the queue
/// semantics — is drivable from a shortcut on any device.
struct SearchAndPlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Search and Play"
    static let description = IntentDescription(
        LocalizedStringResource(
            "Searches your Jellyfin library and plays the best match.",
            comment: "Description of the Search and Play intent shown in the Shortcuts gallery."
        ),
        categoryName: LocalizedStringResource(
            "Audio",
            comment: "Shortcuts gallery category name for Jelly Jams audio intents."
        ),
        searchKeywords: [
            LocalizedStringResource("search and play", comment: "Shortcuts search keyword for the Search and Play intent."),
        ]
    )

    @Parameter(title: "Search Text", requestValueDialog: "What would you like to play?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        guard let client = services.session.client else {
            throw AppIntentError(wrapping: SiriIntentError.notSignedIn)
        }

        let candidates = try await SiriAudioSearch.search(matching: query, client: client)
        guard let best = candidates.first else {
            throw AppIntentError(wrapping: SiriIntentError.noMatch(query))
        }

        let nowPlaying = try await SiriPlayback.play(
            best,
            shuffleRequested: query.localizedCaseInsensitiveContains("shuffle"),
            queueLocation: nil,
            player: services.player,
            client: client
        )
        return .result(dialog: "Now playing \(nowPlaying) in Jelly Jams")
    }
}
#endif
