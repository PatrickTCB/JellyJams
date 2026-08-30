import SwiftUI

/// A compact navigation row with artwork, title and subtitle. Used by the
/// search results and the genre screen, which present the same mix of artists,
/// albums and genres.
struct ItemRow: View {
    let item: BaseItemDto
    var circular = false
    var placeholderSystemImage = "square.stack"

    @EnvironmentObject private var session: SessionStore

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(
                url: session.library.artworkURL(for: item, size: 96),
                cornerRadius: circular ? 500 : 6,
                placeholderSystemImage: placeholderSystemImage
            )
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1)
                if let subtitle = item.subtitleArtist {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
