import SwiftUI

/// A single track row used in album detail, songs, search and queue lists.
/// The whole row is a button that starts playback via `onPlay`; secondary
/// actions live in the context menu and (on iOS) swipe actions.
struct TrackRow: View {
    let track: BaseItemDto
    var showArtwork = false
    var onPlay: () -> Void

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var favourites: FavouriteStore

    private var isCurrent: Bool { player.currentItem?.id == track.id }
    private var isFavourite: Bool { favourites.isFavourite(track) }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayName)
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if let artist = track.subtitleArtist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isFavourite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(Format.duration(track.runtimeSeconds))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu }
        #if os(iOS)
        .swipeActions(edge: .leading) {
            Button {
                favourites.toggle(track)
            } label: {
                Label(isFavourite ? "Unfavourite" : "Favourite", systemImage: isFavourite ? "heart.slash" : "heart")
            }
            .tint(.red)
        }
        .swipeActions(edge: .trailing) {
            Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
                .tint(.accentColor)
            Button { player.addToQueue([track]) } label: { Label("Queue", systemImage: "text.append") }
        }
        #endif
    }

    @ViewBuilder private var leading: some View {
        if showArtwork {
            ArtworkImage(url: session.library.artworkURL(for: track, size: 96))
                .frame(width: 40, height: 40)
        } else if isCurrent {
            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 24)
        } else {
            Text(track.indexNumber.map(String.init) ?? "–")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
        Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
        Button { player.addToQueue([track]) } label: { Label("Add to Queue", systemImage: "text.append") }
        Divider()
        Button { favourites.toggle(track) } label: {
            Label(isFavourite ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: isFavourite ? "heart.slash" : "heart")
        }
        .disabled(favourites.isBusy(track))
    }
}
