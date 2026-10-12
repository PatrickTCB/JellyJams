#if os(iOS)
import Intents
import UIKit

/// UIKit application-lifecycle plumbing for SwiftUI: exists so the process
/// can answer in-app Siri intent routing. Classic Siri (the SiriKit Media
/// domain) consults this before falling back elsewhere; see
/// ``MediaIntentHandler``.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is INPlayMediaIntent:
            MediaIntentHandler()
        default:
            nil
        }
    }

    /// The system waking the app to deliver background download events. The
    /// handler is held until ``DownloadSession``'s delegate reports event
    /// delivery is finished — calling it early lets the system suspend the
    /// app mid-delivery.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadSession.backgroundIdentifier else {
            completionHandler()
            return
        }
        DownloadSession.storeBackgroundEventsCompletionHandler(completionHandler)
    }
}
#endif
