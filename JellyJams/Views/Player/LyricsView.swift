import SwiftUI

/// The current track's lyrics, fetched from the server's
/// `/Audio/{itemId}/Lyrics` endpoint and read off as one line per row.
///
/// Opened by the music.microphone button in the now playing screen — the same
/// sheet shape as the queue's: its own sheet, a "Done" to dismiss it, and the
/// lines it holds while they load.
struct LyricsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    @State private var lyrics: LyricDto?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    content()
                }
                .onAppear { scrollToTop(using: proxy) }
                .onChange(of: lyrics) { scrollToTop(using: proxy) }
                .padding()
            }
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
        .overlay {
            // One fetch at a time: the button that started it shows the wait.
            if isLoading {
                ProgressView("Loading lyrics…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task { await loadLyrics() }
    }

    // MARK: - Content

    /// Whatever the sheet holds: the lines once they arrive, the refusal when
    /// they don't, or the empty case when the server had none.
    @ViewBuilder
    private func content() -> some View {
        if errorMessage != nil {
            errorView()
        } else if !lyricRows.isEmpty {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(lyricRows) { row in
                    Text(row.text)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView("No Lyrics", systemImage: "music.microphone")
        }
    }

    private func errorView() -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
            Text(errorMessage ?? "The server couldn’t load these lyrics.")
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
    }

    /// One display row per lyric line the server sent, in its order, dropping
    /// the blank and untexted lines.
    private var lyricRows: [LyricRow] {
        guard let fetched = lyrics, let lines = fetched.lyrics else { return [] }
        var rows: [LyricRow] = []
        for (index, line) in lines.enumerated() {
            guard let text = line.text, !text.isEmpty else { continue }
            rows.append(LyricRow(id: index, text: text))
        }
        return rows
    }

    // MARK: - Requesting

    /// `GET /Audio/{itemId}/Lyrics` for the current track, and the sheet's
    /// whole state: a fetch in flight, the answer, or the words refused to
    /// come.
    private func loadLyrics() async {
        guard let client = session.client, let item = player.currentItem else {
            errorMessage = JellyfinError.notAuthenticated.errorDescription
            return
        }
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                lyrics = try await client.lyrics(for: item)
            } catch where !error.isCancellation {
                errorMessage = error.userFacingMessage
            } catch {}
        }
    }

    /// Scrolls the lyrics back to the top — the sheet's start position, the
    /// analogue of the queue's scroll-to-current. Runs once the lines exist
    /// to scroll to, and again whenever they arrive.
    private func scrollToTop(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            // Let the ScrollView lay out its rows before scrolling.
            try? await Task.sleep(for: .milliseconds(50))
            if let firstRow = lyricRows.first {
                proxy.scrollTo(firstRow.id, anchor: .top)
            }
        }
    }
}

/// A display row: a lyric line's text, keyed by its position in the fetched
/// lines so the sheet's scroll can find it again.
private struct LyricRow: Identifiable {
    let id: Int
    let text: String
}
