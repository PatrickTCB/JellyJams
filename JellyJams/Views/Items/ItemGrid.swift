import SwiftUI

/// A paginated, adaptive grid of items (albums, artists, playlists, genres).
/// Each cell navigates directly through ``ItemDetailRouter``.
struct ItemGrid: View {
    @ObservedObject var model: PagedItems
    var minCellWidth: CGFloat = 160
    var emptyMessage = "Nothing here yet"
    var emptySystemImage = "music.note"

    var body: some View {
        ScrollView {
            if let error = model.errorMessage, model.isEmpty {
                LoadFailureView(message: error) { await model.reload() }
                    .padding(.top, 60)
            } else {
                Section {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: minCellWidth), spacing: 16)],
                        spacing: 20
                    ) {
                        ForEach(model.items) { item in
                            NavigationLink(value: item) {
                                ItemGridCell(item: item)
                            }
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
    }
}
