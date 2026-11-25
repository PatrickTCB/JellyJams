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
    /// highlight and so leaving the row mid-scrub commits the pending seek.
    @FocusState private var isScrubberFocused: Bool
    /// How far each left/right press moves the playhead while the scrubber
    /// holds focus.
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
        #if os(tvOS)
        // tvOS has no Slider, so the bar is a focusable button that stands in
        // for one: select grabs the playhead (scrub mode), left/right moves it,
        // and select again releases it into a seek — the remote's analogue of
        // dragging the iOS slider. Outside scrub mode, left/right is a quick
        // skip. The system Now Playing overlay still offers its own scrubbing.
        Button {
            if isScrubbing {
                player.seek(to: scrubTime)
                isScrubbing = false
            } else {
                scrubTime = clock.currentTime
                isScrubbing = true
            }
        } label: {
            VStack(spacing: 4) {
                ProgressView(value: isScrubbing ? scrubTime : clock.currentTime, total: max(clock.duration, 0.1))
                    .frame(maxWidth: .infinity)
                    .tint(isScrubbing ? Color.white : Color.accentColor)
                scrubberTimes
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .opacity(isScrubberFocused ? 1 : 0)
        )
        .focused($isScrubberFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left: moveScrubber(by: -Self.remoteSeekStep)
            case .right: moveScrubber(by: Self.remoteSeekStep)
            default: break
            }
        }
        // Leaving the row mid-scrub commits the pending position, like letting
        // go of the slider.
        .onChange(of: isScrubberFocused) { _, focused in
            if !focused, isScrubbing {
                player.seek(to: scrubTime)
                isScrubbing = false
            }
        }
        .remoteFocusSection()
        #else
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
            scrubberTimes
        }
        .padding(.horizontal)
        .remoteFocusSection()
        #endif
    }

    /// The elapsed/total readout under the bar. While scrubbing it names the
    /// pending position, not the clock's.
    private var scrubberTimes: some View {
        HStack {
            Text(Format.duration(isScrubbing ? scrubTime : clock.currentTime))
            Spacer()
            Text(Format.duration(clock.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    #if os(tvOS)
    /// A left/right press on the focused scrubber: while scrubbing it moves the
    /// pending playhead (committed on release); otherwise it seeks at once.
    private func moveScrubber(by delta: Double) {
        if isScrubbing {
            scrubTime = max(0, min(scrubTime + delta, clock.duration))
        } else {
            player.seek(to: clock.currentTime + delta)
        }
    }
    #endif

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
