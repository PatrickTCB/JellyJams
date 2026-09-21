#if os(iOS)
import AppIntents

/// Registers Jelly Jams' App Shortcuts: the spoken phrases Siri listens for
/// when routing music requests to the app, and what puts Jelly Jams in the
/// list of apps Siri offers for audio playback requests.
///
/// Phrases are *examples*, not a whitelist: Siri/Apple Intelligence
/// generalise over the handful given here, so a few well-chosen examples
/// cover far more than the words on the page. The "play some music" open
/// case is deliberately parameterless and routes into the `.unspecified`
/// branch of `AudioSearchQuery` (favourite songs) rather than trying to
/// enumerate every phrasing a user might use.
///
/// ``PlayAudioIntent`` carries the schema-backed request; its `audioEntity`
/// is a `@UnionValue`, which phrases cannot interpolate, so its phrases are
/// parameterless and Siri fills the parameter from the utterance through the
/// audio schema's search resolution. The ``PlaySongIntent`` family has
/// concrete `AppEntity` parameters, which lets the phrases carry a spoken
/// placeholder ("Play my playlist Top 40 in Jelly Jams") that Siri resolves
/// through each entity's string query.
///
/// The application name token is spelled explicitly
/// (`AppShortcutPhraseToken.applicationName`) because the `\.applicationName`
/// sugar fails to type-check after a parameter interpolation on the current
/// toolchain.
struct JellyJamsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {

         // Open / generic play: "Play (some) music in Jelly Jams" with no
         // named thing -- the `.unspecified` branch of `AudioSearchQuery`
         // resolves it to the user's favourite songs.
        AppShortcut(
            intent: PlayAudioIntent(),
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
     /// are playback-stop commands, not "play" intents, so we don't want them
     /// swept in by the open-play phrase above.
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
