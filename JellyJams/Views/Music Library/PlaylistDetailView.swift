import SwiftUI

struct PlaylistDetailView: View {
    let playlist: BaseItemDto

    var body: some View {
        TrackListDetail(headerItem: playlist, showArtworkInRows: true)
    }
}
