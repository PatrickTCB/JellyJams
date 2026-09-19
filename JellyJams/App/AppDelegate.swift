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
}
#endif
