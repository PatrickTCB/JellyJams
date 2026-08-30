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
