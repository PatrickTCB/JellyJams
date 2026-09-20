#if os(iOS)
import AppIntents

/// Registers Jelly Jams' App Shortcuts: the spoken phrases Siri listens for
/// when routing music requests to the app, and what puts Jelly Jams in the
/// list of apps Siri offers for audio playback requests.
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
        AppShortcut(
            intent: PlayAudioIntent(),
            phrases: [
                "Play \(AppShortcutPhraseToken.applicationName)",
                "Play music in \(AppShortcutPhraseToken.applicationName)",
                "Play some music in \(AppShortcutPhraseToken.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "play.circle.fill"
        )

        AppShortcut(
            intent: SearchAndPlayIntent(),
            phrases: [
                "Search and play in \(AppShortcutPhraseToken.applicationName)",
            ],
            shortTitle: "Search and Play",
            systemImageName: "magnifyingglass"
        )

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
                "Play artist \(\.$artist) in \(AppShortcutPhraseToken.applicationName)",
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )

        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play my playlist \(\.$playlist) in \(AppShortcutPhraseToken.applicationName)",
                "Play playlist \(\.$playlist) in \(AppShortcutPhraseToken.applicationName)",
                "Play the playlist \(\.$playlist) in \(AppShortcutPhraseToken.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
    }
}
#endif
