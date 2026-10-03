import SwiftUI
import MediaPlayer
import AVKit

/// The full-screen "Now Playing" view: large artwork, scrubber, transport, and
/// shuffle/repeat controls, plus access to the queue.
struct PlayerView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showingQueue = false

    var body: some View {
        VStack(spacing: 24) {
            handle
            Spacer(minLength: 0)

            let currentItem = player.currentItem
            let localArtworkURL = currentItem.flatMap { (item: BaseItemDto) -> URL? in
                guard session.serverReachable == false else { return nil }
                guard downloads.isDownloaded(item) else { return nil }
                return downloads.localArtworkURL(forImageTag: item.primaryImageTag ?? item.albumPrimaryImageTag ?? "")
            }
            ArtworkImage(url: currentItem.flatMap { session.library.artworkURL(for: $0, size: 800) }, localURL: localArtworkURL, cornerRadius: 12)
                .frame(maxWidth: 420, maxHeight: 420)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .padding(.horizontal)

            VStack(spacing: 6) {
                Text(player.currentItem?.displayName ?? "Not Playing")
                    .font(.title2.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let artist = player.currentItem?.subtitleArtist {
                    Text(artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal)

            scrubber
            transport
            secondaryControls

            Spacer(minLength: 0)
        }
        .padding()
        .frame(minWidth: 360, minHeight: 520)
        .clearsInitialKeyboardFocus()
        .sheet(isPresented: $showingQueue) { QueueView() }
    }

    private var handle: some View {
        HStack {
            if #available(iOS 26, macOS 26, *) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.headline)
                }.buttonStyle(.glassProminent)
            } else {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.headline)
                }.buttonStyle(.bordered)
            }
            Spacer()
            if let item = player.currentItem {
                FavouriteButton(item: item, size: .title3)
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : clock.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(clock.duration, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        scrubTime = clock.currentTime
                    } else {
                        player.seek(to: scrubTime)
                        isScrubbing = false
                    }
                }
            )
            HStack {
                Text(Format.duration(isScrubbing ? scrubTime : clock.currentTime))
                Spacer()
                Text(Format.duration(clock.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var transport: some View {
        HStack(spacing: 40) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .buttonStyle(.plain)

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .buttonStyle(.plain)
            .disabled(!player.canGoNext)
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 44) {
            #if os(iOS)
            AirPlayPicker()
            #endif
            
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode.systemImage)
                    .foregroundStyle(player.repeatMode == .repeatNone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)

            Button { showingQueue = true } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.plain)
        }
        .font(.title3)
    }
}
