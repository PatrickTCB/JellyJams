import SwiftUI

/// Icon-only favourite toggle with optimistic UI. Reverts on failure.
///
/// State and the server write both live in ``FavouriteStore``, so every button
/// showing the same item agrees, and a change survives this view being rebuilt.
struct FavouriteButton: View {
    let item: BaseItemDto
    #if os(macOS)
    var size: Font = .title2
    #else
    var size: Font = .body
    #endif

    @EnvironmentObject private var favourites: FavouriteStore

    private var isFavourite: Bool { favourites.isFavourite(item) }

    var body: some View {
        Button { favourites.toggle(item) } label: {
            Image(systemName: isFavourite ? "heart.fill" : "heart")
                .font(size)
                .foregroundStyle(isFavourite ? .accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        #if os(iOS)
        .buttonStyle(.borderless)
        #else
        .buttonStyle(.bordered)
        #endif
        .disabled(favourites.isBusy(item))
        .help(isFavourite ? "Remove from Favourites" : "Add to Favourites")
        .accessibilityLabel(isFavourite ? "Remove from Favourites" : "Add to Favourites")
    }
}
