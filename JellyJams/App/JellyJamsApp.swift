import SwiftUI

@main
struct JellyJamsApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var player = PlayerController()
    @StateObject private var playerPresentation = PlayerPresentation()
    @StateObject private var playlistStore = PlaylistStore()
    @StateObject private var libraryCache = LibraryCache()
    @StateObject private var favourites = FavouriteStore()
    @StateObject private var settingsPresentation = SettingsPresentation()
    @StateObject private var preferences = PreferencesStore()

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .environmentObject(session)
                .environmentObject(player)
                .environmentObject(playerPresentation)
                .environmentObject(playlistStore)
                .environmentObject(libraryCache)
                .environmentObject(favourites)
                .environmentObject(settingsPresentation)
                .environmentObject(preferences)
                .onAppear { session.restore() }
                .frame(minWidth: 400, minHeight: 300)
        }
        .commands {
            PlaybackCommands(player: player)
            CommandGroup(replacing: .newItem) { }
            #if os(iOS)
            SettingsCommands(presentation: settingsPresentation)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(session)
                .environmentObject(preferences)
        }
        // A settings scene is fixed to its content's size by default, which
        // leaves no way to widen the window when a long server address or a
        // wrapped explanation is squeezed. `contentMinSize` keeps the minimums
        // the content asks for and hands the rest to the user.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 460, height: 420)
        #endif
    }
}
