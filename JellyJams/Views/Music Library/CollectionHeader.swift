import SwiftUI

/// A detail-screen header for a collection whose page is an album grid — the
/// artist pages, online and downloaded: artwork, title, subtitle and
/// Play/Shuffle actions.
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

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var downloads: DownloadStore
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
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPlay)

                Button(action: onShuffle) {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.bordered)
                .disabled(!canPlay)

                FavouriteButton(item: item, size: .title2)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: alignment == .center ? .infinity : nil,
               alignment: alignment == .center ? .center : .leading)
    }
}
