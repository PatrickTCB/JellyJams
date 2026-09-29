import SwiftUI

/// The Pinned row: what the user marked from any album, artist, playlist or
/// station's context menu.
///
/// Pins are resolved against the server by ``PinnedItemsStore`` before they
/// reach here; an item deleted server-side simply stops appearing.
struct PinnedItemsSection: View {
    let entries: [PinnedItemsStore.Entry]

    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pinned")
                .font(.title2.bold())
                .padding(.horizontal)
            HomeItemRow(items: entries) { entry in
                tile(for: entry)
            }
        }
    }

    @ViewBuilder
    private func tile(for entry: PinnedItemsStore.Entry) -> some View {
        if preferences.isAIRadioStation(entry.item) {
            StationTile(station: entry.item)
        } else {
            HomeItemTile(item: entry.item)
        }
    }
}