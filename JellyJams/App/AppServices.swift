import Combine
import Dispatch

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
    let pinnedItems = PinnedItemsStore()
    let networkStatus = NetworkStatus()

    private var cancellables: Set<AnyCancellable> = []

    /// The signed-in state the graph was last wired for, so wiring re-runs on
    /// every transition but never twice for the same state.
    private var lastWiredSignedIn: Bool?

    private init() {
        // Wiring follows the signed-in state wherever it changes, including
        // sign-in and sign-out that happen with no UI on screen. The closure
        // inherits this init's MainActor isolation, and every emission arrives
        // on the main thread because SessionStore only mutates on MainActor.
        //
        // `wire` receives the session values from the publisher rather than
        // reading them back off `session`: `@Published` publishes from
        // `willSet`, so inside this sink a property read can still return the
        // old value — and reading `session.currentUser` during the emission
        // that announces it returns nil, which wired `PinnedItemsStore` to no
        // account: persisted pins never loaded, and new ones never saved.
        Publishers.CombineLatest(session.$client, session.$currentUser)
            .sink { [weak self] client, user in
                self?.wire(client: client, user: user)
            }
            .store(in: &cancellables)

        // Server reachability follows the network: a LAN-only server appears
        // and disappears as the device's connectivity changes, so every path
        // update re-pings — including transitions that keep the device
        // online, like moving from home Wi-Fi to cellular. (The
        // subscription's synchronous initial value is skipped — `wire`
        // already checked once at process start — and the burst of updates a
        // transition emits is coalesced into a single ping.)
        networkStatus.$isOnline
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, session.isSignedIn else { return }
                Task { await session.checkServerReachability() }
            }
            .store(in: &cancellables)

        // Restoring here rather than in the app's `onAppear` puts the saved
        // session in place at process start, foreground launch or background.
        session.restore()
        // The subscription above has already wired for this state when restore
        // signed someone in; this call guarantees the graph is ready the
        // moment `shared` exists even when it didn't.
        wire(client: session.client, user: session.currentUser)
    }

    /// Connects the session to every service that depends on it. Takes the
    /// values to wire for rather than reading them off `session`, which during
    /// a `@Published` emission still holds the old value; the signed-in state
    /// is just that both halves are present.
    private func wire(client: JellyfinService?, user: SessionStore.StoredUser?) {
        let signedIn = client != nil && user != nil
        guard lastWiredSignedIn != signedIn else { return }
        lastWiredSignedIn = signedIn

        player.configure(downloads: downloads)
        player.configure(preferences: preferences)
        #if os(iOS)
        CarPlayController.shared.configure(session: session, player: player, downloads: downloads)
        #endif

        if signedIn {
            player.configure(client: client)
            downloads.configure(client: client)
            playlistStore.configure(client: client)
            favourites.configure(client: client)
            pinnedItems.configure(accountKey: user.map(Self.accountKey(for:)))
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
            pinnedItems.configure(accountKey: nil)
            libraryCache.clear()
        }
    }

    /// The key a set of pins is stored under: item ids belong to one server,
    /// so pins are kept apart per account rather than shared across sign-ins.
    private static func accountKey(for user: SessionStore.StoredUser) -> String {
        "\(user.serverURL.absoluteString)#\(user.id)"
    }
}
