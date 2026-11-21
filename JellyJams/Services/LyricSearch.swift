import Foundation

/// The lyric-search round trip in one place: a remembered line of lyrics
/// in, the songs it belongs to out — best match first.
///
/// Two surfaces want this pipeline — the search screen, which folds a
/// handful of matches in above its name matches, and Siri, which plays
/// the single best match for "Play the song that goes …" — so the
/// pipeline lives here once: ask the backend with `GET /lyric-search`,
/// resolve the ids it picks through `tracks(byIds:)` — which keeps the
/// backend's order, the order the matches rank in, and drops ids the
/// server no longer knows rather than failing the batch. An empty answer
/// at either end is simply no matches; a backend refusal travels onward
/// as the `BackendError` that explains it, and each caller decides what
/// that means for its surface — the search screen swallows it silently,
/// Siri words it as "nothing matched".
enum LyricSearch {
    /// How many matches Siri asks for: a remembered line names one song,
    /// so only the best match is wanted, and it plays alone.
    static let bestMatchLimit = 1

    /// `query` to `GET /lyric-search`, the picks resolved through `client`
    /// — the answer as whole items, in the order the backend matched them.
    /// Empty when the backend matched nothing, or none of its picks exist
    /// on the user's server any more.
    static func tracks(
        query: String,
        limit: Int,
        destination: BackendDestination,
        client: JellyfinService
    ) async throws -> [BaseItemDto] {
        let answer = try await destination.backend.lyricSearch(
            userID: destination.userID,
            query: query,
            limit: limit
        )
        guard !answer.matchingTrackIDs.isEmpty else { return [] }
        return try await client.tracks(byIds: answer.matchingTrackIDs)
    }
}
