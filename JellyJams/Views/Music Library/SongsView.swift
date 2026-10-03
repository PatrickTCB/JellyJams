import SwiftUI

struct SongsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @ObservedObject var model: PagedItems
    /// The selected songs (rows are keyed by track id): click to select,
    /// double-click to play, shift-arrow to extend.
    @State private var selection: Set<String> = []

    /// The selected songs in list order — what selection actions act on.
    private var selectedTracks: [BaseItemDto] {
        TrackEntry.rows(model.items).filter { selection.contains($0.id) }.map(\.item)
    }

    var body: some View {
        // Resolved once: `TrackEntry.rows` and `selectedTracks` re-derive the
        // whole list, and a `TrackRow` call naming them inside the `ForEach`
        // would do that work once per row.
        let entries = TrackEntry.rows(model.items)
        let items = model.items
        let selected = selectedTracks
        List(selection: $selection) {
            // Rows keyed by a non-optional id matching the selection type:
            // Jellyfin's ids are optional, and a String?-keyed row never
            // matches a Set<String> selection.
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                TrackRow(track: entry.item, showArtwork: true, selectedTracks: selection.contains(entry.id) ? selected : []) {
                    player.play(items, startAt: index)
                }
                .task { await model.loadMoreIfNeeded(entry.item) }
            }
            if model.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            } else if let error = model.errorMessage, !model.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn’t load more songs", systemImage: "wifi.exclamationmark")
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.loadNextPage() } }
                }
            }
        }
        .listStyle(.plain)
        .shiftArrowSelection($selection, ids: model.items.compactMap(\.id))
        .onKeyPress(.escape) {
            selection = []
            return .handled
        }
        .focusable()
        .navigationTitle("Songs")
        .overlay {
            if let error = model.errorMessage, model.isEmpty {
                LoadFailureOverlay(title: "Couldn’t Load Songs", message: error) {
                    await model.reload()
                    return model.errorMessage == nil
                }
            } else if model.hasLoadedOnce, model.isEmpty, !model.isLoading {
                ContentUnavailableView("No songs", systemImage: "music.note")
            }
        }
        .toolbar {
            if !selectedTracks.isEmpty {
                ToolbarItem { TrackSelectionMenu(tracks: selectedTracks) }
            }
            ToolbarItem {
                Button {
                    player.play(model.items, shuffled: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .disabled(model.isEmpty)
            }
            ToolbarItem {
                SortMenu(sortBy: $model.sortBy, sortOrder: $model.sortOrder, options: model.sortOptions)
            }
        }
        .refreshToolbarItem { await model.reload() }
        .task(id: model.query) { await model.load(from: session.library) }
        .refreshable { await model.reload() }
    }
}
