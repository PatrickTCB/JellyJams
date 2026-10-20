import SwiftUI

/// The current playback queue: reorderable, removable, and tap-to-jump.
struct QueueView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                let entries = player.queue
                List {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        QueueRow(
                            item: entry.item,
                            isCurrent: index == player.currentIndex,
                            isPlaying: player.isPlaying
                        ) {
                            player.play(atQueueIndex: index)
                        }
                    }
                    .onDelete { player.removeFromQueue(atOffsets: $0) }
                    .onMove { player.moveQueue(fromOffsets: $0, toOffset: $1) }
                }
                .onAppear { scrollToCurrentItem(using: proxy) }
                .onChange(of: player.currentIndex) { scrollToCurrentItem(using: proxy) }
            }
            .navigationTitle("Queue")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
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
            }
            .overlay {
                if player.queue.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "music.note.list")
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

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
        Button(action: onPlay) {
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
        .buttonStyle(.plain)
    }
}
