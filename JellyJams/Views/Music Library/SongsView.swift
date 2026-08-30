import SwiftUI

struct SongsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @ObservedObject var model: PagedItems

    var body: some View {
        List {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, showArtwork: true) {
                    player.play(model.items, startAt: index)
                }
                .task { await model.loadMoreIfNeeded(track) }
            }
            if model.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            } else if let error = model.errorMessage, !model.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn’t load more songs", systemImage: "wifi.exclamationmark")
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.loadNextPage() } }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Songs")
        .overlay {
            if let error = model.errorMessage, model.isEmpty {
                LoadFailureView(title: "Couldn’t Load Songs", message: error) { await model.reload() }
            } else if model.hasLoadedOnce, model.isEmpty, !model.isLoading {
                ContentUnavailableView("No songs", systemImage: "music.note")
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    player.play(model.items, shuffled: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .disabled(model.isEmpty)
            }
            ToolbarItem {
                SortMenu(sortBy: $model.sortBy, sortOrder: $model.sortOrder, options: model.sortOptions)
            }
        }
        .refreshToolbarItem { await model.reload() }
        .task(id: model.query) { await model.load(from: session.library) }
        .refreshable { await model.reload() }
    }
}
