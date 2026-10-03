import SwiftUI

/// Shared layout for a "collection of tracks" detail screen (an album or a
/// playlist): a large header with artwork, metadata and Play/Shuffle actions,
/// followed by the track list.
struct TrackListDetail: View {
    let headerItem: BaseItemDto
    var subtitle: String?
    /// The library item the subtitle names (the album's artist), so it can be
    /// pushed. Nil for callers with a plain-text subtitle or none.
    var subtitleItem: BaseItemDto?
    var showArtworkInRows = false
    /// Opt-in so playlists, which are user-assembled and carry no genre tags of
    /// their own, don't grow an empty section.
    var showsGenres = false
    /// Opt-in for the same reason: Jellyfin has no "similar playlists" notion,
    /// only `/Albums/{id}/Similar`.
    var showsSimilarAlbums = false
    var downloaded = false
    
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var navigator: LibraryNavigator
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var player: PlayerController
    @StateObject private var loader = LoadableModel<[BaseItemDto]>([])
    /// Measured here rather than inside the row so the suggestion row can
    /// render nothing when it has nothing, and still know how much to ask for.
    @State private var contentWidth: CGFloat = 0
    /// The selected rows — playlist entries keyed by entry id
    /// (`playlistItemID`), which stays unique even when the same song is in
    /// the playlist twice; album rows by track id. Selection exists on every
    /// collection now (click to select, double-click to play); only
    /// playlists act on it — removal, reordering — since albums are
    /// disc/track sorted and downloaded collections are offline copies.
    @State private var selection: Set<String> = []
    /// True while a drag's server replay is still settling, so a second
    /// drag can't race the first one's POSTs and interleave the sequences.
    @State private var isReplayingMoves = false
    
    private var tracks: [BaseItemDto] {
        let raw = downloaded
            ? downloads.tracks(forItemId: headerItem.id ?? "")
            : loader.value
        // Download order is a global save counter, so a track first saved by
        // another collection keeps that position here. Albums re-sort by disc
        // then track (missing numbers sink to the end); playlists keep their
        // user-assembled order.
        guard headerItem.itemType == .musicAlbum else { return raw }
        return raw.sorted {
            ($0.parentIndexNumber ?? .max, $0.indexNumber ?? .max, $0.sortName ?? "")
                < ($1.parentIndexNumber ?? .max, $1.indexNumber ?? .max, $1.sortName ?? "")
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            Section {
                trackRows
            }

            if showsGenres {
                Section {
                    GenreChips(genres: headerItem.genreRefs)
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                        .listRowSeparator(.hidden)
                }
            }

            if showsSimilarAlbums {
                // No wrapper view here: `listRowInsets` and `listRowSeparator`
                // only apply to a row's top-level view, so a stack around this
                // would swallow both and the row would keep its default insets
                // and separator.
                SimilarItemsSection(
                    kind: .albums,
                    item: headerItem,
                    availableWidth: contentWidth,
                    contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        // The reordering API's container: rows marked `.reorderable()` (the
        // playlist's track rows) can be dragged — alone or, when selected,
        // with the whole selection lifted together as the system's stacked
        // drag previews. Albums have no reorderable rows, so this stays inert
        // for them.
        .reorderContainer(for: TrackEntry.self) { difference in
            // The API declares this closure nonisolated, but a drop is a UI
            // event on the main actor; assert that so the state changes
            // inside are permitted under Swift 6 concurrency.
            MainActor.assumeIsolated {
                moveEntries(within: difference)
            }
        }
        .dragContainerSelection(Array(selection))
        #endif
        .shiftArrowSelection($selection, ids: rowIds)
        .onKeyPress(.escape) {
            selection = []
            return .handled
        }
        .focusable()
        .overlay {
            // Empty, failed and loading states sit centred over the list
            // rather than in a top row: a `ContentUnavailableView` in a List
            // cell hugs the row's top-left instead of the window's centre.
            if let errorMessage = loader.errorMessage, tracks.isEmpty {
                LoadFailureOverlay(message: errorMessage) {
                    await reload()
                    return loader.errorMessage == nil
                }
            } else if loader.isPending, tracks.isEmpty {
                ProgressView()
            } else if loader.hasLoadedOnce, tracks.isEmpty {
                ContentUnavailableView(
                    "No songs",
                    systemImage: headerItem.itemType == .playlist ? "music.note.list" : "square.stack"
                )
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .navigationTitle(headerItem.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            // Touch devices need edit mode to select and drag; iPad with a
            // trackpad selects directly, macOS needs no edit mode at all.
            if isEditablePlaylist {
                ToolbarItem { EditButton() }
            }
            #endif
            ToolbarItem { FavouriteButton(item: headerItem) }
            ToolbarItem { DownloadButton(item: headerItem) }
            if !selectedTracks.isEmpty {
                ToolbarItem { TrackSelectionMenu(tracks: selectedTracks) }
            }
            if isEditablePlaylist && !selection.isEmpty {
                ToolbarItem {
                    Button(role: .destructive, action: removeSelectedTracks) {
                        Label("Remove \(selection.count) from Playlist", systemImage: "minus.circle")
                    }
                }
            }
        }
        .task(id: headerItem.id) { await reload() }
        .refreshable { await reload() }
        .refreshToolbarItem(isAvailable: !downloaded) { await reload() }
        #if os(iOS)
        .nowPlayingTabContentDock()
        #endif
    }

    // MARK: - Track rows

    /// The track section's rows. Rows are ``TrackEntry``s — keyed by an id
    /// unique within the list rather than by position, so a reload that
    /// reorders or replaces the list carries each row's state (the
    /// current-track highlight, a swipe in progress) with the track, not to
    /// row 3 — and selection exists everywhere. Drag reordering only exists
    /// where the user owns the order — a playlist: albums re-sort by disc
    /// and track on every render, so a drag there would fight the sort and
    /// snap straight back, and downloaded collections are offline copies
    /// whose order no server call would change.
    ///
    /// `entries`, `items` and `selected` are resolved once here and passed
    /// down: `tracks` and `selectedTracks` are computed properties, and a
    /// `row(...)` call that names them re-evaluates — and for albums
    /// re-sorts — the whole list once *per row*, which is what made a
    /// 100-track album stutter.
    @ViewBuilder
    private var trackRows: some View {
        let entries = trackEntries
        let items = entries.map(\.item)
        let selected = selectedTracks
        if isEditablePlaylist {
            playlistRows(entries: entries, items: items, selected: selected)
        } else {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(entry.item, at: index, in: items, selected: selection.contains(entry.id) ? selected : [])
            }
        }
    }

    /// A server-backed playlist's rows: reorderable, with the single tap
    /// belonging to selection. iOS uses the reordering API — a drag carries
    /// the whole checkmark selection and stacks the previews under the
    /// finger — while macOS keeps `onMove`, where dragging any selected row
    /// moves the whole selection together with AppKit's native multi-row
    /// drag image.
    @ViewBuilder
    private func playlistRows(entries: [TrackEntry], items: [BaseItemDto], selected: [BaseItemDto]) -> some View {
        #if os(iOS)
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            row(entry.item, at: index, in: items, selected: selection.contains(entry.id) ? selected : [])
        }
        .reorderable()
        #else
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            row(entry.item, at: index, in: items, selected: selection.contains(entry.id) ? selected : [])
        }
        .onMove(perform: move)
        #endif
    }

    /// Every track as a row, keyed by an id unique within the list: the
    /// playlist entry id in playlists (unique even when the same song is in
    /// the playlist twice), the track id everywhere else. A List binds
    /// selection by row id and Jellyfin's ids are optional, so rows carry a
    /// non-optional id here — a String?-keyed row never matches a
    /// `Set<String>` selection. `JellyfinService` rejects id-less payloads,
    /// so the failable init never actually fails.
    private var trackEntries: [TrackEntry] {
        tracks.compactMap { TrackEntry(id: $0.playlistItemID ?? $0.id, item: $0) }
    }

    /// One track row. `items` and `selected` come in precomputed from the
    /// rows' builder — never re-derived here. `selected` arrives only for
    /// rows that are part of the selection, so a selection change leaves the
    /// other rows' inputs untouched and the List skips them.
    private func row(_ track: BaseItemDto, at index: Int, in items: [BaseItemDto], selected: [BaseItemDto]) -> some View {
        TrackRow(
            track: track,
            showArtwork: showArtworkInRows,
            selectedTracks: selected,
            onRemoveFromPlaylist: isEditablePlaylist ? { removeFromPlaylist(track) } : nil
        ) {
            player.play(items, startAt: index)
        }
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                artwork.frame(width: 180, height: 180)
                info(alignment: .leading)
                Spacer(minLength: 0)
            }
            VStack(spacing: 16) {
                artwork.frame(maxWidth: 240)
                info(alignment: .center)
            }
        }
    }

    private var artwork: some View {
        var localArtworkURL: URL? {
            guard session.serverReachable == false else { return nil }
            guard downloads.isDownloaded(headerItem) else { return nil }
            return downloads.localArtworkURL(forImageTag: headerItem.primaryImageTag ?? headerItem.albumPrimaryImageTag ?? "")
        }
        return ArtworkImage(
            url: session.library.artworkURL(for: headerItem, size: 500),
            localURL: localArtworkURL,
            cornerRadius: 8,
            placeholderSystemImage: headerItem.itemType == .playlist ? "music.note.list" : "square.stack"
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    private func info(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(headerItem.displayName)
                .font(.title.bold())
                .lineLimit(3)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            if let subtitle {
                // A plain Button pushing through ``LibraryNavigator``, not a
                // `NavigationLink`: the subtitle sits in the header's List
                // row, where a `NavigationLink` would make the whole row one
                // tap target. Same reason as the chips in ``GenreChips``.
                if let subtitleItem {
                    Button {
                        navigator.open(subtitleItem)
                    } label: {
                        subtitleText(subtitle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open artist \(subtitle)")
                } else {
                    subtitleText(subtitle)
                }
            }
            Text(metaLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            actions
                .padding(.top, 6)
        }
        .frame(maxWidth: alignment == .center ? .infinity : nil,
               alignment: alignment == .center ? .center : .leading)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(tracks.isEmpty)

            Button {
                player.play(tracks, shuffled: true)
            } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(.bordered)
            .disabled(tracks.isEmpty)
        }
    }

    private func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = headerItem.productionYear { parts.append(String(year)) }
        let count = tracks.isEmpty ? headerItem.childCount : tracks.count
        parts.append(Format.songCount(count))
        let total = tracks.compactMap(\.runtimeSeconds).reduce(0, +)
        if total > 0 { parts.append(Format.duration(total)) }
        return parts.joined(separator: " • ")
    }

    // MARK: - Loading

    /// Playlists are the only collection whose order the user owns — albums
    /// are disc/track sorted, and downloaded collections are offline copies
    /// whose order no server call would change. Only an editable,
    /// server-backed playlist gets row selection, drag reordering and batch
    /// removal.
    private var isEditablePlaylist: Bool {
        headerItem.itemType == .playlist && !downloaded
    }

    private func removeFromPlaylist(_ track: BaseItemDto) {
        guard let entryId = track.playlistItemID else { return }
        Task {
            // ponytail: failed removes surface as the track simply surviving
            // the reload; no separate error UI.
            try? await session.library.removeFromPlaylist(playlistId: headerItem.id, entryIds: [entryId])
            await reload()
        }
    }

    private func reload() async {
        await loader.load { try await session.library.tracks(for: headerItem) }
    }

    /// The ids the track rows are keyed by, in list order — what
    /// shift-arrow's range spans. Playlists key rows by playlist entry id;
    /// every other collection by track id.
    private var rowIds: [String] {
        trackEntries.map(\.id)
    }

    /// The selected tracks in list order — what selection actions act on.
    private var selectedTracks: [BaseItemDto] {
        trackEntries.filter { selection.contains($0.id) }.map(\.item)
    }

    // MARK: - Playlist editing

    /// Commits a reorder — a drag on macOS (`onMove`) or a drop on iOS (the
    /// reordering API) — by applying it locally first, so the drag feels
    /// instant, then replaying it on the server, which only understands one
    /// entry move per request (``movePlan(from:to:)``).
    private func commitReorder(to reordered: [BaseItemDto]) {
        // A drag racing the previous drag's still-in-flight replay would
        // interleave two POST sequences and corrupt the order, so drags that
        // arrive before the server has settled are refused — their rows snap
        // back to the settled arrangement.
        guard !isReplayingMoves else { return }
        isReplayingMoves = true
        let before = tracks
        loader.mutate { $0 = reordered }
        let after = tracks
        Task {
            await replay(Self.movePlan(from: before, to: after))
            // ponytail: the optimistic move is already on screen, so success
            // and failure share one outcome — the reload shows the server's
            // arrangement, which confirms the drag or snaps the list back if
            // a move was rejected. No separate error UI for either.
            await reload()
            isReplayingMoves = false
        }
    }

    #if os(macOS)
    /// `onMove`'s drag. The offsets index the playlist's entries; a
    /// multi-row drag arrives as one source set — dragging any selected row
    /// drags the whole selection.
    private func move(from source: IndexSet, to destination: Int) {
        var entries = trackEntries
        entries.move(fromOffsets: source, toOffset: destination)
        commitReorder(to: entries.map(\.item))
    }
    #endif

    #if os(iOS)
    /// The reordering API's drop: the dragged entries land before an anchor
    /// entry or at the end of the list.
    private func moveEntries(within difference: ReorderDifference<String, ReorderableSingleCollectionIdentifier>) {
        let position: PlaylistDropPosition
        switch difference.destination.position {
        case .before(let anchor): position = .before(anchor)
        case .end: position = .end
        }
        commitReorder(to: Self.reordered(trackEntries, moving: difference.sources, to: position).map(\.item))
    }
    #endif

    /// Performs the plan's moves in order, stopping at the first failure:
    /// every move is issued against the arrangement the previous one left
    /// behind, so nothing after a failure is meaningful.
    private func replay(_ ops: [PlaylistMoveOp]) async {
        for op in ops {
            do {
                try await session.library.moveInPlaylist(
                    playlistId: headerItem.id,
                    entryId: op.entryId,
                    to: op.index
                )
            } catch {
                return
            }
        }
    }

    /// Removes every selected entry in one request, then refreshes.
    private func removeSelectedTracks() {
        let entryIds = trackEntries
            .filter { selection.contains($0.id) }
            .compactMap(\.item.playlistItemID)
        guard !entryIds.isEmpty else { return }
        selection = []
        Task {
            // ponytail: failed removes surface as the tracks simply surviving
            // the reload; no separate error UI.
            try? await session.library.removeFromPlaylist(playlistId: headerItem.id, entryIds: entryIds)
            await reload()
        }
    }

    /// One single-entry move the server must perform to replay a drag.
    struct PlaylistMoveOp: Equatable {
        let entryId: String
        let index: Int
    }

    /// The single-entry moves that turn `before` into `after`.
    ///
    /// A multi-row drag — possible whenever selection is active — cannot be
    /// expressed as one Jellyfin request, so the general strategy walks target
    /// positions front to back and moves the entry that belongs at each
    /// position into place: every step leaves the positions before `target`
    /// final, and inserting at `target` never disturbs them again. That is also
    /// why indices can't be precomputed from `after` alone — each move is
    /// issued against the arrangement the previous move left behind.
    ///
    /// A single-row drag (the overwhelmingly common case) is detected up front
    /// and collapses to one request; without that, dragging a song from the
    /// top of a long playlist to the bottom would issue a move for every row
    /// it passed.
    ///
    /// Entries without a `playlistItemID` — servers predating playlist entries
    /// — contribute no move; the next reload re-synchronizes those lists.
    static func movePlan(from before: [BaseItemDto], to after: [BaseItemDto]) -> [PlaylistMoveOp] {
        guard before.count == after.count, !before.isEmpty else { return [] }
        if let single = Self.singleEntryMove(from: before, to: after) {
            return [single]
        }

        var simulation = before
        var ops: [PlaylistMoveOp] = []
        for target in simulation.indices {
            guard simulation[target].playlistEntryKey != after[target].playlistEntryKey,
                  let current = simulation.firstIndex(where: { $0.playlistEntryKey == after[target].playlistEntryKey })
            else { continue }
            let entry = simulation.remove(at: current)
            simulation.insert(entry, at: target)
            if let entryId = entry.playlistItemID {
                ops.append(PlaylistMoveOp(entryId: entryId, index: target))
            }
        }
        return ops
    }

    /// The single move that turns `before` into `after`, when `after` is
    /// exactly `before` with one row removed and reinserted; nil otherwise.
    private static func singleEntryMove(from before: [BaseItemDto], to after: [BaseItemDto]) -> PlaylistMoveOp? {
        // The moved row starts or ends inside the window where the two orders
        // disagree, so only rows there can be candidates.
        for index in before.indices where before[index].playlistEntryKey != after[index].playlistEntryKey {
            let entry = before[index]
            guard let target = after.firstIndex(where: { $0.playlistEntryKey == entry.playlistEntryKey }),
                  let entryId = entry.playlistItemID
            else { continue }
            var candidate = before
            candidate.remove(at: index)
            candidate.insert(entry, at: target)
            if candidate.map(\.playlistEntryKey) == after.map(\.playlistEntryKey) {
                return PlaylistMoveOp(entryId: entryId, index: target)
            }
        }
        return nil
    }

    /// Where a reorder drop lands, in the vocabulary of the entries list.
    enum PlaylistDropPosition: Equatable {
        /// Immediately before the entry with this id.
        case before(String)
        /// At the end of the list.
        case end
    }

    /// The entry list after a reorder drop: the dragged entries leave their
    /// positions and reinsert — in drag order — before the anchor entry, or
    /// at the end. Every other entry keeps both its order and its position
    /// relative to them.
    static func reordered(
        _ entries: [TrackEntry],
        moving sources: [String],
        to position: PlaylistDropPosition
    ) -> [TrackEntry] {
        // A repeated source id would otherwise duplicate the entry.
        var seen = Set<String>()
        let dragged = sources.filter { seen.insert($0).inserted }
        let moving = Set(dragged)
        let moved = dragged.compactMap { id in entries.first { $0.id == id } }
        var result = entries.filter { !moving.contains($0.id) }
        switch position {
        case .end:
            result.append(contentsOf: moved)
        case .before(let anchor):
            if let index = result.firstIndex(where: { $0.id == anchor }) {
                result.insert(contentsOf: moved, at: index)
            } else {
                // The anchor is gone (a concurrent edit); keeping the dragged
                // entries in the list matters more than where exactly.
                result.append(contentsOf: moved)
            }
        }
        return result
    }
}

/// One row of a track list: the track plus the non-optional id the row is
/// keyed by within its list — the Jellyfin playlist entry id in playlists,
/// where ordering, selection, removal and the move endpoint all operate on
/// entries (so the same song twice is two distinct rows), and the track id
/// everywhere else. A List binds selection by row id, and Jellyfin's ids are
/// optional, so track rows carry their id here: a String?-keyed row never
/// matches a `Set<String>` selection.
struct TrackEntry: Identifiable, Hashable {
    let id: String
    let item: BaseItemDto

    init?(id: String?, item: BaseItemDto) {
        guard let id else { return nil }
        self.id = id
        self.item = item
    }

    /// Tracks as rows keyed by track id, for lists that are not playlists.
    static func rows(_ tracks: [BaseItemDto]) -> [TrackEntry] {
        tracks.compactMap { TrackEntry(id: $0.id, item: $0) }
    }

    static func == (lhs: TrackEntry, rhs: TrackEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension BaseItemDto {
    /// A playlist row's identity: the playlist entry id when the item came
    /// from a playlist (unique even when the same song is in the playlist
    /// twice), otherwise the item id.
    var playlistEntryKey: String? { playlistItemID ?? id }
}
