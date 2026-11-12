#if os(iOS)
import AppIntents

/// Registers Jelly Jams' App Shortcuts: the spoken phrases Siri listens for
/// when playing a named item, and what puts Jelly Jams in the list of apps
/// Siri offers for audio playback requests.
///
/// Phrases are *examples*, not a whitelist: Siri/Apple Intelligence
/// generalise over the handful given here, so a few well-chosen examples
/// cover far more than the words on the page.
///
/// Open-ended requests like "Play some music in Jelly Jams" bind to
/// ``PlayDefaultMusicIntent``, which takes no parameters and starts the
/// user's default playback immediately on every device — including ones
/// without Apple Intelligence, where the audio schema's free-form routing
/// isn't available.
///
/// Free-text descriptions of music — nothing the library is asked to name —
/// bind to ``PlayDescribedMusicIntent``, the explicit route to the backend's
/// Text to Tunes. The same pipeline also answers schema and classic-Siri
/// requests the library cannot match, through the ``TextToTunesPlaylist``
/// fallback.
///
/// ``PlayAudioIntent`` carries the schema-backed request and deliberately has
/// no phrases: its `audioEntity` is a `@UnionValue`, which phrases cannot
/// interpolate, so a phrase would leave the parameter unfilled and make Siri
/// ask what to play. Siri's schema routing fills it instead.
///
/// The ``PlaySongIntent`` family has concrete `AppEntity` parameters, which
/// lets the phrases carry a spoken placeholder ("Play my playlist Top 40 in
/// Jelly Jams"). A placeholder matches only the values the entity's
/// `suggestedEntities()` offered when the system last fetched them, so
/// ``AppServices`` calls `updateAppShortcutParameters()` whenever someone
/// signs in.
///
/// The application name token is spelled explicitly
/// (`AppShortcutPhraseToken.applicationName`) because the `\.applicationName`
/// sugar fails to type-check after a parameter interpolation on the current
/// toolchain.
struct JellyJamsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {

         // Open / generic play with nothing named: parameterless, so the
         // phrase runs straight into the default playback resolution.
        AppShortcut(
            intent: PlayDefaultMusicIntent(),
            phrases: [
                 "Play music in \(AppShortcutPhraseToken.applicationName)",
                 "Play some music in \(AppShortcutPhraseToken.applicationName)",
                 "Rock some jams in \(AppShortcutPhraseToken.applicationName)",
                 "Play some tunes using \(AppShortcutPhraseToken.applicationName)",
             ],
            shortTitle: "Play Music",
            systemImageName: "play.circle.fill"
         )

         // Open-ended Text to Tunes: a free-text description goes to the
         // backend rather than the library, so the placeholder takes any
         // spoken words — the one play phrase here is not anchored to a
         // named item. `MusicDescriptionEntity` echoes what it is handed,
         // which is what lets the phrase interpolate open-ended text.
         // Phrases are build-time metadata that cannot be conditioned on a
         // configured backend — the intent itself is what refuses without
         // one, see ``PlayDescribedMusicIntent``.
        AppShortcut(
            intent: PlayDescribedMusicIntent(),
            phrases: [
                 "Play music that sounds like \(\.$description) in \(AppShortcutPhraseToken.applicationName)",
                 "Play some \(\.$description) music in \(AppShortcutPhraseToken.applicationName)",
                 "Get me some \(\.$description) tunes using \(AppShortcutPhraseToken.applicationName)",
             ],
            shortTitle: "Text to Tunes",
            systemImageName: "sparkles"
         )

         // Named-item plays; the spoken placeholder binds to the entity's
        // `EntityStringQuery` through the `\(self.$x)` parameter form.
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                 "Play \(\.$song) in \(AppShortcutPhraseToken.applicationName)",
                 "Play song \(\.$song) in \(AppShortcutPhraseToken.applicationName)",
                 "Play the song \(\.$song) in \(AppShortcutPhraseToken.applicationName)",
             ],
            shortTitle: "Play Song",
            systemImageName: "music.note"
         )

        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                 "Play album \(\.$album) in \(AppShortcutPhraseToken.applicationName)",
                 "Play the album \(\.$album) in \(AppShortcutPhraseToken.applicationName)",
             ],
            shortTitle: "Play Album",
            systemImageName: "music.note.square.stack"
         )

        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                 "Play music by \(\.$artist) in \(AppShortcutPhraseToken.applicationName)",
                 "Play songs by \(\.$artist) in \(AppShortcutPhraseToken.applicationName)",
             ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
         )

        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                 "Play my playlist \(\.$playlist) in \(AppShortcutPhraseToken.applicationName)",
                 "Play my \(\.$playlist) playlist in \(AppShortcutPhraseToken.applicationName)",
                 "Play playlist \(\.$playlist) in \(AppShortcutPhraseToken.applicationName)",
             ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
         )
     }

     /// Phrases that must never trigger a Jelly Jams shortcut. "stop"/"pause"
     /// are playback-stop commands, not "play" intents, so the play phrases
     /// above shouldn't sweep them in.
     ///
     /// Constructed on demand as a computed `static var`, exactly like
     /// `appShortcuts`, rather than a stored `static let`/`var`: a stored
     /// global of the non-`Sendable` `NegativeAppShortcutPhrases` would be
     /// rejected as a non-isolated shared-mutable-state global under Swift 6.
     static var negativePhrases: NegativeAppShortcutPhrases {
          NegativeAppShortcutPhrases(phrases: [
               "Stop playing",
               "Stop Jelly Jams",
               "Stop",
               "Pause",
           ])
      }
}
#endif
