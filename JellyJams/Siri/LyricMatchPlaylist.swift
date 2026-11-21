#if os(iOS) || os(tvOS)
import Foundation

/// The pseudo-item that hands a remembered lyric line to the backend's
/// lyric search — the lyric sibling of ``TextToTunesPlaylist``.
///
/// "Play the song that goes …" is claimed by more than one Siri surface:
/// the lyric App Shortcut phrases, the plain song phrases (the line rides
/// in as the song's "name"), and the SiriKit Media domain. Which one
/// answers varies by device and utterance — the iPhone 14s of the world
/// have no Apple Intelligence to generalise the lyric phrases — so every
/// path that receives the words recognises the lyric markers and resolves
/// them to this sentinel instead of a library miss Siri cannot answer.
/// Like the other synthetic items, the meaning lives in the identifier —
/// the line rides in it, percent-encoded — because that is the only thing
/// that survives the system between resolution and playback.
/// ``SiriPlayback`` decodes it and runs ``LyricSearch``, playing the
/// single best match.
enum LyricMatchPlaylist {
    /// Internal, but visible to tests: an identifier with this prefix is a
    /// lyric-match request, and everything after it is the encoded line.
    static let idPrefix = "jellyjams.lyric-match/"

    /// What may ride in an identifier unescaped: the URL unreserved set.
    /// Everything else — spaces, ampersands, a line's own punctuation —
    /// becomes percent-escapes, so no spoken words can ever collide with
    /// a real Jellyfin id or break the prefix test.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func id(query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? query
        return idPrefix + encoded
    }

    /// The line an identifier carries, or nil for an ordinary item.
    /// A malformed escape decodes to its raw text rather than losing the
    /// request — ids like these are only ever minted by `id(query:)`.
    static func query(in id: String) -> String? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let encoded = String(id.dropFirst(idPrefix.count))
        return encoded.removingPercentEncoding ?? encoded
    }

    static func candidate(query: String) -> SiriCandidate {
        SiriCandidate(id: id(query: query), kind: .song, title: query)
    }

    /// The whole fallback decision, consulted the same way from every Siri
    /// path: a marked line goes to the backend — but only when there is a
    /// backend to send it to. Otherwise there is nothing to fall back to,
    /// and the request fails the way it always has.
    @MainActor
    static func fallbackCandidate(for query: String) -> SiriCandidate? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, BackendDestination.current() != nil else { return nil }
        return candidate(query: trimmed)
    }

    /// The markers that give a spoken span away as a remembered lyric
    /// line: the tails of the lyric App Shortcut phrases. When Siri binds
    /// the request to a different play template ("Play the song …"), they
    /// ride along at the front of the parameter, which is what lets every
    /// path recognise a lyric request even when the lyric shortcut itself
    /// was not picked. Longest first, so "that goes like" is not read as
    /// "that goes" plus a line starting "like".
    private static let markers = [
        "that goes like",
        "with the lyrics",
        "that goes",
        "with lyrics",
        "goes like",
    ]

    /// The remembered line inside a spoken span, or nil when the span is
    /// an ordinary name. Only a leading marker counts: a title that merely
    /// contains the words ("The Song That Goes On") is still a title.
    static func phrase(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for marker in markers {
            guard lowered.hasPrefix(marker + " ") else { continue }
            let line = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
        return nil
    }

    #if os(iOS)
    /// The song-shaped stand-in for ``SongQuery``: a lyric request that
    /// arrived through a song phrase resolves to this instead of a library
    /// miss, and ``SiriPlayback`` reads the line back out of its id.
    static func songEntity(query: String) -> SongEntity {
        SongEntity(item: BaseItemDto(id: id(query: query), name: query, type: .audio), artworkURL: nil)
    }
    #endif
}
#endif
