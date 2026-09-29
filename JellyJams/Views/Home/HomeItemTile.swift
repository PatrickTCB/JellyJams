import SwiftUI

/// One tile in a home row: the standard grid cell at a fixed size. It
/// navigates through the library stack unless `onSelect` replaces the tap
/// action, the way station tiles play instead of opening.
struct HomeItemTile: View {
    static let width: CGFloat = 150

    let item: BaseItemDto
    var title: String?
    var onSelect: ((BaseItemDto) -> Void)?

    var body: some View {
        Group {
            if let onSelect {
                Button { onSelect(item) } label: { cell }
            } else {
                NavigationLink(value: item) { cell }
            }
        }
        .buttonStyle(.plain)
        .frame(width: Self.width)
    }

    private var cell: some View {
        ItemGridCell(item: item, title: title)
    }
}