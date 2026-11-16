import SwiftUI

/// A detail-screen header for a collection whose page is an album grid — the
/// artist pages, online and downloaded: artwork, title, subtitle and
/// Play/Shuffle actions, plus Instant Mix when online.
struct CollectionHeader: View {
    let item: BaseItemDto
    var subtitle: String?
    var isCircular = false
    /// A saved artwork file the caller resolved itself, for an item whose own
    /// keys cannot find it — a downloaded artist, whose group resolves its
    /// picture (or borrowed album cover) through keys the stand-in item does
    /// not carry. `nil` (the default) resolves for `item` as usual.
    var localArtworkURL: URL? = nil
    var canPlay: Bool
    var onPlay: () -> Void
    var onShuffle: () -> Void
    /// The hosting page's wrap-to-top focus target, bound to the Play button
    /// on tvOS so the remote's focus wrap has somewhere to land. Nil leaves
    /// the button unbound; other platforms never read it.
    var topFocus: FocusState<Bool>.Binding?

    @Environment(SessionStore.self) private var session
    @Environment(DownloadStore.self) private var downloads
    /// Downloaded content never builds a server artwork request.
    @Environment(\.offlineBrowsing) private var offlineBrowsing

    /// Downloaded artwork comes from disk and is never re-requested; see
    /// ``ArtworkImage`` and ``DownloadStore/localArtworkURL(for:)``.
    private var artworkFileURL: URL? { localArtworkURL ?? downloads.localArtworkURL(for: item) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                artwork.frame(width: 160, height: 160)
                info(alignment: .leading)
                Spacer(minLength: 0)
            }
            VStack(spacing: 16) {
                artwork.frame(width: 200, height: 200)
                info(alignment: .center)
            }
        }
    }

    private var artwork: some View {
        return ArtworkImage(
            url: offlineBrowsing ? nil : session.library.artworkURL(for: item, size: 500),
            localURL: artworkFileURL,
            cornerRadius: isCircular ? 500 : 8,
            placeholderSystemImage: isCircular ? "music.mic" : "guitars"
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    @ViewBuilder private var playButton: some View {
        let button = Button(action: onPlay) {
            Image(systemName: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canPlay)
        #if os(tvOS)
        if let topFocus {
            button.focused(topFocus)
        } else {
            button
        }
        #else
        button
        #endif
    }

    private func info(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 8) {
            Text(item.displayName)
                .font(.largeTitle.bold())
                .lineLimit(3)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                playButton

                Button(action: onShuffle) {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.bordered)
                .disabled(!canPlay)

                // Renders nothing for a downloaded artist: instant mix is
                // server-only.
                InstantMixButton(item: item)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)

                FavouriteButton(item: item, size: .title2)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: alignment == .center ? .infinity : nil,
               alignment: alignment == .center ? .center : .leading)
    }
}
