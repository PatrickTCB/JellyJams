import SwiftUI
import UniformTypeIdentifiers

/// The Pinned row: what the user marked from any album, artist, playlist or
/// mixtape's context menu.
///
/// Pins are resolved against the server by ``PinnedItemsStore`` before they
/// reach here, and they never disappear on their own: an item deleted
/// server-side keeps its tile, shown from the stored name alone, and tapping
/// it asks the server again — present, the item opens; gone, the removal of
/// the pin is offered.
///
/// The user sets the row's order themselves: with more than one pin every
/// tile lifts its pin for a drag — long-press on iOS, click-drag on macOS —
/// and dropping it at an index of the row moves it there, order and all,
/// persisted with the pins.
struct PinnedItemsSection: View {
    let entries: [PinnedItemsStore.Entry]

    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var navigator: LibraryNavigator
    @EnvironmentObject private var pinnedItems: PinnedItemsStore

    /// The pin whose removal has been offered and not yet answered.
    @State private var pinPendingRemoval: PinnedItemsStore.PinnedItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pinned")
                .font(.title2.bold())
                .padding(.horizontal)
            // A single pin has no order to change, and a lone draggable
            // tile would only fight its long-press menu — so the row
            // rearranges while it holds two or more.
            if entries.count > 1 {
                ReorderableHomeItemRow(
                    items: entries,
                    payload: \.pin,
                    drop: { pin, index in pinnedItems.move(pin, to: index) }
                ) { entry in
                    tile(for: entry)
                }
            } else {
                HomeItemRow(items: entries) { entry in
                    tile(for: entry)
                }
            }
        }
        .confirmationDialog(
            Text("Pin Unavailable"),
            isPresented: Binding(
                get: { pinPendingRemoval != nil },
                set: { if !$0 { pinPendingRemoval = nil } }
            ),
            presenting: pinPendingRemoval
        ) { pin in
            Button("Remove Pin", role: .destructive) {
                pinnedItems.unpin(pin)
            }
            Button("Keep Pin", role: .cancel) { }
        } message: { pin in
            Text("“\(pin.name)” no longer exists on your server.")
        }
    }

    @ViewBuilder
    private func tile(for entry: PinnedItemsStore.Entry) -> some View {
        switch entry.state {
        case .resolved(let item):
            if preferences.isMixtape(item) {
                MixtapeTile(mixtape: item)
            } else {
                HomeItemTile(item: item)
            }
        case .missing, .unresolved:
            UnresolvedPinTile(
                entry: entry,
                isBusy: pinnedItems.resolvingPinId == entry.pin.itemId
            ) {
                Task { await use(entry) }
            }
        }
    }

    /// The tap on an unresolved or missing pin: ask the server about it now.
    /// Answered present, the item opens — or plays, for a mixtape; answered
    /// gone, the removal is offered; failed to answer, the error surfaces and
    /// the pin stays.
    private func use(_ entry: PinnedItemsStore.Entry) async {
        switch await pinnedItems.use(entry, using: session.library) {
        case .resolved(let item):
            if preferences.isMixtape(item) {
                MixtapePlayback.play(
                    item,
                    mixtapeName: preferences.mixtapeName(for: item),
                    library: session.library,
                    player: player,
                    playlistStore: playlistStore
                )
            } else {
                navigator.open(item)
            }
        case .missing:
            pinPendingRemoval = entry.pin
        case .unavailable(let message):
            playlistStore.presentActionError(message)
        case .cancelled:
            break
        }
    }
}

extension PinnedItemsStore.PinnedItem: Transferable {
    /// The payload a pinned tile carries when it is dragged. A drop only
    /// ever moves a pin the row still holds, so a payload decoded from
    /// anywhere else changes nothing.
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// A tile for a pin the server has not currently resolved: the stored name
/// under a kind-appropriate placeholder. A missing pin — one a successful
/// server answer failed to carry — is dimmed and captioned "Unavailable"; a
/// tap re-asks the server, so an item that reappears finds its pin alive.
private struct UnresolvedPinTile: View {
    let entry: PinnedItemsStore.Entry
    let isBusy: Bool
    let onUse: () -> Void

    private var isMissing: Bool {
        if case .missing = entry.state { return true }
        return false
    }

    private var placeholderSystemImage: String {
        switch entry.pin.kind {
        case .album: "record.circle.fill"
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        }
    }

    var body: some View {
        Button(action: onUse) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkImage(
                    url: nil,
                    cornerRadius: entry.pin.kind == .artist ? 500 : 6,
                    placeholderSystemImage: placeholderSystemImage
                )
                .opacity(isMissing ? 0.5 : 1)
                .overlay {
                    if isBusy { ProgressView() }
                }

                Text(entry.pin.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(isMissing ? Color.secondary : Color.primary)

                if isMissing {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: HomeItemTile.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}
