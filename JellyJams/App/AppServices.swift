import Combine

/// Owns the process-wide service graph.
///
/// Previously the services were created by ``JellyJamsApp`` and wired together
/// from ``RootContainerView``, which only runs once UI appears. App Intents
/// (Siri) launch the app into the background with no scene, so the graph — and
/// the session restore and wiring underneath it — has to come up without any
/// UI. The scene graph adopts these exact instances through `@StateObject`, so
/// there is one of each service per process, whichever surface reaches them
/// first: a window, Settings, CarPlay, or an intent.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let session = SessionStore()
    let player = PlayerController()
    let playerPresentation = PlayerPresentation()
    let playlistStore = PlaylistStore()
    let libraryCache = LibraryCache()
    let favourites = FavouriteStore()
    let settingsPresentation = SettingsPresentation()
    let preferences = PreferencesStore()
    let downloads = DownloadStore()

    private var cancellables: Set<AnyCancellable> = []

    /// The signed-in state the graph was last wired for, so wiring re-runs on
    /// every transition but never twice for the same state.
    private var lastWiredSignedIn: Bool?

    private init() {
        // Wiring follows the signed-in state wherever it changes, including
        // sign-in and sign-out that happen with no UI on screen. The closure
        // inherits this init's MainActor isolation, and every emission arrives
        // on the main thread because SessionStore only mutates on MainActor.
        Publishers.CombineLatest(session.$client, session.$currentUser)
            .map { client, user in client != nil && user != nil }
            .removeDuplicates()
            .sink { [weak self] signedIn in
                self?.wire(signedIn: signedIn)
            }
            .store(in: &cancellables)

        // Restoring here rather than in the app's `onAppear` puts the saved
        // session in place at process start, foreground launch or background.
        session.restore()
        // The subscription above has already wired for this state when restore
        // signed someone in; this call guarantees the graph is ready the
        // moment `shared` exists even when it didn't.
        wire(signedIn: session.isSignedIn)
    }

    /// Connects the session to every service that depends on it.
    private func wire(signedIn: Bool) {
        guard lastWiredSignedIn != signedIn else { return }
        lastWiredSignedIn = signedIn

        player.configure(downloads: downloads)
        #if os(iOS)
        CarPlayController.shared.configure(session: session, player: player, downloads: downloads)
        #endif

        if signedIn {
            player.configure(client: session.client)
            downloads.configure(client: session.client)
            playlistStore.configure(client: session.client)
            favourites.configure(client: session.client)
            Task {
                await session.checkServerReachability()
                player.restorePlaybackState()
            }
        } else {
            player.clearQueue()
            player.configure(client: nil)
            downloads.configure(client: nil)
            playlistStore.configure(client: nil)
            favourites.configure(client: nil)
            libraryCache.clear()
        }
    }
}
