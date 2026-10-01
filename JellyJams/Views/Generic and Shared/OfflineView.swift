import SwiftUI

/// Shown in place of ``LoadFailureView`` when the signed-in server is
/// currently unreachable, so a dropped Jellyfin connection reads as "you're
/// offline" rather than a generic load failure.
///
/// Retrying re-runs the failed load; ``SessionStore/checkServerReachability()``
/// only runs afterwards, and only if that load actually succeeded — a retry
/// that fails for an unrelated reason shouldn't flip `serverReachable` back to
/// true.
struct OfflineView: View {
    var title: String = "You’re Offline"
    var message: String = "Check your connection to the Jellyfin server and try again."
    let retry: () async -> Bool

    @EnvironmentObject private var session: SessionStore

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                Task {
                    if await retry() {
                        await session.checkServerReachability()
                    }
                }
            }
        }
    }
}
