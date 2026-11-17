#if os(iOS) || os(tvOS)
import Foundation
import Intents

/// The contract between the tvOS Siri extension and the app for a spoken
/// playback request.
///
/// On tvOS, SiriKit intent handling lives in an Intents app extension — a
/// separate process with no access to the app's session or player — and the
/// audio schema does not exist there at all. So the extension resolves a
/// *pass-through* item (the request itself, under ``identifierPrefix``) and
/// answers `.continueInApp`: the app foregrounds, receives the request as a
/// user activity, and runs the real search and playback in its own process.
/// This type is the shared vocabulary of that hand-off, compiled into both
/// targets.
///
/// The request travels two ways: the system attaches the resolved
/// `INPlayMediaIntent` to the activity's `interaction`, and the extension
/// also copies the search fields into `userInfo` as a fallback. The snapshot
/// init reads both, preferring the intent.
struct SiriMediaRequest: Sendable {
    /// The activity type SiriKit uses for a `.continueInApp` hand-off: the
    /// intent's own name.
    static let activityType = "INPlayMediaIntent"

    /// Marks an identifier as the extension's pass-through stand-in rather
    /// than a real library id, so the app knows to resolve the request fresh
    /// instead of looking the identifier up on the server.
    static let identifierPrefix = "jellyjams.request/"

    /// userInfo keys carrying the search fields alongside the intent.
    private static let nameKey = "name"
    private static let artistKey = "artist"
    private static let mediaTypeKey = "mediaType"

    let mediaType: INMediaItemType?
    let name: String?
    let artist: String?
    /// A real library identifier when the request carries one — a donated
    /// interaction, say. Nil for search-bearing and pass-through requests,
    /// which resolve through the shared pipeline instead.
    let concreteIdentifier: String?

    /// Takes a `Sendable` snapshot of the delivered activity, synchronously
    /// on the caller's side, so the intent objects themselves never cross
    /// into the playback task.
    init(activity: NSUserActivity) {
        self.init(intent: activity.interaction?.intent as? INPlayMediaIntent, userInfo: activity.userInfo)
    }

    /// The snapshot's substance, split out from the activity so tests can
    /// hand it an intent directly — `NSUserActivity.interaction` is
    /// read-only, attached by the system at delivery.
    init(intent: INPlayMediaIntent?, userInfo: [AnyHashable: Any]?) {
        let search = intent?.mediaSearch
        name = search?.mediaName ?? userInfo?[Self.nameKey] as? String
        artist = search?.artistName ?? userInfo?[Self.artistKey] as? String
        if let raw = search?.mediaType.rawValue ?? userInfo?[Self.mediaTypeKey] as? Int {
            mediaType = INMediaItemType(rawValue: raw)
        } else {
            mediaType = nil
        }
        if let identifier = intent?.mediaItems?.first?.identifier,
           !identifier.hasPrefix(Self.identifierPrefix) {
            concreteIdentifier = identifier
        } else {
            concreteIdentifier = nil
        }
    }

    /// The identifier the extension resolves its pass-through item with.
    /// Opaque by design: the app re-resolves the request, so nothing rides
    /// in it beyond the prefix that marks it.
    static func passThroughIdentifier() -> String {
        identifierPrefix + UUID().uuidString
    }

    /// The search fields as activity userInfo — the fallback copy of what
    /// the intent itself carries.
    static func userInfo(for search: INMediaSearch?) -> [String: Any] {
        var info: [String: Any] = [:]
        if let name = search?.mediaName { info[nameKey] = name }
        if let artist = search?.artistName { info[artistKey] = artist }
        if let mediaType = search?.mediaType { info[mediaTypeKey] = mediaType.rawValue }
        return info
    }
}
#endif
