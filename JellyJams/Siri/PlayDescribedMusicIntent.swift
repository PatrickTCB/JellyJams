#if os(iOS)
import AppIntents
import Foundation
import SwiftUI

/// A free-text description of music, shaped like an entity.
///
/// App Shortcut phrases can only interpolate `AppEntity`/`AppEnum`
/// parameters — a `String` slot in a phrase is rejected outright by the
/// metadata exporter ("AppEntity and AppEnum are the only allowed types")
/// — so the words a listener speaks about *what they want to hear* need a
/// type to arrive in. This is the thinnest one that works: the text is the
/// id, and every query hands back whatever it is given, so no phrase span
/// and no typed description can fail to resolve. Unlike the library
/// entities, this one suggests nothing: it is a vessel for words, not a
/// picker of items. (Conformances spelled out rather than `@AppEntity` —
/// that macro only takes a schema on this SDK.)
struct MusicDescriptionEntity: AppEntity, Transferable, Codable {
    // Computed rather than stored: a stored global of these types is
    // non-`Sendable` shared mutable state under Swift 6, exactly like the
    // `negativePhrases` note in ``JellyJamsShortcuts`` describes.
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "music description" }
    static var defaultQuery: MusicDescriptionQuery { MusicDescriptionQuery() }

    /// The description itself — the entity is nothing but its words.
    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

struct MusicDescriptionQuery {}

extension MusicDescriptionQuery: EntityQuery {
    func entities(for identifiers: [MusicDescriptionEntity.ID]) async throws -> [MusicDescriptionEntity] {
        identifiers.map(MusicDescriptionEntity.init(id:))
    }

    func suggestedEntities() async throws -> [MusicDescriptionEntity] { [] }
}

extension MusicDescriptionQuery: EntityStringQuery {
    /// The free-form contract: whatever was spoken or typed becomes the
    /// entity, so a phrase placeholder can match open-ended text.
    func entities(matching string: String) async throws -> [MusicDescriptionEntity] {
        [MusicDescriptionEntity(id: string)]
    }
}

/// Plays music described in free text — "high energy rock", "up tempo folk
/// about Canada" — by sending the description to the Jelly Jams Backend's
/// Text to Tunes and playing the picks, exactly like the Home screen's
/// sparkles button.
///
/// This is the explicit face of `/text-to-tunes`: a spoken or Shortcuts-
/// supplied description goes straight to the backend with no library search
/// first. The implicit face is the fallback in ``TextToTunesPlaylist``,
/// which reaches the same pipeline when the library cannot answer a
/// free-form request. Both run ``TextToTunes``; a plain play request
/// replaces whatever is currently playing.
///
/// The backend is optional, and the request needs it: with none configured
/// the intent refuses with ``SiriIntentError/backendUnavailable``, pointing
/// at the settings. The refusal — not hiding the intent — is the only lever
/// the SDK gives: App Shortcut phrases are build-time metadata, the shortcut
/// builder rejects any runtime condition that is not `#available`, and
/// `isDiscoverable` is exported as a compile-time constant from a context
/// that cannot read the app's state. So the shortcut exists on installs
/// without a backend, says so clearly, and means nothing on ones that have
/// one; the automatic fallback never offers itself unless the backend is
/// configured, because resolving it consults that before presenting it.
struct PlayDescribedMusicIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Described Music"
    static let description = IntentDescription(
        LocalizedStringResource(
            "Turns a description of the music you want to hear into a queue of songs, with the Jelly Jams Backend.",
            comment: "Description of the Text to Tunes intent shown in the Shortcuts gallery and Siri suggestion sheets."
        ),
        categoryName: LocalizedStringResource(
            "Audio",
            comment: "Shortcuts gallery category name for Jelly Jams audio intents."
        ),
        searchKeywords: [
            LocalizedStringResource("play described music", comment: "Shortcuts search keyword for the Text to Tunes intent."),
            LocalizedStringResource("text to tunes", comment: "Shortcuts search keyword for the Text to Tunes intent."),
        ]
    )

    // MARK: Parameters

    /// What to ask the backend for. No default: a phrase with nothing
    /// described is not a request, and Siri asks for the words instead.
    @Parameter(title: "Description")
    var description: MusicDescriptionEntity

    /// A compile-time literal stands in for ``TextToTunes/defaultSongLimit``:
    /// the `@Parameter` macro wants one, and the two must stay agreeing.
    @Parameter(title: "Maximum Song Count", default: 30)
    var songCount: Int

    // MARK: Perform

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = AppServices.shared
        guard let client = services.session.client else {
            throw AppIntentError(wrapping: SiriIntentError.notSignedIn)
        }
        let phrase = description.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, songCount >= 1 else {
            throw AppIntentError(wrapping: SiriIntentError.noMatch(description.id))
        }
        guard let destination = TextToTunes.currentDestination() else {
            // Signed in to Jellyfin but no backend address — the feature
            // this request is for does not exist on this install.
            throw AppIntentError(wrapping: SiriIntentError.backendUnavailable)
        }

        do {
            let tracks = try await TextToTunes.tracks(
                description: phrase,
                limit: songCount,
                destination: destination,
                client: client
            )
            services.player.play(tracks)
        } catch {
            // Whatever went wrong at either end, the listener hears that
            // these words found no music — which is the truth of it.
            throw AppIntentError(wrapping: SiriIntentError.noMatch(phrase))
        }

        return .result()
    }
}
#endif
