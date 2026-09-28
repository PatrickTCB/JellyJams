import SwiftUI

/// Chooses what an open-ended play request starts: the item Siri plays for
/// "play some music" and the system play button starts when nothing is
/// queued, plus its shuffle and repeat settings.
///
/// Unset means the built-in favourites shuffle, which stays pinned at the top
/// of the sheet so it is always one tap away. Items are found with the same
/// literal server search the library uses; picking one stores its id, kind
/// and title (``DefaultPlaybackSetting``), and ``DefaultPlaybackResolver``
/// rehydrates the tracks at play time.
struct DefaultPlaybackSettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results = SearchResults()
    @State private var isSearching = false
    @State private var searchFailed = false

    struct SearchResults: Equatable {
        var playlists: [BaseItemDto] = []
        var artists: [BaseItemDto] = []
        var albums: [BaseItemDto] = []
        var songs: [BaseItemDto] = []

        var isEmpty: Bool { playlists.isEmpty && artists.isEmpty && albums.isEmpty && songs.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                currentSection
                resultsSections
            }
            .navigationTitle("Default Playback")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Songs, albums, artists, playlists")
            .task(id: query) { await runSearch() }
            .overlay { overlay }
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    // MARK: Current selection

    private var currentSection: some View {
        Section {
            Button {
                preferences.defaultPlayback = nil
            } label: {
                HStack {
                    Label("Favourite Songs", systemImage: "star.fill")
                    Spacer()
                    if preferences.defaultPlayback == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }

            if let setting = preferences.defaultPlayback {
                LabeledContent("Default", value: "\(setting.title) (\(setting.kind.label))")
                Toggle("Shuffle", isOn: shuffleBinding)
                Picker("Repeat", selection: repeatBinding) {
                    Text("Off").tag(RepeatMode.repeatNone)
                    Text("All").tag(RepeatMode.repeatAll)
                    Text("One").tag(RepeatMode.repeatOne)
                }
                Button("Reset to Favourite Songs", role: .destructive) {
                    preferences.defaultPlayback = nil
                }
            }
        } header: {
            Text("Current")
        } footer: {
            Text("What Siri starts for \"play some music\" requests, and what the play button starts when nothing is queued. An artist's catalogue always shuffles.")
        }
    }

    private var shuffleBinding: Binding<Bool> {
        Binding(
            get: { preferences.defaultPlayback?.shuffle ?? false },
            set: { preferences.defaultPlayback?.shuffle = $0 }
        )
    }

    private var repeatBinding: Binding<RepeatMode> {
        Binding(
            get: { preferences.defaultPlayback?.repeatMode ?? .repeatNone },
            set: { preferences.defaultPlayback?.repeatMode = $0 }
        )
    }

    // MARK: Search results

    @ViewBuilder private var resultsSections: some View {
        if !results.playlists.isEmpty {
            resultSection("Playlists", items: results.playlists, kind: .playlist, placeholder: "music.note.list")
        }
        if !results.artists.isEmpty {
            resultSection("Artists", items: results.artists, kind: .artist, circular: true, placeholder: "music.mic")
        }
        if !results.albums.isEmpty {
            resultSection("Albums", items: results.albums, kind: .album, placeholder: "square.stack")
        }
        if !results.songs.isEmpty {
            resultSection("Songs", items: results.songs, kind: .song, placeholder: "music.note")
        }
    }

    private func resultSection(
        _ header: String,
        items: [BaseItemDto],
        kind: DefaultPlaybackSetting.Kind,
        circular: Bool = false,
        placeholder: String
    ) -> some View {
        Section(header) {
            ForEach(items, id: \.id) { item in
                Button {
                    select(item, kind: kind)
                } label: {
                    HStack {
                        ItemRow(item: item, circular: circular, placeholderSystemImage: placeholder)
                        Spacer()
                        if preferences.defaultPlayback?.itemId == item.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(item.id == nil)
            }
        }
    }

    private func select(_ item: BaseItemDto, kind: DefaultPlaybackSetting.Kind) {
        guard let id = item.id else { return }
        preferences.defaultPlayback = DefaultPlaybackSetting(
            kind: kind,
            itemId: id,
            title: item.displayName,
            shuffle: kind == .artist || kind == .playlist,
            repeatMode: .repeatNone
        )
    }

    // MARK: Search plumbing

    @ViewBuilder private var overlay: some View {
        if searchFailed {
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "exclamationcircle.triangle")
            } actions: {
                Button("Try Again") { Task { await runSearch() } }
            }
        } else if isSearching && results.isEmpty {
            ProgressView()
        }
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear first: the previous term's results are not an answer to this
        // one, and resetting is what puts a spinner up during the debounce.
        results = SearchResults()
        searchFailed = false
        guard !term.isEmpty else { return }

        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        guard let client = session.client else { return }

        isSearching = true
        defer { isSearching = false }
        do {
            async let playlists = client.getItems(
                includeItemTypes: [.playlist], mediaTypes: [.audio], recursive: true, searchTerm: term, limit: 5
            )
            async let artists = client.getAlbumArtists(searchTerm: term, limit: 8)
            async let albums = client.getItems(
                includeItemTypes: [.musicAlbum], recursive: true, searchTerm: term, limit: 10
            )
            async let songs = client.getItems(
                includeItemTypes: [.audio], recursive: true, searchTerm: term, limit: 20
            )
            let (playlistItems, artistItems, albumItems, songItems) = try await (playlists, artists, albums, songs)
            results = SearchResults(
                playlists: playlistItems.items ?? [],
                artists: artistItems.items ?? [],
                albums: albumItems.items ?? [],
                songs: songItems.items ?? []
            )
        } catch {
            searchFailed = true
        }
    }
}
