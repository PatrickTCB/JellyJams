import SwiftUI

/// The Downloads section: everything saved for offline playback, presented the
/// way Favourites is — a segmented Songs / Albums / Artists / Playlists picker
/// above a list of downloaded items. Collections open read-only lists of their
/// saved tracks (offline); removing one unreferences its tracks, and only
/// tracks no other download requires disappear.
struct DownloadsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case albums, artists, playlists, songs

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var player: PlayerController
    @State private var tab: Tab = .albums
    @State private var confirmingDeleteAll = false

    private var songs: [BaseItemDto] { downloads.downloadedSongs() }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch tab {
            case .albums: collectionsList(type: .musicAlbum, placeholder: "square.stack")
            case .artists: artistsList
            case .playlists: collectionsList(type: .playlist, placeholder: "music.note.list")
            case .songs: songsList
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) { confirmingDeleteAll = true } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .disabled(downloads.batches.isEmpty == false
                          || (downloads.entries.isEmpty && downloads.collections.isEmpty))
            }
        }
        .alert("Delete all downloaded music?", isPresented: $confirmingDeleteAll) {
            Button("Delete All Downloads", role: .destructive) { downloads.removeAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var songsList: some View {
        List {
            Section {
                ForEach(songs) { song in
                    TrackRow(track: song, showArtwork: true) {
                        player.play(songs, startAt: songs.firstIndex { $0.id == song.id } ?? 0)
                    }
                }
                ForEach(downloads.batches) { batch in
                    BatchRow(batch: batch)
                }
            } header: {
                Text(Format.songCount(songs.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .overlay {
            if songs.isEmpty && downloads.batches.isEmpty {
                ContentUnavailableView("No downloaded songs", systemImage: "music.note")
            }
        }
    }

    /// Artists are derived from the downloaded albums rather than stored, so
    /// downloading any album of an artist surfaces them here.
    private var artistsList: some View {
        let artists = downloads.downloadedArtists()
        return List {
            Section {
                ForEach(artists) { artist in
                    DownloadedItemRow(item: artist, placeholder: "music.mic", subtitle: .albums)
                }
            } header: {
                Text(Format.artistCount(artists.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .overlay {
            if artists.isEmpty {
                ContentUnavailableView("No downloaded artists", systemImage: "music.mic")
            }
        }
    }

    private func collectionsList(type: ItemType, placeholder: String) -> some View {
        List {
            Section {
                ForEach(downloads.downloadedCollections(ofType: type)) { item in
                    DownloadedItemRow(item: item, placeholder: placeholder)
                }
            } header: {
                let count = downloads.downloadedCollections(ofType: type).count
                Text(type == .musicAlbum ? Format.albumCount(count) : Format.playlistCount(count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .overlay {
            if downloads.downloadedCollections(ofType: type).isEmpty {
                ContentUnavailableView("No downloaded \(tab.title.lowercased())", systemImage: placeholder)
            }
        }
    }
}

private struct DownloadedItemRow: View {
    enum Subtitle {
        /// Number of songs saved for the item.
        case songs
        /// Number of downloaded albums attributed to the item (artists, whose
        /// tracks are referenced by album, have no song count of their own).
        case albums
    }

    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var session: SessionStore
    let item: BaseItemDto
    let placeholder: String
    var subtitle: Subtitle = .songs

    private var subtitleText: String {
        switch subtitle {
        case .songs:
            Format.songCount(downloads.tracks(forItemId: item.id ?? "").count)
        case .albums:
            Format.albumCount(downloads.downloadedAlbums(forArtistId: item.id ?? "").count)
        }
    }

    var body: some View {
        Group {
            // Value-based so the push registers in ``LibraryNavigator/path``;
            // the ref resolves to the offline detail, not the online one.
            if let ref = DownloadedCollectionRef(item) {
                NavigationLink(value: ref) { rowContent }
            } else {
                rowContent
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: { downloads.remove(item) }) {
                Label("Remove Download", systemImage: "trash")
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            ArtworkImage(
                url: session.client?.artworkURL(for: item, size: 96),
                cornerRadius: 6,
                placeholderSystemImage: placeholder
            )
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            .buttonStyle(.borderless)
        }
    }
}

private struct BatchRow: View {
    let batch: DownloadStore.Batch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(batch.label).lineLimit(1)
            HStack {
                ProgressView(value: totalProgress)
                Text("\(min(batch.completed + batch.failed, batch.total))/\(batch.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var totalProgress: Double {
        guard batch.total > 0 else { return 0 }
        return Double(batch.completed + batch.failed) / Double(batch.total)
    }
}
