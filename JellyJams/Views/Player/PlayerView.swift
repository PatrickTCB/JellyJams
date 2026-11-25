import SwiftUI
import MediaPlayer
import AVKit
#if os(tvOS)
import UIKit
#endif

/// The full-screen "Now Playing" view: large artwork, scrubber, transport, and
/// shuffle/repeat controls, plus access to the queue.
struct PlayerView: View {
    @Environment(SessionStore.self) private var session
    @Environment(PlayerController.self) private var player
    @Environment(PlaybackClock.self) private var clock
    @Environment(DownloadStore.self) private var downloads
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showingQueue = false
    @State private var isPresentingLyrics = false
    #if os(tvOS)
    /// Whether the scrubber row holds the remote's focus, so it can show a
    /// highlight while left/right seeks through the track.
    @FocusState private var isScrubberFocused: Bool
    /// How far each left/right press seeks while the scrubber holds focus.
    private static let remoteSeekStep: Double = 10
    #endif

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 24) {
            Spacer(minLength: 0)

            let currentItem = player.currentItem
            // A downloaded track's cover comes from disk, never from the server.
            let localArtworkURL = currentItem.flatMap(downloads.localArtworkURL(for:))
            ArtworkImage(url: currentItem.flatMap { session.library.artworkURL(for: $0, size: 800) }, localURL: localArtworkURL, cornerRadius: 12)
                .frame(maxWidth: 720, maxHeight: 720)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .padding(.horizontal)

            VStack(spacing: 6) {
                handle
                Text(player.currentItem?.displayName ?? "Not Playing")
                    .font(.title2.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let artist = player.currentItem?.subtitleArtist {
                    Text(artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
                scrubber
                transport
                secondaryControls
            }
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        // The cover's own backdrop is translucent on tvOS; an opaque surface
        // filling the whole screen keeps the shell from showing through the
        // player. tvOS has no UIColor.systemBackground, so the dynamic
        // provider stands in for it — following the TV's light/dark appearance.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
                .ignoresSafeArea()
        )
        .remotePlayPause()
        // The cover raises the queue and lyrics sheets too. These live on the
        // tvOS branch as well as the non-tvOS one below: attached only there,
        // the TV's lyrics and queue buttons set their flags with nothing
        // watching them, so a press appears to do nothing.
        .sheet(isPresented: $showingQueue) { QueueView() }
        .sheet(isPresented: $isPresentingLyrics) { LyricsView() }
        #else
        VStack(spacing: 24) {
            handle
            Spacer(minLength: 0)

            let currentItem = player.currentItem
            // A downloaded track's cover comes from disk, never from the server.
            let localArtworkURL = currentItem.flatMap(downloads.localArtworkURL(for:))
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
        .sheet(isPresented: $isPresentingLyrics) { LyricsView() }
        #endif
    }

    private var handle: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline)
            }.buttonStyle(.glassProminent)
            Spacer()
            if let item = player.currentItem {
                // The same submenu the song's context menu offers — the song,
                // its album, its artists — shown icon-only, and nothing at
                // all when the backend can't take bans.
                BanMenu(item: item)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.secondary)
                FavouriteButton(item: item, size: .title3)
            }
        }
        // One focus row: up/down leaves it through its full-width frame, so
        // the remote reaches the scrubber below even though no control sits
        // directly beneath the edge-pinned Dismiss and Favourite buttons.
        .remoteFocusSection()
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            #if os(tvOS)
            // tvOS has no Slider. The bar is a focusable row of its own:
            // left/right on the remote seeks while it holds focus, and the
            // system Now Playing overlay still offers its own scrubbing.
            ProgressView(value: clock.currentTime, total: max(clock.duration, 0.1))
                .frame(maxWidth: .infinity)
            #else
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
            #endif
            HStack {
                Text(Format.duration(isScrubbing ? scrubTime : clock.currentTime))
                Spacer()
                Text(Format.duration(clock.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        #if os(tvOS)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .opacity(isScrubberFocused ? 1 : 0)
        )
        .focusable()
        .focused($isScrubberFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left: player.seek(to: clock.currentTime - Self.remoteSeekStep)
            case .right: player.seek(to: clock.currentTime + Self.remoteSeekStep)
            default: break
            }
        }
        #endif
        .remoteFocusSection()
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
            #if !os(tvOS)
            .keyboardShortcut(.space, modifiers: [])
            #endif

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .buttonStyle(.plain)
            .disabled(!player.canGoNext)
        }
        .remoteFocusSection()
    }

    @ViewBuilder private var secondaryControls: some View {
        #if os(macOS)
        // Equal-width flexible sides keep the buttons centred under the
        // transport while the volume slider sits at the trailing edge.
        HStack(spacing: 16) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            secondaryButtons.fixedSize()
            VolumeSlider()
                .frame(minWidth: 80, maxWidth: 160)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal)
        #else
        secondaryButtons
        #endif
    }

    private var secondaryButtons: some View {
        HStack(spacing: 32) {
            #if os(iOS)
            AirPlayPicker()
            #endif
            
            // The current track's lyrics. Always in the row, so the controls
            // don't shift as tracks change, and disabled when there are none
            // to show: nothing playing, or a track the server has no lyrics
            // for. Plain like the queue's button, which also raises a sheet —
            // the tint in this row marks the modes that are on.
            Button { isPresentingLyrics = true } label: {
                Image(systemName: "music.microphone")
            }
            .buttonStyle(.plain)
            .disabled(!(player.currentItem?.supportsLyrics ?? false))

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

            // The same preference in the backend settings sheet's toggle edits —
            // Infinite Queue is one switch with two handles. Lit while on;
            // when the backend cannot be reached it simply does nothing rather
            // than refusing the tap.
            Button { preferences.infiniteQueueEnabled.toggle() } label: {
                Image(systemName: "infinity")
                    .foregroundStyle(preferences.infiniteQueueEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)

            Button { showingQueue = true } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.plain)
        }
        .font(.title3)
        .remoteFocusSection()
    }
}
