import SwiftUI

/// A toolbar sort control: pick a field and toggle ascending/descending.
struct SortMenu: View {
    @Binding var sortBy: SortBy
    @Binding var sortOrder: SortOrder
    var options: [SortBy]

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sortBy) {
                ForEach(options) { option in
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
