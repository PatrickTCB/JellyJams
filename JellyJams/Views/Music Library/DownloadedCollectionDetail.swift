import SwiftUI

/// A downloaded collection opened from the Downloads section: the tracks
/// saved for it, entirely from the manifest — no server involved. Playback
/// resolves each track to its saved file via ``DownloadStore/localURL(forItemId:)``.
///
/// Pushed as its own value type (not the bare `BaseItemDto`) so it can share
/// a navigation stack with library destinations without both claiming to
/// resolve `BaseItemDto` pushes.
struct DownloadedCollectionDetail: View {
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var player: PlayerController
    let collection: BaseItemDto

    private var tracks: [BaseItemDto] {
        downloads.tracks(forItemId: collection.id ?? "")
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track) {
                        player.play(tracks, startAt: index)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("No songs", systemImage: "music.note")
            }
        }
        .navigationTitle(collection.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Navigation value for a downloaded collection. Distinct from `BaseItemDto`
/// so ``ItemDetailRouter`` doesn't claim pushes that should open the offline
/// detail instead.
struct DownloadedCollectionRef: Hashable {
    let id: String
    let name: String

    init?(_ item: BaseItemDto) {
        guard let id = item.id else { return nil }
        self.id = id
        self.name = item.displayName
    }
}