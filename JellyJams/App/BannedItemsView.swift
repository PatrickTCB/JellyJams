import SwiftUI

/// The push value that opens ``BannedItemsView`` from the Jelly Jams
/// Backend settings sheet, on that sheet's own stack — see
/// ``JellyJamsBackendSettingsView``, which binds the stack to a
/// ``LibraryNavigator`` so a banned item can push its album or artist page.
struct BansScreen: Hashable { }

/// The user's bans, as the backend keeps them: what to open, what it says,
/// and where tapping goes.
///
/// The list behaves like the queue, because it is that shape of screen —
/// a plain list of rows you thin out. On iOS a row is a button that opens
/// what it names, and a swipe unbans it; on macOS the single click belongs
/// to the list's selection, the delete key takes the selection out, and
/// only a double-click opens. Opening means the artist page for a banned
/// artist, the album for a banned album, and the album a banned song was
/// taken from — the song itself has no page of its own outside it.
struct BannedItemsView: View {
    @EnvironmentObject private var bans: BanStore

    /// The banned items the macOS selection holds, keyed by item id — the
    /// same key `DELETE /ban` unbans by, and unique across the three
    /// sections because Jellyfin ids are.
    @State private var selection: Set<String> = []
    @State private var isConfirmingReset = false

    var body: some View {
        content
            .navigationTitle("Bans")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .toolbar {
                // The queue's "Remove N", bans edition: the selection's
                // answer without reaching for the keyboard.
                if !selection.isEmpty {
                    ToolbarItem {
                        Button(role: .destructive) {
                            let ids = Array(selection)
                            selection = []
                            Task { await bans.unban(itemIds: ids) }
                        } label: {
                            Label("Unban \(selection.count)", systemImage: "minus.circle")
                        }
                    }
                }
            }
            #endif
            .task { await bans.refreshBans() }
            .alert("Reset Bans", isPresented: $isConfirmingReset) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    Task { await bans.resetBans() }
                }
            } message: {
                Text("Every ban will be removed from the backend, and the playlists it generates will start offering them again. This can’t be undone.")
            }
    }

    /// Loaded bans are a list; none yet, with a read in flight, is a
    /// spinner; none after a read is the feature standing quiet — with the
    /// refusal, if the refusal is why there is nothing to show.
    @ViewBuilder private var content: some View {
        if bans.hasBans {
            #if os(iOS)
            List { sections }
            #else
            List(selection: $selection) { sections }
            #endif
        } else if bans.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Nothing’s Banned", systemImage: "nosign")
            } description: {
                Text(bans.listErrorMessage ?? "Songs, albums and artists banned from their menus are kept out of the playlists the backend generates.")
            } actions: {
                if bans.listErrorMessage != nil {
                    Button("Try Again") {
                        Task { await bans.refreshBans() }
                    }
                }
            }
        }
    }

    // MARK: - The list

    @ViewBuilder private var sections: some View {
        Section {
            Button(role: .destructive) { isConfirmingReset = true } label: {
                Label("Reset Bans", systemImage: "trash")
            }
        } footer: {
            Text("Removes every ban at once, not one at a time.")
        }

        // The kinds keep the order the setting names them in: artists,
        // albums, songs. An empty kind shows no section.
        ForEach(BanKind.allCases, id: \.self) { kind in
            let items = bans.bannedItems(of: kind)
            if !items.isEmpty {
                Section {
                    ForEach(items) { banned in
                        BannedItemRow(banned: banned)
                    }
                    .onDelete { offsets in
                        remove(items, at: offsets)
                    }
                } header: {
                    Label(kind.sectionTitle, systemImage: kind.symbol)
                }
            }
        }

        if let error = bans.listErrorMessage {
            // A refused unban, reset, or refresh — shown where the rows it
            // just put back are, since the rows are why it matters.
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    /// The delete key (macOS) and the swipe (iOS) both arrive as offsets
    /// into the section's list; the unbanning itself is the store's.
    private func remove(_ items: [BannedItem], at offsets: IndexSet) {
        let ids = offsets.map { items[$0].id }
        #if os(macOS)
        selection.subtract(ids)
        #endif
        Task { await bans.unban(itemIds: ids) }
    }
}

/// One banned item's row. Selection, swipe and delete belong to the list
/// around it; the row only names the item and opens what it can.
///
/// On iOS the row is the navigation itself — a `NavigationLink` value that
/// lands on the stack's ``LibraryNavigator/path``, the standard settings
/// row with its chevron. macOS keeps rows bare so the single click belongs
/// to the list's selection, and only a double-click opens, exactly like
/// the queue behaves there.
private struct BannedItemRow: View {
    let banned: BannedItem

    #if os(macOS)
    @EnvironmentObject private var navigator: LibraryNavigator
    #endif

    var body: some View {
        #if os(iOS)
        if let target = banned.navigationTarget {
            NavigationLink(value: target) { label }
        } else {
            // Nowhere to open — usually a banned song whose album the
            // server no longer answers. Swipe-to-unban still works.
            label
        }
        #else
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: open)
        #endif
    }

    private var label: some View {
        Text(banned.label)
    }

    #if os(macOS)
    private func open() {
        guard let target = banned.navigationTarget else { return }
        navigator.open(target)
    }
    #endif
}
