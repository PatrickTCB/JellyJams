import SwiftUI

struct ArtistsView: View {
    @Environment(SessionStore.self) private var session
    let model: PagedItems

    var body: some View {
        ItemGrid(model: model, minCellWidth: 150 * ArtworkImage.sizeMultiplier, emptyMessage: "No artists", emptySystemImage: "music.mic")
            .navigationTitle("Artists")
            .tvScrollingBar(title: "Artists") { orderButton }
            .toolbar {
                ToolbarItem {
                    orderButton
                }
            }
            .refreshToolbarItem { await model.reload() }
            .task(id: model.query) { await model.load(from: session.library) }
            .refreshable { Task {await model.reload() }}
    }

    private var orderButton: some View {
        Button {
            model.sortOrder = model.sortOrder.toggled
        } label: {
            Label("Order", systemImage: model.sortOrder == .ascending ? "arrow.down" : "arrow.up")
        }
    }
}
