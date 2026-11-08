import SwiftUI

/// Starts an instant mix — a queue the server builds from a seed song, album,
/// artist or playlist — replacing the current queue.
///
/// One view serves both the detail headers and the context menus: in a menu
/// the label shows its title, and headers pick the icon-only style they use
/// for Play and Shuffle.
///
/// The mix only exists on the server, so the button renders nothing while
/// browsing downloads, and nothing for item kinds the mix isn't offered for.
struct InstantMixButton: View {
    let item: BaseItemDto

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playlistStore: PlaylistStore
    @Environment(\.offlineBrowsing) private var offlineBrowsing

    @State private var isLoading = false

    var body: some View {
        if item.supportsInstantMix && !offlineBrowsing {
            Button(action: start) {
                Label("Instant Mix", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(isLoading)
            .help("Play an instant mix based on “\(item.displayName)”")
        }
    }

    private func start() {
        isLoading = true
        // Unstructured so the request outlives a context menu that dismisses
        // the moment its button is chosen.
        Task {
            defer { isLoading = false }
            do {
                let tracks = try await session.library.instantMix(for: item)
                guard !tracks.isEmpty else {
                    throw JellyfinError.emptyInstantMix(item.displayName)
                }
                player.play(tracks)
            } catch where !error.isCancellation {
                // The root-hosted alert, as with the context menu's other
                // actions: the failure lands after the menu has gone.
                playlistStore.presentActionError(error.userFacingMessage)
            } catch {}
        }
    }
}

extension BaseItemDto {
    /// Whether an instant mix is offered for this item: songs, albums,
    /// artists and playlists.
    var supportsInstantMix: Bool {
        guard id != nil else { return false }
        switch itemType {
        case .audio, .musicAlbum, .musicArtist, .playlist: return true
        default: return false
        }
    }
}
