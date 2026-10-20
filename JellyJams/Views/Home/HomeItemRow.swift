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
