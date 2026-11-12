import Foundation

/// The Text to Tunes round trip in one place: a free-text description of
/// what the listener wants to hear in, playable tracks from the user's own
/// server out.
///
/// Two surfaces want this pipeline — the Home screen's sparkles button
/// (`TextToTunesSheet`) and Siri, where a request the library cannot answer
/// falls back to it (`TextToTunesPlaylist`) — so the pipeline lives here
/// once: ask the backend with `GET /text-to-tunes`, resolve the ids it picks
/// through `tracks(byIds:)` — which keeps the backend's order, the order the
/// songs play in, and drops ids the server no longer knows rather than
/// failing the batch — and report each stage of coming back empty as its
/// own `Failure`. The caller decides what to do with the tracks; nothing
/// here touches the player.
enum TextToTunes {
    /// How many songs to ask for when the requester didn't say: the sheet's
    /// default and the Siri fallback agree on this.
    static let defaultSongLimit = 30

    /// The ways the pipeline can come back empty-handed, as distinct
    /// outcomes so each caller can word them for its own surface. A
    /// refusal with a reason of its own arrives as a `BackendError`
    /// instead and travels untouched.
    enum Failure: Error, Sendable, Equatable {
        /// The backend knew nothing for that description.
        case noPicks
        /// The backend picked ids, but none of them exist on the user's
        /// server any more.
        case noneResolvable
    }

    /// The backend and the account to speak as — every endpoint but `/ping`
    /// keys off the registered `userID`, so a request needs both halves.
    struct Destination: Sendable {
        let backend: JellyJamsBackend
        let userID: String
    }

    /// The destination the given settings describe — nil when there is no
    /// backend address to talk to, or no signed-in user to speak as. The
    /// state is taken as inputs rather than read from the app's graph, so
    /// a view can pass the environment it is already holding and a test
    /// can pass whatever it likes.
    static func destination(address: String, deviceInfo: DeviceInfo, userID: String?) -> Destination? {
        guard let backend = JellyJamsBackend.configured(address: address, deviceInfo: deviceInfo),
              let userID
        else { return nil }
        return Destination(backend: backend, userID: userID)
    }

    /// The destination as `AppServices` currently knows it. Siri has no
    /// environment to read, which is what this is for.
    @MainActor
    static func currentDestination() -> Destination? {
        let services = AppServices.shared
        return destination(
            address: services.preferences.jellyJamsBackendAddress,
            deviceInfo: services.session.deviceInfo,
            userID: services.session.currentUser?.id
        )
    }

    /// `description` to `GET /text-to-tunes`, the picks resolved through
    /// `client` — the answer as whole items, in the order the backend
    /// chose them. Throws `Failure.noPicks` or `Failure.noneResolvable`
    /// when either end comes back empty.
    static func tracks(
        description: String,
        limit: Int,
        destination: Destination,
        client: JellyfinService
    ) async throws -> [BaseItemDto] {
        let answer = try await destination.backend.textToTunes(
            userID: destination.userID,
            query: description,
            limit: limit
        )
        guard !answer.newTrackIDs.isEmpty else { throw Failure.noPicks }
        let tracks = try await client.tracks(byIds: answer.newTrackIDs)
        guard !tracks.isEmpty else { throw Failure.noneResolvable }
        return tracks
    }
}
