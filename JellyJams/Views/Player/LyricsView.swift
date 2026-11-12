import SwiftUI

/// A song's lyrics, read along with it: one line per row, with the line being
/// sung highlighted and kept in view.
///
/// Raised in the queue's sheet shape — its own navigation bar and a "Done" to
/// dismiss it — from two places. The lyrics button in the now playing screen
/// opens it without a ``track``: it then follows the player rather than the
/// track it was opened on, so a track change while it is open brings up the
/// new track's lyrics. A song's context menu opens it on that song, which it
/// keeps whatever plays next; its lines are read along only while that song
/// is the one playing.
struct LyricsView: View {
    /// The song to show, or nil to follow the player.
    var track: BaseItemDto?

    @Environment(SessionStore.self) private var session
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var loader = LoadableModel(LyricTimeline())

    private var timeline: LyricTimeline { loader.value }

    /// The song whose lyrics are on screen.
    private var item: BaseItemDto? { track ?? player.currentItem }

    /// Whether the song on screen is the one playing — the only song the
    /// clock is timing, so the only one with a line being sung.
    private var isCurrent: Bool {
        guard let id = item?.id else { return false }
        return id == player.currentItem?.id
    }

    var body: some View {
        NavigationStack {
            LyricLines(timeline: timeline, isCurrent: isCurrent)
                // A new track's lines start from the top, not from wherever
                // the last track's were scrolled to.
                .id(item?.id)
                .overlay { overlay }
                .navigationTitle("Lyrics")
                // The song on screen needn't be the one playing, so the sheet
                // names it — falling back the way the now playing screen does.
                .navigationSubtitle(item?.displayName ?? "Not Playing")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 360, minHeight: 420)
        .task(id: item?.id) {
            // Kept while the new track's load runs, the last track's lines
            // would be read against the new track's clock.
            loader.reset()
            await load()
        }
    }

    @ViewBuilder private var overlay: some View {
        if let errorMessage = loader.errorMessage, timeline.isEmpty {
            LoadFailureOverlay(title: "Couldn’t Load Lyrics", message: errorMessage) {
                await load()
                return loader.errorMessage == nil
            }
        } else if timeline.isEmpty, loader.isPending {
            if session.serverReachable {
                ProgressView()
            } else {
                // Offline, the request waits up to a minute for the connection
                // to come back rather than failing, so say why nothing has
                // arrived instead of spinning.
                OfflineView {
                    await load()
                    return loader.errorMessage == nil
                }
            }
        } else if timeline.isEmpty {
            ContentUnavailableView("No Lyrics", systemImage: "music.microphone")
        }
    }

    private func load() async {
        let item = self.item
        await loader.load {
            guard let item else { return LyricTimeline() }
            return try await session.library.lyrics(for: item)
        }
    }
}

/// The lines themselves, with the one being sung highlighted and scrolled to
/// the middle of the sheet.
///
/// The only part of the sheet that observes ``PlaybackClock``, which ticks
/// every half second: the current line is worked out here, once per tick, and
/// handed to each row as a plain flag.
private struct LyricLines: View {
    let timeline: LyricTimeline
    /// Whether the song is the one playing. The clock times only that one,
    /// so any other song's lines are shown with none of them current.
    let isCurrent: Bool

    @Environment(PlaybackClock.self) private var clock
    @State private var position = ScrollPosition(idType: Int.self)
    /// Set while the listener scrolls the lines by hand, so following the
    /// song doesn't drag them back mid-gesture. Following picks up again at
    /// the next line once they let go.
    @State private var isBrowsing = false

    var body: some View {
        let currentIndex = isCurrent ? timeline.currentLineIndex(at: clock.currentTime) : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(timeline.lines.indices, id: \.self) { index in
                    LyricRow(text: timeline.lines[index], isCurrent: index == currentIndex)
                }
            }
            .scrollTargetLayout()
            .padding()
        }
        .scrollPosition($position, anchor: .center)
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting, .decelerating: isBrowsing = true
            case .idle: isBrowsing = false
            // `.animating` is the sheet's own scroll to the current line.
            default: break
            }
        }
        .onChange(of: currentIndex) { _, index in
            guard let index, !isBrowsing else { return }
            withAnimation { position.scrollTo(id: index, anchor: .center) }
        }
    }
}

/// One lyric line. Its inputs are plain values rather than the clock — the
/// queue's rows follow the same rule — so a tick that leaves the highlight
/// where it was doesn't re-render the row.
private struct LyricRow: View {
    let text: String
    let isCurrent: Bool

    var body: some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
}
