import SwiftUI

/// The last tile in a home row: opens the row's library section, so a row that
/// teases a few items ends in a way through to the rest of them.
///
/// Styled to sit among the tiles it follows: an artwork-sized square carrying
/// the section's own symbol on the same fill ``ArtworkImage``'s placeholder
/// uses, with the usual title treatment under it.
struct BrowseMoreTile: View {
    let section: LibrarySection

    var body: some View {
        NavigationLink(value: section) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: section.systemImage)
                        .font(.system(size: HomeItemTile.width * 0.32))
                        .foregroundStyle(.secondary)
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)

                Text("Browse more")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: HomeItemTile.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browse more \(section.title)")
    }
}
