import SwiftUI

/// A horizontally scrolling row of home tiles. Scrolling the row itself keeps
/// a long pin list or ten recent albums from squeezing the tiles narrower.
struct HomeItemRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder var content: (Item) -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(items) { item in
                    content(item)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
}