import SwiftUI

/// A paginated, adaptive grid of items (albums, artists, playlists, genres).
/// Each cell navigates directly through ``ItemDetailRouter``.
struct ItemGrid: View {
    @ObservedObject var model: PagedItems
    var minCellWidth: CGFloat = 160
    var emptyMessage = "Nothing here yet"
    var emptySystemImage = "music.note"
    /// Replaces navigation as the tap action, for a grid whose items are not
    /// opened but acted on — the AI Radio stations, which start playing.
    var onSelect: ((BaseItemDto) -> Void)?
    /// Replaces each cell's title, for a grid that calls its items something
    /// other than what the server named them. See ``ItemGridCell/title``.
    var title: ((BaseItemDto) -> String)?

    var body: some View {
        ScrollView {
            if let error = model.errorMessage, model.isEmpty {
                LoadFailureOverlay(message: error) {
                    await model.reload()
                    return model.errorMessage == nil
                }
                .padding(.top, 60)
            } else {
                Section {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: minCellWidth), spacing: 16)],
                        spacing: 20
                    ) {
                        ForEach(model.items) { item in
                            cell(for: item)
                                .buttonStyle(.plain)
                                .task { await model.loadMoreIfNeeded(item) }
                        }
                    }
                    .padding()
                } header: {
                    Text("\(model.total) items")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if model.isLoading {
                    ProgressView().padding(.vertical, 24)
                } else if let error = model.errorMessage, !model.isEmpty {
                    VStack(spacing: 8) {
                        Label("Couldn’t load more items", systemImage: "wifi.exclamationmark")
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") { Task { await model.loadNextPage() } }
                    }
                    .padding()
                }
            }
        }
        .overlay {
            if model.hasLoadedOnce, model.isEmpty, !model.isLoading, model.errorMessage == nil {
                ContentUnavailableView(emptyMessage, systemImage: emptySystemImage)
            }
        }
        .gridRefreshAction { await model.reload() }
    }

    @ViewBuilder private func cell(for item: BaseItemDto) -> some View {
        if let onSelect {
            Button { onSelect(item) } label: { ItemGridCell(item: item, title: title?(item)) }
        } else {
            NavigationLink(value: item) { ItemGridCell(item: item, title: title?(item)) }
        }
    }
}
