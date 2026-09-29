import SwiftUI

/// Recent Music: the newest albums and artists the server has, under a header
/// picked at random from ``RecentMusicHeading/options`` each time the page
/// loads. An empty row is no row, so a library without one kind simply shows
/// the other.
struct RecentMusicSection: View {
    let heading: String
    let latest: HomeModel.Latest

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(heading)
                .font(.title2.bold())
                .padding(.horizontal)
            if !latest.albums.isEmpty {
                row("Albums", items: latest.albums)
            }
            if !latest.artists.isEmpty {
                row("Artists", items: latest.artists)
            }
        }
    }

    private func row(_ title: String, items: [BaseItemDto]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .padding(.horizontal)
            HomeItemRow(items: items) { HomeItemTile(item: $0) }
        }
    }
}