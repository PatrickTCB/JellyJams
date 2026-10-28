import Foundation

/// What Infinite Queue asks the backend for when the queue runs short.
///
/// The two cases are the backend's two extension endpoints: a listen that is
/// an album in track order continues with whatever album the backend picks
/// next; every other listen gets alchemy seeded from the queue itself.
enum QueueExtensionPlan: Equatable, Sendable {
    /// The listener is playing one album in track order and the queue runs
    /// out with it — `GET /extend-queue-by-album`, keyed on that album.
    case album(id: String)
    /// Anything else — `GET /extend-queue`, seeded from the queue so far.
    case general

    /// How many tracks of one album an in-order run needs before it counts as
    /// listening to an album. A lone track from an album is a song choice, not
    /// an album listen — there is no order to observe in a single item — so
    /// its neighbours are what prove it, and a run of one falls back to
    /// alchemy, which the lone song still seeds perfectly well.
    private static let minimumAlbumRun = 2

    /// Whether `next` is the track that ought to follow `previous` in an
    /// album listen: the next number on the same disc, or the first track of
    /// the next disc. A missing number can never confirm an expected order,
    /// so it never continues a run — an album whose tracks carry no numbers
    /// is indistinguishable from a handful of songs that share an album.
    private static func continuesAlbum(previous: BaseItemDto, next: BaseItemDto) -> Bool {
        guard let previousTrack = previous.indexNumber, let nextTrack = next.indexNumber else { return false }
        let previousDisc = previous.parentIndexNumber ?? 1
        let nextDisc = next.parentIndexNumber ?? 1
        if nextDisc == previousDisc { return nextTrack == previousTrack + 1 }
        return nextDisc == previousDisc + 1 && nextTrack == 1
    }

    /// Reads a queue the way the listener hears it and decides which
    /// extension it deserves.
    ///
    /// An album listen means: the current track belongs to an album, every
    /// track still to come continues that album in order all the way to the
    /// end of the queue (so the appended album joins on seamlessly rather
    /// than landing between this album's tracks and something else), and the
    /// same-album tracks behind the current one — looked back for, so a
    /// mid-album start still counts — are the ones expected before it. The
    /// run may start anywhere: a different album (or a different kind of
    /// queue entry) immediately behind is simply where the listen began.
    ///
    /// A shuffled queue never counts: its order is not a listen order, even
    /// when the shuffle happens to line tracks up.
    static func detect(queue: [QueueEntry], currentIndex: Int, isShuffled: Bool) -> QueueExtensionPlan {
        guard !isShuffled, queue.indices.contains(currentIndex) else { return .general }
        let current = queue[currentIndex].item
        guard let albumID = current.albumID, current.indexNumber != nil else { return .general }

        // Forward: the run must reach the end of the queue. One gap, one
        // foreign track, one missing number, and the queue is not an album
        // about to finish.
        var runLength = 1
        var previous = current
        for entry in queue[(currentIndex + 1)...] {
            guard entry.item.albumID == albumID, continuesAlbum(previous: previous, next: entry.item) else {
                return .general
            }
            previous = entry.item
            runLength += 1
        }

        // Backward: same-album entries must precede in order; anything else
        // is where the run started, which is allowed to be anywhere.
        var next = current
        for entry in queue[..<currentIndex].reversed() {
            guard entry.item.albumID == albumID else { break }
            guard continuesAlbum(previous: entry.item, next: next) else { return .general }
            next = entry.item
            runLength += 1
        }

        guard runLength >= minimumAlbumRun else { return .general }
        return .album(id: albumID)
    }
}

/// Fetches the tracks Infinite Queue appends when the running queue gets
/// short: the backend's next album for an album listen, or its alchemy picks
/// for any other, resolved into whole items ready to queue.
///
/// What the backend can extend for follows the same rule bans do — a signed-in
/// account, a saved address that parses, and a registration — because both
/// endpoints key off the `userID` that `/register` put on the backend's books.
/// Configured from ``AppServices`` on the same publisher trio, for the same
/// reasons: the settings sheet edits the address one keystroke at a time, so
/// every value arrives from the publisher rather than being read back.
@MainActor
final class QueueExtender {
    /// How many of the queue's ids seed one alchemy request. The queue of a
    /// long-running Infinite Queue listen grows without bound, and every id in
    /// it is a song the backend would weigh; the tail — the recent history and
    /// what is coming up — is the part that describes the listen right now.
    static let sourceSongLimit = 50

    private var userID: String?
    /// The saved backend address, normalised — nil while there is no address,
    /// it will not parse, or the account has never registered.
    private var backendURL: URL?
    private var deviceInfo: DeviceInfo?
    /// Passed through to every client the extender builds. Production leaves
    /// it nil; tests install their stub loader with it.
    private var sessionConfiguration: URLSessionConfiguration?

    /// Whether the backend can extend a queue at all right now.
    var canExtend: Bool { userID != nil && backendURL != nil }

    func configure(
        userID: String?,
        address: String,
        registered: Bool,
        deviceInfo: DeviceInfo,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.userID = userID
        self.backendURL = registered
            ? (try? JellyJamsBackend.normalizeAddress(address))
            : nil
        self.deviceInfo = deviceInfo
        self.sessionConfiguration = sessionConfiguration
    }

    /// The tracks one extension adds, in the order they should play.
    ///
    /// The ids the backend picks are resolved through the user's own Jellyfin
    /// server — the backend never sends whole items — and ids the server
    /// cannot find are dropped rather than failing the batch: one dead entry
    /// should not cost the whole top-up. An empty answer resolves to nothing
    /// to append, which is a success the caller treats as a no-op.
    func tracks(
        for plan: QueueExtensionPlan,
        existingQueueIDs: [String],
        client: JellyfinService
    ) async throws -> [BaseItemDto] {
        guard let backend = makeBackend(), let userID else {
            throw BackendError.notSignedIn
        }
        let answer: BackendExtendedQueue
        switch plan {
        case .album(let albumID):
            answer = try await backend.extendQueueByAlbum(userID: userID, currentAlbumID: albumID)
        case .general:
            let sources = Array(existingQueueIDs.suffix(Self.sourceSongLimit))
            answer = try await backend.extendQueue(userID: userID, existingQueue: sources)
        }
        guard !answer.newTrackIDs.isEmpty else { return [] }
        return try await client.tracks(byIds: answer.newTrackIDs)
    }

    /// The client for the address the extender points at, built per fetch
    /// rather than in `configure`, for the reason ``BanStore`` builds per
    /// send: the settings field edits the address live, and a client saved
    /// along with it would be rebuilt — and abandoned — as it was typed.
    private func makeBackend() -> JellyJamsBackend? {
        guard let backendURL, let deviceInfo else { return nil }
        return JellyJamsBackend(
            baseURL: backendURL,
            deviceInfo: deviceInfo,
            sessionConfiguration: sessionConfiguration
        )
    }
}
