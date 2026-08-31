import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject var model: PagedItems

    var body: some View {
        ItemGrid(model: model, minCellWidth: 150, emptyMessage: "No artists", emptySystemImage: "music.mic")
            .navigationTitle("Artists")
            .toolbar {
                ToolbarItem {
                    Button {
                        model.sortOrder = model.sortOrder.toggled
                    } label: {
                        Label("Order", systemImage: model.sortOrder == .ascending ? "arrow.down" : "arrow.up")
                    }
                }
            }
            .refreshToolbarItem { await model.reload() }
            .task(id: model.query) { await model.load(from: session.library) }
            .refreshable { Task {await model.reload() }}
    }
}
