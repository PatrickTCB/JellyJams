#if os(iOS) || os(tvOS)
import Foundation
import Intents

/// Tells classic Siri what kind of media app Jelly Jams is right now.
///
/// `INMediaUserContext` is one of the signals Siri's app selection weighs
/// when a request names no app ("Play some music"): an app that publishes a
/// playable library reads as a candidate, and one that publishes nothing
/// reads as having no usable catalog. On tvOS this matters doubly, because
/// the SiriKit Media domain is the only playback path there — for classic
/// Siri and Siri AI alike.
///
/// Published on every sign-in transition by ``AppServices``: a signed-in
/// account is a registered (free) subscription as far as the context is
/// concerned, with the library's song count as its size; a sign-out
/// publishes an empty library so Siri stops weighing the app.
enum SiriMediaUserContext {

    @MainActor
    static func publish(client: JellyfinService?) async {
        let context = INMediaUserContext()
        if let client {
            context.subscriptionStatus = .subscribed
            // A count-only query: one item back, the total in the envelope.
            // A server that cannot answer leaves the count unset rather
            // than claiming an empty library.
            let result = try? await client.getItems(includeItemTypes: [.audio], recursive: true, limit: 1)
            context.numberOfLibraryItems = result?.totalRecordCount
        } else {
            context.subscriptionStatus = .notSubscribed
            context.numberOfLibraryItems = 0
        }
        context.becomeCurrent()
    }
}
#endif
