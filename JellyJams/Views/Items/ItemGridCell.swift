import SwiftUI

/// A square (or circular, for artists) artwork tile with a title and subtitle,
/// used across the album/artist/playlist/genre grids.
struct ItemGridCell: View {
    let item: BaseItemDto

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var favourites: FavouriteStore

    private var isArtist: Bool { item.itemType == .musicArtist }

    private var subtitle: String? {
        switch item.itemType {
        case .musicAlbum:
            return item.subtitleArtist
        case .musicArtist:
            return nil
        case .playlist:
            return item.childCount.map { Format.songCount($0) }
        case let type? where type.isGenre:
            return item.childCount.map { Format.songCount($0) }
        default:
            return item.subtitleArtist
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(
                url: session.library.artworkURL(for: item, size: 320),
                cornerRadius: isArtist ? 500 : 6,
                placeholderSystemImage: isArtist ? "music.mic" : "record.circle.fill"
            )
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)

            HStack(spacing: 4) {
                if isArtist { Spacer(minLength: 0) }
                Text(item.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                if favourites.isFavourite(item) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Favourite")
                }
                Spacer(minLength: 0)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .itemContextMenu(for: item)
    }
}
