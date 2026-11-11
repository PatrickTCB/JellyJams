import SwiftUI

/// Owns the push stack for one navigation column and opens library items and
/// genres by appending to it.
///
/// The suggestion tiles in ``SimilarItemsSection`` and the chips in
/// ``GenreChips`` open items through this rather than a `NavigationLink`. Both
/// sit inside a single `List` row on the album screen, and a
/// `List` gives every `NavigationLink` in a row the whole-row treatment —
/// collapsing a grid of them into one tap target and, on iOS, stamping each
/// tile with a disclosure chevron. A plain `Button` calling ``open(_:)`` gets
/// none of that, and because the push is an imperative edit to ``path`` it also
/// survives the row reloading its contents (which would otherwise cancel a
/// `NavigationLink` mid-tap).
@MainActor
final class LibraryNavigator: ObservableObject {
    @Published var path = NavigationPath()

    func open(_ item: BaseItemDto) { path.append(item) }
    func open(_ genre: GenreRef) { path.append(genre) }
}

/// A `NavigationStack` bound to its own ``LibraryNavigator`` so every column
/// keeps an independent back stack.
///
/// Detail navigation across the app is value-based (`NavigationLink(value:)`)
/// and resolves through the single destinations registered here, so the whole
/// app pushes onto this one ``LibraryNavigator/path``.
///
/// The navigator is injected on the `NavigationStack` itself, not on its
/// root: environment set inside the stack stays with the root view, while
/// environment set on the stack reaches every screen it pushes — which is what
/// lets ``SimilarItemsSection``, ``GenreChips`` and the row menus push from a
/// pushed screen too.
struct LibraryNavigationStack<Root: View>: View {
    @ViewBuilder var root: () -> Root
    @StateObject private var navigator = LibraryNavigator()

    var body: some View {
        NavigationStack(path: $navigator.path) {
            root()
                .libraryNavigationDestinations()
                #if os(iOS)
                .nowPlayingTabContentDock()
                #endif
        }
        .environmentObject(navigator)
    }
}
