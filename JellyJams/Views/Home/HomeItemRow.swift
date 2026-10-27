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

/// The same row, made drag-to-reorder: every tile lifts the payload built
/// from its item, and one drop destination over the row resolves a drop to
/// the index it lands at — long-press and drag on iOS, click and drag on
/// macOS, with the system shifting tiles out of the way and animating the
/// moved tile into its new place. `drop` asks the model to move the payload
/// and reports whether the order changed; a drop that changes nothing just
/// lets the tile spring back.
///
/// It is a sibling of ``HomeItemRow`` rather than a mode of it because the
/// reordering modifiers must sit on the `ForEach` itself — SwiftUI's list
/// identity only survives the chain when the modifier is unconditional —
/// so rows that do not reorder keep the plain type untouched. Keep both
/// bodies' layout in step.
struct ReorderableHomeItemRow<Item: Identifiable, Payload: Transferable, Content: View>: View {
    let items: [Item]
    var payload: (Item) -> Payload
    var drop: (Payload, Int) -> Bool
    var content: (Item) -> Content

    init(
        items: [Item],
        payload: @escaping (Item) -> Payload,
        drop: @escaping (Payload, Int) -> Bool,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.payload = payload
        self.drop = drop
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(items) { item in
                    content(item)
                        .draggable(payload(item))
                }
                .dropDestination(for: Payload.self) { payloads, index in
                    guard let payload = payloads.first else { return }
                    _ = withAnimation(.snappy) {
                        drop(payload, index)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
}
