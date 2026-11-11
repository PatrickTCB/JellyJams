import SwiftUI

/// The current track's lyrics, read along with the song: one line per row,
/// with the line being sung highlighted and kept in view.
///
/// Raised by the lyrics button in the now playing screen, in the queue's sheet
/// shape — its own navigation bar and a "Done" to dismiss it. It follows the
/// player rather than the track it was opened on, so a track change while it
/// is open brings up the new track's lyrics.
struct LyricsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    @StateObject private var loader = LoadableModel(LyricTimeline())

    private var timeline: LyricTimeline { loader.value }

    var body: some View {
        NavigationStack {
            LyricLines(timeline: timeline)
                // A new track's lines start from the top, not from wherever
                // the last track's were scrolled to.
                .id(player.currentItem?.id)
                .overlay { overlay }
                .navigationTitle("Lyrics")
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
        .task(id: player.currentItem?.id) {
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
        let item = player.currentItem
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

    @EnvironmentObject private var clock: PlaybackClock
    @State private var position = ScrollPosition(idType: Int.self)
    /// Set while the listener scrolls the lines by hand, so following the
    /// song doesn't drag them back mid-gesture. Following picks up again at
    /// the next line once they let go.
    @State private var isBrowsing = false

    var body: some View {
        let currentIndex = timeline.currentLineIndex(at: clock.currentTime)
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
