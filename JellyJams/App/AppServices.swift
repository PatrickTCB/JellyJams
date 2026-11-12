import Foundation
import Observation
#if os(iOS)
import AppIntents
#endif

/// Owns the process-wide service graph.
///
/// Previously the services were created by ``JellyJamsApp`` and wired together
/// from ``RootContainerView``, which only runs once UI appears. App Intents
/// (Siri) launch the app into the background with no scene, so the graph — and
/// the session restore and wiring underneath it — has to come up without any
/// UI. The scenes hand these exact instances to the environment, so there is
/// one of each service per process, whichever surface reaches them first: a
/// window, Settings, CarPlay, or an intent.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let session = SessionStore()
    let player = PlayerController()
    let playerPresentation = PlayerPresentation()
    let playlistStore = PlaylistStore()
    let libraryCache = LibraryCache()
    let favourites = FavouriteStore()
    let bans = BanStore()
    let queueExtender = QueueExtender()
    let settingsPresentation = SettingsPresentation()
    let preferences = PreferencesStore()
    let downloads = DownloadStore()
    let pinnedItems = PinnedItemsStore()
    let networkStatus = NetworkStatus()

    /// The signed-in state the graph was last wired for, so wiring re-runs on
    /// every transition but never twice for the same state.
    private var lastWiredSignedIn: Bool?

    private init() {
        // Wiring follows the signed-in state wherever it changes, including
        // sign-in and sign-out that happen with no UI on screen. A change
        // arrives once it has landed — a sign-in's client and user together —
        // and the observation, like the graph, lasts as long as the process.
        Task { [weak self, session] in
            for await (client, user) in Observations({ (session.client, session.currentUser) }) {
                self?.wire(client: client, user: user)
            }
        }

        // Server reachability follows the network: a LAN-only server appears
        // and disappears as the device's connectivity changes, so every path
        // update re-pings — including transitions that keep the device
        // online, like moving from home Wi-Fi to cellular, which is why this
        // counts path updates rather than watching `isOnline`. (The value
        // observation starts from is skipped — `wire` already checked once at
        // process start — and the burst of updates a transition emits is
        // coalesced into a single ping, a second after the last of them.)
        Task { [weak self, networkStatus] in
            var pendingPing: Task<Void, Never>?
            for await _ in Observations({ networkStatus.pathUpdateCount }).dropFirst() {
                pendingPing?.cancel()
                pendingPing = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let session = self?.session, session.isSignedIn else { return }
                    // A task of its own, so a later update cancels only the
                    // wait above, never a ping already under way: a cancelled
                    // ping comes back as the server being unreachable.
                    Task { await session.checkServerReachability() }
                }
            }
        }

        // Bans and Infinite Queue follow the backend rather than the session
        // alone: whether a "Ban" menu may offer itself — and whether a
        // running queue can be extended — depends on who is signed in, where
        // the backend lives, and whether it knows this account yet. The
        // closure names what ``configureBackend()`` depends on; a
        // registration records its address and suffix together, so they
        // arrive as the one change they are.
        Task { [weak self, session, preferences] in
            let backendSettings = Observations {
                (session.currentUser?.id, preferences.jellyJamsBackendAddress, preferences.isMixtapesActive)
            }
            for await _ in backendSettings {
                self?.configureBackend()
            }
        }

        // Restoring here rather than in the app's `onAppear` puts the saved
        // session in place at process start, foreground launch or background.
        session.restore()
        // The observations above deliver their first values only once this
        // init has returned; wiring and configuring now guarantees the graph
        // is ready the moment `shared` exists.
        wire(client: session.client, user: session.currentUser)
        configureBackend()
    }

    /// Points the backend clients at the backend as the session and settings
    /// now describe it. `registered` is the rule
    /// ``PreferencesStore/isMixtapesActive`` reads: a registration recorded a
    /// playlist-name ending.
    private func configureBackend() {
        let userID = session.currentUser?.id
        let address = preferences.jellyJamsBackendAddress
        let registered = preferences.isMixtapesActive
        bans.configure(
            userID: userID,
            address: address,
            registered: registered,
            deviceInfo: session.deviceInfo
        )
        queueExtender.configure(
            userID: userID,
            address: address,
            registered: registered,
            deviceInfo: session.deviceInfo
        )
    }

    /// Connects the session to every service that depends on it, for the
    /// client and user it is handed; the signed-in state is just that both
    /// halves are present.
    ///
    /// A transition *from* signed-in is a sign-out — the settings button's or
    /// the account menu's — as distinct from launching with nobody signed in,
    /// which the first wiring at process start also is. Only the real thing
    /// runs ``forgetEverything()``: the launch wiring must find the stored
    /// state standing, or every relaunch would be a reset.
    private func wire(client: JellyfinService?, user: SessionStore.StoredUser?) {
        let signedIn = client != nil && user != nil
        guard lastWiredSignedIn != signedIn else { return }
        let isSigningOut = lastWiredSignedIn == true && !signedIn
        lastWiredSignedIn = signedIn

        player.configure(downloads: downloads)
        player.configure(preferences: preferences)
        player.configure(queueExtender: queueExtender)
        #if os(iOS)
        CarPlayController.shared.configure(session: session, player: player, downloads: downloads, pinnedItems: pinnedItems)
        #endif

        if signedIn {
            player.configure(client: client)
            player.configure(favourites: favourites)
            downloads.configure(client: client)
            playlistStore.configure(client: client)
            favourites.configure(client: client)
            pinnedItems.configure(accountKey: user.map(Self.accountKey(for:)))
            #if os(iOS)
            // A phrase like "Play <song> in Jelly Jams" can only match the
            // values the entity queries suggested when the system last asked
            // — and while signed out they suggest nothing. Ask it to fetch
            // them again now there is a library to suggest from.
            JellyJamsShortcuts.updateAppShortcutParameters()
            #endif
            Task {
                await session.checkServerReachability()
                player.restorePlaybackState()
            }
        } else {
            player.clearQueue()
            if isSigningOut {
                forgetEverything()
            }
            player.configure(client: nil)
            player.configure(favourites: nil)
            downloads.configure(client: nil)
            playlistStore.configure(client: nil)
            favourites.configure(client: nil)
            pinnedItems.configure(accountKey: nil)
            libraryCache.clear()
        }
    }

    /// What makes a sign-out indistinguishable from a fresh install: every
    /// store forgets what it persisted — the preferences, every account's
    /// pins, the playback resume point and the volume, the downloads and
    /// their manifest — the device takes a new identity, and the artwork
    /// caches are dropped. The in-memory state the sign-out wiring already
    /// resets (the queue, the bans, the library cache, the playlist and
    /// favourite caches) is not repeated here.
    ///
    /// The Jelly Jams Backend is deliberately not asked anything: a server
    /// sign-out is a local affair. The account there lives on, with
    /// everything it holds, until the backend's own Sign Out deletes it —
    /// this app simply stops remembering it exists.
    private func forgetEverything() {
        preferences.forgetEverything()
        pinnedItems.forgetEverything()
        player.forgetEverything()
        downloads.removeAll()
        session.regenerateDeviceIdentity()
        ImageCache.shared.removeAll()
        ArtworkLoader.urlCache.removeAllCachedResponses()
    }

    /// The key a set of pins is stored under: item ids belong to one server,
    /// so pins are kept apart per account rather than shared across sign-ins.
    private static func accountKey(for user: SessionStore.StoredUser) -> String {
        "\(user.serverURL.absoluteString)#\(user.id)"
    }
}
