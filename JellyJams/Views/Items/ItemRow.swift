import SwiftUI

/// A compact navigation row with artwork, title and subtitle. Used by the
/// search results and the genre screen, which present the same mix of artists,
/// albums and genres.
struct ItemRow: View {
    let item: BaseItemDto
    var circular = false
    var placeholderSystemImage = "square.stack"

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.offlineBrowsing) private var offlineBrowsing

    /// Downloaded artwork comes from disk and is never re-requested; see
    /// ``ArtworkImage`` and ``DownloadStore/localArtworkURL(for:)``.
    private var localArtworkURL: URL? { downloads.localArtworkURL(for: item) }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(
                url: offlineBrowsing ? nil : session.library.artworkURL(for: item, size: 96),
                localURL: localArtworkURL,
                cornerRadius: circular ? 500 : 6,
                placeholderSystemImage: placeholderSystemImage
            )
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1)
                if let subtitle = item.subtitleAlbumArtist {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
