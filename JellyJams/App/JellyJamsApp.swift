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
// Note: the intermediate view was necessary for the disabled state on the menu
// item to update on pre-Monterey systems — long before this app's deployment
// target — and is kept because Sparkle's own sample ships it this way.
// See https://stackoverflow.com/questions/68553092/menu-not-updating-swiftui-bug for more info
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
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
    #if os(iOS)
    // Routes classic-Siri (SiriKit Media) intents to their in-app handlers.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    // The service graph belongs to ``AppServices``, the process-wide owner,
    // so a background launch that never creates a scene — an App Intent —
    // still shares this exact graph. The scenes hand those same instances to
    // the environment; the app itself only holds on to their owner.
    private let services: AppServices
    #if os(macOS)
    private let updaterController: SPUStandardUpdaterController
    #endif

    init() {
        // Referencing `shared` here forces the service graph, its session
        // restore and its wiring to run at process start, even when no scene
        // ever appears.
        services = AppServices.shared
        #if os(macOS)
        // Don't start the updater during test runs: its scheduled checks and
        // installer services have no place in a test host.
        let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        updaterController = SPUStandardUpdaterController(startingUpdater: !runningTests, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .environment(services.session)
                .environment(services.player)
                .environment(services.player.clock)
                .environment(services.playerPresentation)
                .environment(services.playlistStore)
                .environment(services.libraryCache)
                .environment(services.favourites)
                .environment(services.bans)
                .environment(services.settingsPresentation)
                .environment(services.preferences)
                .environment(services.downloads)
                .environment(services.pinnedItems)
                .environment(services.networkStatus)
                .frame(minWidth: 400, minHeight: 300)
        }
        .commands {
            PlaybackCommands(player: services.player)
            #if os(macOS)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #endif
            CommandGroup(replacing: .newItem) { }
            #if os(iOS)
            SettingsCommands(presentation: services.settingsPresentation)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif

        #if os(macOS)
        Settings {
            // The backend settings sheet browses — the bans screen opens
            // real album and artist pages, whose rows reach every store a
            // library screen uses — so the settings scene carries the same
            // service graph as the main window rather than the handful the
            // settings forms once needed alone.
            SettingsView()
                .environment(services.session)
                .environment(services.preferences)
                .environment(services.downloads)
                .environment(services.player)
                .environment(services.player.clock)
                .environment(services.playerPresentation)
                .environment(services.playlistStore)
                .environment(services.libraryCache)
                .environment(services.favourites)
                .environment(services.bans)
                .environment(services.pinnedItems)
                .environment(services.networkStatus)
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
