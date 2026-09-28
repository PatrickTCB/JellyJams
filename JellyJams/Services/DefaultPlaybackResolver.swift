import Foundation

/// Turns the ``DefaultPlaybackSetting`` into the queue an open-ended play
/// request starts.
///
/// Shared by every surface that answers "play something" with nothing named:
/// the system play button (``PlayerController/playOrResume()``) and Siri's
/// default-playback sentinel (``SiriPlayback``). A missing setting, or one
/// whose item has vanished from the server, falls back to the favourites
/// shuffle rather than failing.
enum DefaultPlaybackResolver {
    struct Resolved: Sendable {
        let tracks: [BaseItemDto]
        let shuffled: Bool
        /// `nil` means "leave the player's mode alone" — what the favourites
        /// fallback does, matching the behaviour before the setting existed.
        let repeatMode: RepeatMode?
    }

    static func resolve(
        setting: DefaultPlaybackSetting?,
        client: JellyfinService
    ) async throws -> Resolved {
        guard let setting else { return try await fallback(client: client) }

        guard let item = try await client.item(byId: setting.itemId) else {
            return try await fallback(client: client)
        }

        let tracks: [BaseItemDto]
        switch setting.kind {
        case .song:
            tracks = [item]
        case .album, .artist, .playlist:
            tracks = try await client.tracks(for: item)
        }
        guard !tracks.isEmpty else { return try await fallback(client: client) }

        // An artist's catalogue shuffles even when the setting says not to,
        // matching "play <artist>" everywhere else in the app.
        return Resolved(
            tracks: tracks,
            shuffled: setting.shuffle || setting.kind == .artist,
            repeatMode: setting.repeatMode
        )
    }

    private static func fallback(client: JellyfinService) async throws -> Resolved {
        Resolved(
            tracks: try await PlayerController.fallbackQueue(client: client),
            shuffled: false,
            repeatMode: nil
        )
    }
}
