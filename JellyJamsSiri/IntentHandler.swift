import Intents

/// The tvOS face of classic Siri — the SiriKit Media domain, which is the
/// only third-party playback path on Apple TV (the App Intents audio schema
/// is unavailable there, for classic Siri and Siri AI alike).
///
/// tvOS has no in-app intent handling, so this extension is where Siri
/// arrives. It is deliberately lightweight: an extension is a separate
/// short-lived process with no access to the app's session or player, and
/// sharing the credentials into it would buy little on a platform where the
/// app foregrounds anyway. So resolution passes the request straight
/// through as a stand-in item, and handling answers `.continueInApp` — the
/// tvOS-recommended foreground launch — leaving the real search and
/// playback to the app, which receives the request as a user activity
/// (see `SiriMediaRequest` and `MediaIntentHandler.play(_:)` in the app
/// target).
final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        guard intent is INPlayMediaIntent else { return self }
        return PlayMediaIntentHandler()
    }
}

final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {

    /// Resolves the request to a single pass-through item: the spoken title
    /// for Siri's confirmation, under an identifier the app recognises as
    /// "resolve this request fresh" rather than a library id. The app does
    /// the real search once it foregrounds, so no credentials are needed
    /// here — and a signed-out or no-match request is reported by the app's
    /// own screen, which is where the person is looking on TV.
    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let search = intent.mediaSearch
        let title = search?.mediaName ?? search?.artistName ?? "Music"
        let item = INMediaItem(
            identifier: SiriMediaRequest.passThroughIdentifier(),
            title: title,
            type: search?.mediaType ?? .unknown,
            artwork: nil
        )
        completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
    }

    /// Hands the request to the app. `.continueInApp` foregrounds it — the
    /// preferred interaction on tvOS, where one app owns the screen — and
    /// the system delivers the intent on the activity's `interaction`. The
    /// search fields ride in userInfo as well, a fallback copy should the
    /// intent ever arrive stripped.
    func handle(
        intent: INPlayMediaIntent,
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        let activity = NSUserActivity(activityType: SiriMediaRequest.activityType)
        activity.userInfo = SiriMediaRequest.userInfo(for: intent.mediaSearch)
        completion(INPlayMediaIntentResponse(code: .continueInApp, userActivity: activity))
    }
}
