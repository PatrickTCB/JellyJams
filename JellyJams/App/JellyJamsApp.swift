import SwiftUI
#if os(macOS)
import Sparkle

// This view model class publishes when new updates can be checked by the user
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

// This is the view for the Check for Updates menu item
// Note this intermediate view is necessary for the disabled state on the menu item to work properly before Monterey.
// See https://stackoverflow.com/questions/68553092/menu-not-updating-swiftui-bug for more info
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
        
        // Create our view model for our CheckForUpdatesView
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }
    
    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}
#endif

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
    @StateObject private var downloads = DownloadStore()
    #if os(macOS)
    private let updaterController: SPUStandardUpdaterController
        
    init() {
        // If you want to start the updater manually, pass false to startingUpdater and call .startUpdater() later
        // This is where you can also pass an updater delegate if you need one
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
    #endif
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
                .environmentObject(downloads)
                .onAppear { session.restore() }
                .frame(minWidth: 400, minHeight: 300)
        }
        .commands {
            PlaybackCommands(player: player)
            #if os(macOS)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #endif
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
