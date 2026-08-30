import SwiftUI

/// "Similar Albums" / "Similar Artists" at the foot of a detail screen: one row
/// of tiles the server picked as close to what you are looking at.
///
/// The row is sized to the space it is given rather than to the device, so a
/// narrow Split View column gets the iPhone treatment instead of the iPad one.
/// That count is what is asked of Jellyfin, not a trim applied to the response,
/// so nothing is fetched that cannot be shown.
///
/// Renders nothing when the lookup is switched off, when it found nothing, or
/// while it is still running — a suggestion row is not worth a spinner, and an
/// empty one is worse than none. Callers can include it unconditionally, the
/// way ``GenreChips`` is included.
struct SimilarItemsSection: View {
    let kind: LibraryRepository.SimilarKind
    let item: BaseItemDto
    /// Width of the screen hosting this row, measured by the parent.
    let availableWidth: CGFloat
    /// Padding for the row itself. A `List` row has to inset its own content —
    /// insets applied by the caller would also pad the invisible placeholder
    /// this shows while it has nothing, leaving a gap under the track list.
    var contentInsets = EdgeInsets()

    /// Enough width for five tiles to stay legible — five at roughly 125pt plus
    /// the gaps between them. A full-width iPad clears this in either
    /// orientation; an iPhone and a narrow Split View column do not.
    private static let wideLayoutMinimumWidth: CGFloat = 700
    private static let wideCount = 5
    private static let narrowCount = 3

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var navigator: LibraryNavigator
    @StateObject private var loader = LoadableModel<[BaseItemDto]>([])
    /// The `item`+`count` the current suggestions were fetched for. Jellyfin's
    /// "similar" endpoint returns a fresh random sample on every call, so
    /// re-running the load when nothing has actually changed — which `task`
    /// does each time this row scrolls back on screen — would swap the tiles
    /// out from under the user (and cancel a tap that was landing on one).
    @State private var loadedKey: LoadKey?

    private var similar: [BaseItemDto] { loader.value }

    /// `nil` until the parent has measured itself. Loading waits for that, so
    /// the first request already asks for the right number instead of fetching
    /// three and immediately throwing them away for five.
    private var count: Int? {
        guard availableWidth > 0 else { return nil }
        return availableWidth >= Self.wideLayoutMinimumWidth ? Self.wideCount : Self.narrowCount
    }

    var body: some View {
        // The preference is checked here rather than at the call sites so that
        // switching it off takes the `task` below out of the view tree with the
        // rest of the body. There is no request to cancel because none is made.
        if preferences.showsSimilarItems {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title2.bold())
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(similar) { suggestion in
                        // A plain Button rather than a NavigationLink: this grid
                        // renders inside a single `List` row on the album and
                        // playlist screens, where a `List` gives every
                        // NavigationLink the whole-row treatment (one collapsed
                        // tap target, plus a disclosure chevron per tile on
                        // iOS). ``LibraryNavigator`` pushes imperatively, which
                        // also survives this row reloading its contents.
                        Button {
                            navigator.open(suggestion)
                        } label: {
                            ItemGridCell(item: suggestion)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(contentInsets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: loadKey) { await load() }
        } else if !loader.hasLoadedOnce {
            // Something has to stay in the view tree to carry the task, but only
            // until it answers. Once the server has said "nothing", this leaves
            // entirely rather than lingering as an empty row: a zero-height view
            // still costs a list row's separator or a stack's spacing.
            Color.clear
                .frame(height: 0)
                .accessibilityHidden(true)
                .task(id: loadKey) { await load() }
        }
    }

    private var title: String {
        switch kind {
        case .albums: "Similar Albums"
        case .artists: "Similar Artists"
        }
    }

    /// Fixed rather than adaptive columns: the request already asked for the
    /// number that fits, so the row should lay out as that many tiles even when
    /// the server returns fewer.
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
            count: count ?? Self.narrowCount
        )
    }

    /// Reloading is driven by the item *and* the count, so rotating an iPad
    /// from three tiles to five fetches the two that were never asked for.
    private var loadKey: LoadKey { LoadKey(itemId: item.id, count: count) }

    private struct LoadKey: Equatable {
        let itemId: String?
        let count: Int?
    }

    private func load() async {
        guard let count else { return }
        let key = loadKey
        guard key != loadedKey else { return }
        await loader.load {
            try await session.library.similarItems(kind, to: item, limit: count)
        }
        if !Task.isCancelled {
            loadedKey = key
        }
    }
}
