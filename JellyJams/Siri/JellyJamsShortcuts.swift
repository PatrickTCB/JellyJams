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
/// ``PlayAudioIntent`` carries the schema-backed request and deliberately has
/// no phrases: its `audioEntity` is a `@UnionValue`, which phrases cannot
/// interpolate, so a phrase would leave the parameter unfilled and make Siri
/// ask what to play. Siri's schema routing fills it instead.
///
/// The ``PlaySongIntent`` family has concrete `AppEntity` parameters, which
/// lets the phrases carry a spoken placeholder ("Play my playlist Top 40 in
/// Jelly Jams") that Siri resolves through each entity's string query.
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
             ],
            shortTitle: "Play Music",
            systemImageName: "play.circle.fill"
         )

         // Named-item plays; the spoken placeholder binds to the entity's
        // `EntityStringQuery` through the `\(self.$x)` parameter form.
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                 "Play \(\.$song) in \(AppShortcutPhraseToken.applicationName)",
                 "Play song \(\.$song) in \(AppShortcutPhraseToken.applicationName)",
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
