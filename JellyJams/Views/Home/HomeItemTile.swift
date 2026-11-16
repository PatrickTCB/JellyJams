import SwiftUI

/// One tile in a home row: the standard grid cell at a fixed size. It
/// navigates through the library stack unless `onSelect` replaces the tap
/// action, the way mixtape tiles play instead of opening.
struct HomeItemTile: View {
    static let width: CGFloat = 150 * ArtworkImage.sizeMultiplier

    let item: BaseItemDto
    var title: String?
    var onSelect: ((BaseItemDto) -> Void)?

    @Environment(SessionStore.self) private var session
    @Environment(PlayerController.self) private var player
    @Environment(PlaylistStore.self) private var playlistStore

    var body: some View {
        Group {
            if let onSelect {
                Button { onSelect(item) } label: { cell }
            } else {
                NavigationLink(value: item) { cell }
            }
        }
        .buttonStyle(.plain)
        .frame(width: Self.width)
        .remotePlayAction(playAction)
    }

    private var cell: some View {
        ItemGridCell(item: item, title: title)
    }

    /// What the Siri Remote's play/pause button does while this tile holds
    /// focus and nothing is loaded: the tile's own tap action when that plays
    /// (mixtapes), else the item's tracks — an album, a playlist, or a pinned
    /// artist's songs. Failures land in the root-hosted alert, as the context
    /// menu's and Instant Mix's do.
    private var playAction: () -> Void {
        if let onSelect {
            return { onSelect(item) }
        }
        return {
            Task {
                do {
                    let tracks = try await session.library.tracks(for: item)
                    guard !tracks.isEmpty else {
                        throw JellyfinError.emptyCollection(item.displayName)
                    }
                    player.play(tracks)
                } catch where !error.isCancellation {
                    playlistStore.presentActionError(error.userFacingMessage)
                } catch {}
            }
        }
    }
}