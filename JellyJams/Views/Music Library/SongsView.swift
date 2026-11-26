import SwiftUI

struct SongsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(PlayerController.self) private var player
    @Bindable var model: PagedItems
    /// The selected songs (rows are keyed by track id): click to select,
    /// double-click to play, shift-arrow to extend.
    @State private var selection: Set<String> = []

    /// The selected songs in list order — what selection actions act on.
    private var selectedTracks: [BaseItemDto] {
        TrackEntry.rows(model.items).filter { selection.contains($0.id) }.map(\.item)
    }

    var body: some View {
        container
            .navigationTitle("Songs")
            .tvScrollingBar(title: "Songs") {
                selectionMenu
                shuffleButton
                sortMenu
            }
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
                    ToolbarItem { selectionMenu }
                }
                ToolbarItem {
                    shuffleButton
                }
                ToolbarItem {
                    sortMenu
                }
            }
            .refreshToolbarItem { await model.reload() }
            .task(id: model.query) { await model.load(from: session.library) }
            .refreshable { await model.reload() }
    }

    /// The bar and the rows in their scroll container.
    ///
    /// tvOS scrolls a plain stack, like the grids: a `List` row there is one
    /// focus target as a whole, which swallows the bar's buttons into a single
    /// row-sized highlight the remote cannot move inside — and a focus section
    /// on the row's content does not override the row itself. In a stack each
    /// bar button and each row is its own focus target. The other platforms
    /// keep the List and its selection machinery.
    @ViewBuilder private var container: some View {
        // Resolved once: `TrackEntry.rows` and `selectedTracks` re-derive the
        // whole list, and a `TrackRow` call naming them inside the `ForEach`
        // would do that work once per row.
        let entries = TrackEntry.rows(model.items)
        let items = model.items
        let selected = selectedTracks
        #if os(tvOS)
        ScrollView {
            TVScrollingBarSlot()
            LazyVStack(alignment: .leading, spacing: 12) {
                rows(entries: entries, items: items, selected: selected)
                footer
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        #else
        List(selection: $selection) {
            TVScrollingBarSlot()
            rows(entries: entries, items: items, selected: selected)
            footer
        }
        .listStyle(.plain)
        .shiftArrowSelection($selection, ids: model.items.compactMap(\.id))
        .onKeyPress(.escape) {
            selection = []
            return .handled
        }
        // Keyboard platforms need the list itself focusable for the selection
        // keys.
        .focusable()
        #endif
    }

    /// The song rows, shared by both containers. Rows are keyed by a
    /// non-optional id matching the selection type: Jellyfin's ids are
    /// optional, and a String?-keyed row never matches a Set<String>
    /// selection.
    @ViewBuilder
    private func rows(entries: [TrackEntry], items: [BaseItemDto], selected: [BaseItemDto]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            TrackRow(track: entry.item, showArtwork: true, tapBehavior: rowTapBehavior, selectedTracks: selection.contains(entry.id) ? selected : []) {
                player.play(items, startAt: index)
            }
            .remotePlayAction { player.play(items, startAt: index) }
            .task(id: model.settledLoads) { await model.loadMoreIfNeeded(entry.item) }
        }
    }

    /// The loading spinner / load-more failure shown after the last row.
    @ViewBuilder private var footer: some View {
        if model.isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
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

    /// On tvOS the single press belongs to playback: there is no selection
    /// gesture to give it to — no edit mode, no drag, no keyboard — so rows
    /// play on select, as ``TrackListDetail``'s do.
    private var rowTapBehavior: TrackRow.TapBehavior {
        #if os(tvOS)
        .play
        #else
        .select
        #endif
    }

    @ViewBuilder private var selectionMenu: some View {
        if !selectedTracks.isEmpty {
            TrackSelectionMenu(tracks: selectedTracks)
        }
    }

    private var shuffleButton: some View {
        Button {
            player.play(model.items, shuffled: true)
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        .disabled(model.isEmpty)
    }

    private var sortMenu: some View {
        SortMenu(sortBy: $model.sortBy, sortOrder: $model.sortOrder, options: model.sortOptions)
    }
}
