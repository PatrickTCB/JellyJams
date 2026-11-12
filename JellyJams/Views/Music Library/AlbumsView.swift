import SwiftUI

struct AlbumsView: View {
    @Environment(SessionStore.self) private var session
    @Bindable var model: PagedItems

    var body: some View {
        ItemGrid(model: model, emptyMessage: "No albums", emptySystemImage: "square.stack")
            .navigationTitle("Albums")
            .toolbar {
                ToolbarItem {
                    SortMenu(sortBy: $model.sortBy, sortOrder: $model.sortOrder, options: model.sortOptions)
                }
            }
            .refreshToolbarItem { await model.reload() }
            .clearsInitialKeyboardFocus()
            .task(id: model.query) { await model.load(from: session.library) }
            .refreshable { Task {await model.reload() }}
    }
}
