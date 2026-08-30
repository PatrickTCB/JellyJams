import SwiftUI

/// A detail-screen header for collections shown as album grids (artists,
/// genres): artwork, title, subtitle and Play/Shuffle actions.
struct CollectionHeader: View {
    let item: BaseItemDto
    var subtitle: String?
    var isCircular = false
    var canPlay: Bool
    var onPlay: () -> Void
    var onShuffle: () -> Void

    @EnvironmentObject private var session: SessionStore

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
        ArtworkImage(
            url: session.library.artworkURL(for: item, size: 500),
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
