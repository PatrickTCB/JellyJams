import SwiftUI

/// The standard "that didn't load" panel: what failed, why, and a way to try
/// again.
///
/// Every screen that can fail to load shows this, so the wording, the icon and
/// the retry affordance stay the same wherever the failure happens.
struct LoadFailureView: View {
    var title: String = "Couldn’t load"
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await retry() } }
        }
    }
}

/// Picks between ``OfflineView`` and ``LoadFailureView`` for a failed load,
/// depending on whether the signed-in server is currently reachable: a
/// connectivity drop reads as "you're offline" rather than a generic failure.
struct LoadFailureOverlay: View {
    var title: String = "Couldn’t load"
    let message: String
    /// Re-runs the failed load and reports whether it succeeded, so the
    /// offline case can decide whether to re-check server reachability.
    let retry: () async -> Bool

    @EnvironmentObject private var session: SessionStore

    var body: some View {
        if session.serverReachable {
            LoadFailureView(title: title, message: message) { _ = await retry() }
        } else {
            OfflineView(retry: retry)
        }
    }
}
