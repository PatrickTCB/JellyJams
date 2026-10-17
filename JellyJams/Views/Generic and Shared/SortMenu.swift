import SwiftUI

/// What a ``SortMenu`` offers: a picker-taggable value that names itself.
/// `SortBy` covers every server-side sort; lists that sort locally conform
/// with their own cases, such as the Downloads lists' recency.
protocol SortOption: Hashable {
    var displayName: String { get }
}

extension SortBy: SortOption {}

/// A toolbar sort control: pick a field and toggle ascending/descending.
struct SortMenu<Option: SortOption>: View {
    @Binding var sortBy: Option
    @Binding var sortOrder: SortOrder
    var options: [Option]

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sortBy) {
                ForEach(options, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            Divider()
            Picker("Order", selection: $sortOrder) {
                Label("Ascending", systemImage: "arrow.up").tag(SortOrder.ascending)
                Label("Descending", systemImage: "arrow.down").tag(SortOrder.descending)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}
