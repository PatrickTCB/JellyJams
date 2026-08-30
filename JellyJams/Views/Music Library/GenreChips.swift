import SwiftUI

/// The "Genres" section shown at the foot of an album or artist screen. Each
/// chip opens ``GenreResultsView`` for that genre.
///
/// Renders nothing when the item has no genres, so callers can include it
/// unconditionally.
struct GenreChips: View {
    let genres: [GenreRef]
    @EnvironmentObject private var navigator: LibraryNavigator

    var body: some View {
        if !genres.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Genres")
                    .font(.title2.bold())
                FlowLayout(spacing: 8) {
                    ForEach(genres) { genre in
                        // A plain Button pushing through ``LibraryNavigator``
                        // for the same reason as the tiles in
                        // ``SimilarItemsSection``: these chips render inside a
                        // single `List` row on the album/playlist screen, where
                        // a `NavigationLink` would make the whole row one tap
                        // target that opens only the last chip.
                        Button {
                            navigator.open(genre)
                        } label: {
                            chip(genre.name)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Browse \(genre.name)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ name: String) -> some View {
        Text(name)
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
    }
}
