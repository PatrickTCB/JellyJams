import SwiftUI

/// The current playback queue: reorderable, removable, and tap-to-jump. Only
/// the two most recently played tracks are shown above the current one.
///
/// Editing follows each platform's own idiom. iOS touches rows directly —
/// long-press to drag, swipe to delete — so it needs no edit mode. macOS has
/// no edit mode at all (`EditButton` and the `editMode` environment value are
/// unavailable there), so the queue behaves like the library's track lists:
/// a click selects, a drag reorders, a double-click plays, and the delete key
/// or the "Remove" toolbar button takes out the selection.
struct QueueView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.dismiss) private var dismiss

    #if os(macOS)
    /// The selected rows, keyed by queue-entry id so the same song twice in
    /// the queue stays two distinct selections.
    @State private var selection: Set<UUID> = []
    #endif

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                queueList
                    .onAppear { scrollToCurrentItem(using: proxy) }
                    .onChange(of: player.currentIndex) { scrollToCurrentItem(using: proxy) }
            }
            .navigationTitle("Queue")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        player.clearUpcoming()
                        if player.queue.isEmpty { dismiss() }
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(player.queue.isEmpty)
                }
                #if os(macOS)
                if !selectedQueueOffsets.isEmpty {
                    ToolbarItem {
                        Button(role: .destructive) {
                            player.removeFromQueue(atOffsets: selectedQueueOffsets)
                            selection = []
                        } label: {
                            Label("Remove \(selectedQueueOffsets.count)", systemImage: "minus.circle")
                        }
                    }
                }
                #endif
            }
            .overlay {
                if player.queue.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "music.note.list")
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    /// Only the last few played tracks are shown; rows map their slice
    /// offsets back to full-queue indices.
    @ViewBuilder
    private var queueList: some View {
        let start = player.visibleQueueStartIndex
        let entries = player.queue[start...]
        #if os(iOS)
        List {
            queueRows(start: start, entries: entries)
        }
        #else
        List(selection: $selection) {
            queueRows(start: start, entries: entries)
        }
        #endif
    }

    @ViewBuilder
    private func queueRows(start: Int, entries: ArraySlice<QueueEntry>) -> some View {
        ForEach(Array(zip(entries.indices, entries)), id: \.1.id) { index, entry in
            QueueRow(
                item: entry.item,
                isCurrent: index == player.currentIndex,
                isPlaying: player.isPlaying
            ) {
                player.play(atQueueIndex: index)
            }
        }
        .onDelete { offsets in
            player.removeFromQueue(atOffsets: IndexSet(offsets.map { $0 + start }))
            #if os(macOS)
            selection = []
            #endif
        }
        .onMove { offsets, destination in
            player.moveQueue(
                fromOffsets: IndexSet(offsets.map { $0 + start }),
                toOffset: destination + start
            )
        }
    }

    #if os(macOS)
    /// The selection's full-queue indices, computed against the live queue so
    /// an id whose entry has since gone contributes nothing.
    private var selectedQueueOffsets: IndexSet {
        IndexSet(player.queue.indices.filter { selection.contains(player.queue[$0].id) })
    }
    #endif

    /// Scrolls the queue so the currently playing entry is centered.
    private func scrollToCurrentItem(using proxy: ScrollViewProxy) {
        guard let index = player.currentIndex, player.queue.indices.contains(index) else { return }
        let currentID = player.queue[index].id
        Task { @MainActor in
            // Let the List lay out its rows before scrolling.
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(currentID, anchor: .center)
        }
    }
}

/// One queue row. Its inputs are plain values rather than the player itself,
/// so player state the row never reads cannot re-render it; the parent hands
/// down only the highlight the row shows.
private struct QueueRow: View {
    let item: BaseItemDto
    let isCurrent: Bool
    let isPlaying: Bool
    let onPlay: () -> Void

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var downloads: DownloadStore

    /// A downloaded track's cover comes from disk, never from the server.
    private var localArtworkURL: URL? { downloads.localArtworkURL(for: item) }

    var body: some View {
        #if os(iOS)
        Button(action: onPlay) { rowLabel }
            .buttonStyle(.plain)
        #else
        // The single click belongs to the list's selection — macOS has no
        // edit mode — and playback is the deliberate second gesture. A
        // whole-row button would swallow the press and block the row's
        // drag-to-reorder, the same reason the library's rows stay bare.
        rowLabel
            .onTapGesture(count: 2, perform: onPlay)
        #endif
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: session.library.artworkURL(for: item, size: 96), localURL: localArtworkURL)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                if let artist = item.subtitleArtist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}
