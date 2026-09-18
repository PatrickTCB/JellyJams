import SwiftUI

/// Top-level view that swaps between onboarding and the signed-in app based on
/// session state. Service wiring happens in ``AppServices``; this view only
/// renders, and hosts the alerts that need to outlive the screens raising
/// them.
struct RootContainerView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var favourites: FavouriteStore
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.isRestoring {
                ProgressView()
            } else if session.isSignedIn {
                MainShellView()
            } else {
                ServerLoginView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            if phase == .background || phase == .inactive {
                player.savePlaybackState()
            }
            #endif
        }
        .alert(
            "Account Error",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { session.dismissError() }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .alert(
            "Playback Problem",
            isPresented: Binding(
                get: { player.errorMessage != nil },
                set: { if !$0 { player.dismissError() } }
            )
        ) {
            Button("Retry") { player.retry() }
            if player.canGoNext {
                Button("Skip") { player.next() }
            }
            Button("OK", role: .cancel) { player.dismissError() }
        } message: {
            Text(player.errorMessage ?? "")
        }
        // Favourite writes are raised from rows and menus that are often on
        // their way out by the time the write fails, so the alert is hosted
        // here on a view that stays put rather than on the affordance itself.
        .alert(
            "Couldn’t Update Favourite",
            isPresented: Binding(
                get: { favourites.errorMessage != nil },
                set: { if !$0 { favourites.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { favourites.dismissError() }
        } message: {
            Text(favourites.errorMessage ?? "")
        }
        .alert(
            "Download Problem",
            isPresented: Binding(
                get: { downloads.errorMessage != nil },
                set: { if !$0 { downloads.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { downloads.dismissError() }
        } message: {
            Text(downloads.errorMessage ?? "")
        }
    }
}
