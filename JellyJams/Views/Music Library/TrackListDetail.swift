import SwiftUI

/// Shared layout for a "collection of tracks" detail screen (an album or a
/// playlist): a large header with artwork, metadata and Play/Shuffle actions,
/// followed by the track list.
struct TrackListDetail: View {
    let headerItem: BaseItemDto
    var subtitle: String?
    var showArtworkInRows = false
    /// Opt-in so playlists, which are user-assembled and carry no genre tags of
    /// their own, don't grow an empty section.
    var showsGenres = false
    /// Opt-in for the same reason: Jellyfin has no "similar playlists" notion,
    /// only `/Albums/{id}/Similar`.
    var showsSimilarAlbums = false

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @StateObject private var loader = LoadableModel<[BaseItemDto]>([])
    /// Measured here rather than inside the row so the suggestion row can
    /// render nothing when it has nothing, and still know how much to ask for.
    @State private var contentWidth: CGFloat = 0

    private var tracks: [BaseItemDto] { loader.value }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            if let errorMessage = loader.errorMessage, tracks.isEmpty {
                LoadFailureView(message: errorMessage) { await reload() }
                    .listRowSeparator(.hidden)
            } else if loader.isPending, tracks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    // Keyed by the track's own id rather than its position: a
                    // reload that reorders or replaces the list must carry each
                    // row's state (the current-track highlight, a swipe in
                    // progress) with the track, not leave it on row 3.
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, showArtwork: showArtworkInRows) {
                            player.play(tracks, startAt: index)
                        }
                    }
                }
            }

            if showsGenres {
                Section {
                    GenreChips(genres: headerItem.genreRefs)
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                        .listRowSeparator(.hidden)
                }
            }

            if showsSimilarAlbums {
                // No wrapper view here: `listRowInsets` and `listRowSeparator`
                // only apply to a row's top-level view, so a stack around this
                // would swallow both and the row would keep its default insets
                // and separator.
                SimilarItemsSection(
                    kind: .albums,
                    item: headerItem,
                    availableWidth: contentWidth,
                    contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .navigationTitle(headerItem.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem { FavouriteButton(item: headerItem) } }
        .task(id: headerItem.id) { await reload() }
        .refreshable { await reload() }
        #if os(iOS)
        .nowPlayingTabContentDock()
        #endif
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                artwork.frame(width: 180, height: 180)
                info(alignment: .leading)
                Spacer(minLength: 0)
            }
            VStack(spacing: 16) {
                artwork.frame(maxWidth: 240)
                info(alignment: .center)
            }
        }
    }

    private var artwork: some View {
        ArtworkImage(
            url: session.library.artworkURL(for: headerItem, size: 500),
            cornerRadius: 8,
            placeholderSystemImage: headerItem.itemType == .playlist ? "music.note.list" : "square.stack"
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    private func info(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(headerItem.displayName)
                .font(.title.bold())
                .lineLimit(3)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(metaLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            actions
                .padding(.top, 6)
        }
        .frame(maxWidth: alignment == .center ? .infinity : nil,
               alignment: alignment == .center ? .center : .leading)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(tracks.isEmpty)

            Button {
                player.play(tracks, shuffled: true)
            } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(.bordered)
            .disabled(tracks.isEmpty)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = headerItem.productionYear { parts.append(String(year)) }
        let count = tracks.isEmpty ? headerItem.childCount : tracks.count
        parts.append(Format.songCount(count))
        let total = tracks.compactMap(\.runtimeSeconds).reduce(0, +)
        if total > 0 { parts.append(Format.duration(total)) }
        return parts.joined(separator: " • ")
    }

    // MARK: - Loading

    private func reload() async {
        await loader.load { try await session.library.tracks(for: headerItem) }
    }
}
