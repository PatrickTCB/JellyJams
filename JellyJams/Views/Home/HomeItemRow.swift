import SwiftUI

/// A horizontally scrolling row of home tiles. Scrolling the row itself keeps
/// a long pin list or ten recent albums from squeezing the tiles narrower.
///
/// `trailing` rides inside the scroll, after the last tile — the rows that
/// tease a library section end with the ``BrowseMoreTile`` that opens it.
struct HomeItemRow<Item: Identifiable, Content: View, Trailing: View>: View {
    let items: [Item]
    var content: (Item) -> Content
    var trailing: () -> Trailing

    init(
        items: [Item],
        @ViewBuilder content: @escaping (Item) -> Content,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.items = items
        self.content = content
        self.trailing = trailing
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(items) { item in
                    content(item)
                }
                trailing()
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
}

extension HomeItemRow where Trailing == EmptyView {
    init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.init(items: items, content: content) { EmptyView() }
    }
}

/// The same row, made drag-to-reorder with SwiftUI's reordering API — the
/// tiles are `.reorderable()` inside a `.reorderContainer`. A tile lifts
/// with a long-press and drag on iOS, or a click and drag on macOS, and the
/// other tiles shift out of its way. Dropping it hands `move` the tile's
/// item and the index it landed at, counted against `items` as the drag
/// found them: the index means "before the item currently there", and
/// `items.count` means the end of the row. A drop that changes nothing can
/// be ignored.
///
/// (A `dropDestination` on the `ForEach` is an insert action, not a
/// reorder. SwiftUI never delivers this row's drags to it, so every
/// dropped tile springs back.)
///
/// The reordering API needs macOS 27, so on earlier macOS versions this is
/// the plain row and its order is fixed.
///
/// It is a sibling of ``HomeItemRow`` rather than a mode of it because
/// `.reorderable()` must sit on the `ForEach` itself — SwiftUI's list
/// identity only survives the chain when the modifier is unconditional —
/// so rows that do not reorder keep the plain type untouched. Keep both
/// bodies' layout in step.
struct ReorderableHomeItemRow<Item: Identifiable, Content: View>: View where Item.ID: Sendable {
    let items: [Item]
    var move: (Item, Int) -> Void
    var content: (Item) -> Content

    init(
        items: [Item],
        move: @escaping (Item, Int) -> Void,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.move = move
        self.content = content
    }

    var body: some View {
        if #available(macOS 27, *) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        // The stack makes every tile a single view. A tile
                        // whose body opens with an `if` or `switch` — as
                        // HomeItemTile and PinnedItemsSection's tiles do —
                        // otherwise crashes SwiftUI as the drag lifts
                        // ("Unexpected identifier type"). `.id`, `.frame`
                        // and other modifiers distribute over the branches
                        // and do not help; `AnyView` crashes too.
                        ZStack {
                            content(item)
                        }
                    }
                    .reorderable()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .reorderContainer(for: Item.self) { difference in
                // The API declares this closure nonisolated, but a drop is a
                // UI event on the main actor.
                MainActor.assumeIsolated {
                    moveTile(within: difference)
                }
            }
        } else {
            HomeItemRow(items: items, content: content)
        }
    }

    /// The reordering API's drop, translated for `move`: the dragged tile's
    /// item, and the index of the tile it landed before.
    @available(macOS 27, *)
    private func moveTile(within difference: ReorderDifference<Item.ID, ReorderableSingleCollectionIdentifier>) {
        // Tiles move one at a time.
        guard let id = difference.sources.first,
              let item = items.first(where: { $0.id == id }) else { return }
        let index = switch difference.destination.position {
        case .before(let anchor): items.firstIndex { $0.id == anchor } ?? items.count
        case .end: items.count
        }
        move(item, index)
    }
}
