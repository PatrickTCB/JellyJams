import SwiftUI

/// Persistent mini player shown above the tab bar / at the bottom of the
/// window whenever something is loaded. Tapping the metadata opens the full
/// player; transport buttons are separate controls (never nested in a button).
struct NowPlayingBar: View {
    /// Where the bar is hosted, which decides how much chrome it draws for
    /// itself and how tightly it lays out.
    enum Presentation {
        /// The default: draws its own separator, background and progress line.
        /// The macOS shell stacks it below the tab view.
        case docked
        /// Hosted by the iOS 26 tab bar accessory, which supplies the glass
        /// background behind it.
        case accessory
        /// Hosted by the iOS 26 tab bar accessory while the tab bar is
        /// minimised, which leaves room for one condensed line of controls.
        case accessoryInline
    }

    var presentation: Presentation = .docked

    @Environment(SessionStore.self) private var session
    @Environment(PlayerController.self) private var player
    @Environment(PlaybackClock.self) private var clock
    @Environment(PlayerPresentation.self) private var playerPresentation
    @Environment(DownloadStore.self) private var downloads

    private var isDocked: Bool { presentation == .docked }
    private var isInline: Bool { presentation == .accessoryInline }
    

    var body: some View {
        if let item = player.currentItem {
            // A downloaded track's cover comes from disk, never from the server.
            let localArtworkURL = downloads.localArtworkURL(for: item)
            VStack(spacing: 0) {
                #if !os(tvOS)
                if isDocked { Divider() }
                #endif
                Group {
                    #if os(tvOS)
                    // The whole bar is one focus target: a clear-label button
                    // behind the row supplies a focus frame the size of the
                    // card, so the focus lift wraps the bar itself instead of
                    // overshooting a narrower frame into the transport. The
                    // metadata visual lets taps fall through to that button;
                    // the transport buttons stay live on top of it.
                    HStack(spacing: 12) {
                        metadata(item: item, localArtworkURL: localArtworkURL)
                            .allowsHitTesting(false)
                        transportButtons
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background {
                        Button {
                            playerPresentation.isShowingPlayer = true
                        } label: {
                            Color.clear
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open Now Playing")
                    }
                    #else
                    HStack(spacing: isInline ? 8 : 12) {
                        Button {
                            playerPresentation.isShowingPlayer = true
                        } label: {
                            metadata(item: item, localArtworkURL: localArtworkURL)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open Now Playing")

                        #if os(macOS)
                        VolumeSlider()
                            .frame(width: 140)
                            .padding(.trailing, 8)
                        #endif

                        transportButtons
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, isInline ? 8 : 12)
                    #endif
                }
                .overlay(alignment: .bottom) {
                    if isDocked {
                        #if os(tvOS)
                        // Inset past the background's rounded corners so the
                        // line stays on the card.
                        progressLine.padding(.horizontal, Self.cornerRadius)
                        #else
                        progressLine
                        #endif
                    }
                }
            }
            #if os(tvOS)
            .background {
                if isDocked {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            // Inset from the window edges so the rounded corners show — the
            // bar floats as a card rather than running edge to edge.
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            #else
            .background { if isDocked { Rectangle().fill(.bar) } }
            #endif
        }
    }

    /// The artwork-and-titles half of the bar. On tvOS it is visual only:
    /// taps fall through to the whole-bar button behind the row.
    private func metadata(item: BaseItemDto, localArtworkURL: URL?) -> some View {
        HStack(spacing: isInline ? 8 : 12) {
            #if os(macOS)
            ArtworkImage(url: session.library.artworkURL(for: item, size: 192), localURL: localArtworkURL)
                .frame(width: 64, height: 64)
            #else
            ArtworkImage(url: session.library.artworkURL(for: item, size: 96), localURL: localArtworkURL)
                .frame(width: isInline ? 28 : 40, height: isInline ? 28 : 44)
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                if let artist = item.subtitleArtist, !isInline {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The bar's corner radius on tvOS, shared by the background and the
    /// progress line's inset so the line ends where the bottom edge's
    /// straight run ends.
    private static let cornerRadius: CGFloat = 16

    /// The play and skip controls. tvOS's larger title fonts overflow the
    /// 36pt frames the other platforms use, and the focused button lifts
    /// besides, so the pair sits further apart there — the same spacing the
    /// full player's transport uses — and keeps a pinch of room from the
    /// bar's trailing edge. Other platforms keep the spacing and edge the
    /// row has always had.
    private var transportButtons: some View {
        HStack(spacing: transportSpacing) {
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(isInline ? .title3 : .title2)
                    .frame(width: isInline ? 28 : 36, height: isInline ? 28 : 36)
            }
            .buttonStyle(.plain)
            if !isInline {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(!player.canGoNext)
            }
        }
        #if os(tvOS)
        .padding(.trailing, 24)
        #endif
    }

    private var transportSpacing: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return isInline ? 8 : 12
        #endif
    }

    private var progressLine: some View {
        GeometryReader { geo in
            let fillPercentage = clock.duration > 0
                ? min(max(clock.currentTime / clock.duration, 0), 1)
                : 0
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(.gray.opacity(0.3))
                
                // Foreground (animated fill)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.tint)
                    .frame(width: geo.size.width * fillPercentage)
            }
            .animation(.easeInOut(duration: 1.0), value: fillPercentage)
        }
        .frame(height: 2)
    }
}
