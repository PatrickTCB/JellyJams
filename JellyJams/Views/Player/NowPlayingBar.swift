import SwiftUI

/// Persistent mini player shown above the tab bar / at the bottom of the
/// window whenever something is loaded. Tapping the metadata opens the full
/// player; transport buttons are separate controls (never nested in a button).
struct NowPlayingBar: View {
    /// Where the bar is hosted, which decides how much chrome it draws for
    /// itself and how tightly it lays out.
    enum Presentation {
        /// Docked with `safeAreaInset` on macOS, iPad and iOS 18–25: draws its
        /// own separator, background and progress line.
        case docked
        /// Hosted by the iOS 26 tab bar accessory, which supplies the glass
        /// background behind it.
        case accessory
        /// Hosted by the iOS 26 tab bar accessory while the tab bar is
        /// minimised, which leaves room for one condensed line of controls.
        case accessoryInline
    }

    var presentation: Presentation = .docked

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playerPresentation: PlayerPresentation

    private var isDocked: Bool { presentation == .docked }
    private var isInline: Bool { presentation == .accessoryInline }

    var body: some View {
        if let item = player.currentItem {
            VStack(spacing: 0) {
                if isDocked { Divider() }
                HStack(spacing: isInline ? 8 : 12) {
                    Button {
                        playerPresentation.isShowingPlayer = true
                    } label: {
                        HStack(spacing: isInline ? 8 : 12) {
                            #if os(macOS)
                            ArtworkImage(url: session.library.artworkURL(for: item, size: 192))
                                .frame(width: 64, height: 64)
                            #else
                            ArtworkImage(url: session.library.artworkURL(for: item, size: 96))
                                .frame(width: isInline ? 28 : 40, height: isInline ? 44 : 44)
                            #endif
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                                if let artist = item.subtitleArtist, !isInline {
                                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Now Playing")

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
                .padding(.horizontal, 12)
                .padding(.vertical, isInline ? 8 : 12)
                .overlay(alignment: .bottom) { if isDocked { progressLine } }
            }
            .background { if isDocked { Rectangle().fill(.bar) } }
        }
    }

    private var progressLine: some View {
        GeometryReader { geo in
            let fillPercentage = player.duration > 0
                ? min(max(player.currentTime / player.duration, 0), 1)
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
