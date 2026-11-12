#if os(iOS)
import Foundation

/// The pseudo-playlist that hands a free-text request the library could not
/// answer to the backend's Text to Tunes.
///
/// Like the other synthetic playlists, the identifier carries the meaning —
/// here it is "say these words back to the backend", so the phrase rides in
/// the id itself, percent-encoded. The system rehydrates entities by
/// identifier between resolution and playback (and the SiriKit path only
/// ever returns an identifier), so a request that starts here can only be
/// finished from the id: an in-memory copy of the words would be stripped.
/// When the id comes back, ``SiriPlayback`` decodes the phrase and runs the
/// ``TextToTunes`` pipeline on it, exactly like the Home screen's sparkles
/// button.
enum TextToTunesPlaylist {
    /// Internal, but visible to tests: an identifier with this prefix is a
    /// fallback request, and everything after it is the encoded phrase.
    static let idPrefix = "jellyjams.text-to-tunes/"

    /// What may ride in an identifier unescaped: the URL unreserved set.
    /// Everything else — spaces, ampersands, a phrase's own punctuation —
    /// becomes percent-escapes, so no spoken words can ever collide with a
    /// real Jellyfin id or break the prefix test.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func entity(query: String) -> PlaylistEntity {
        PlaylistEntity(id: id(query: query), title: query)
    }

    static func id(query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? query
        return idPrefix + encoded
    }

    /// The phrase an identifier carries, or nil for an ordinary playlist.
    /// A malformed escape decodes to its raw text rather than losing the
    /// request — ids like these are only ever minted by `id(query:)`.
    static func query(in id: String) -> String? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let encoded = String(id.dropFirst(idPrefix.count))
        return encoded.removingPercentEncoding ?? encoded
    }

    /// The whole fallback decision, consulted the same way from both Siri
    /// paths: words the library could not answer go to the backend — but
    /// only when there are words worth sending and a backend to send them
    /// to. Otherwise there is nothing to fall back to, and the request
    /// fails the way it always has.
    @MainActor
    static func fallbackEntity(for query: String) -> AudioEntity? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, TextToTunes.currentDestination() != nil else { return nil }
        return .playlist(entity(query: trimmed))
    }
}
#endif
