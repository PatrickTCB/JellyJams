import Foundation
import MediaPlayer
import OSLog

private let nowPlayingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "net.aseriesoftubes.JellyJams",
    category: "NowPlaying"
)

/// Handlers the system remote-command center invokes (media keys, Control
/// Centre, lock screen, headphones).
struct RemoteCommandHandlers: Sendable {
    var play: @MainActor @Sendable () -> Void
    var pause: @MainActor @Sendable () -> Void
    var toggle: @MainActor @Sendable () -> Void
    var next: @MainActor @Sendable () -> Void
    var previous: @MainActor @Sendable () -> Void
    var seek: @MainActor @Sendable (Double) -> Void
}

/// Bridges playback state to `MPNowPlayingInfoCenter` and wires up
/// `MPRemoteCommandCenter`. Works on both macOS and iOS.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()
    private var didConfigure = false
    private var artworkURL: URL?

    private init() {}

    func configure(_ handlers: RemoteCommandHandlers) {
        guard !didConfigure else { return }
        didConfigure = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in
            Task { @MainActor in handlers.play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in handlers.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in handlers.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in handlers.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in handlers.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in handlers.seek(position) }
            return .success
        }
        setCommandAvailability(
            hasItem: false,
            isPlaying: false,
            canGoNext: false,
            canGoPrevious: false,
            canSeek: false
        )
    }

    func update(
        item: BaseItemDto?,
        isPlaying: Bool,
        currentTime: Double,
        duration: Double,
        artworkURL: URL?,
        canGoNext: Bool,
        canGoPrevious: Bool
    ) {
        guard let item else { clear(); return }
        setCommandAvailability(
            hasItem: true,
            isPlaying: isPlaying,
            canGoNext: canGoNext,
            canGoPrevious: canGoPrevious,
            canSeek: duration > 0
        )
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = item.subtitleArtist { info[MPMediaItemPropertyArtist] = artist }
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let track = item.indexNumber { info[MPMediaItemPropertyAlbumTrackNumber] = track }

        // Reuse existing artwork if the URL hasn't changed.
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
           artworkURL == self.artworkURL {
            info[MPMediaItemPropertyArtwork] = existing
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if artworkURL != self.artworkURL {
            self.artworkURL = artworkURL
            loadArtwork(from: artworkURL)
        }
    }

    private func loadArtwork(from url: URL?) {
        guard let url else { return }
        Task {
            if let cached = ImageCache.shared.image(for: url) {
                apply(artwork: cached, for: url)
                return
            }
            do {
                let (data, response) = try await ArtworkLoader.session.data(from: url)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let image = PlatformImage(data: data)
                else { return }
                ImageCache.shared.set(image, for: url)
                apply(artwork: image, for: url)
            } catch {
                guard !error.isCancellation else { return }
                nowPlayingLogger.debug("Could not load Now Playing artwork: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func apply(artwork image: PlatformImage, for url: URL) {
        guard url == artworkURL else { return }
        let requestHandler: @Sendable (CGSize) -> PlatformImage = { _ in image }
        let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: requestHandler)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        artworkURL = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        setCommandAvailability(
            hasItem: false,
            isPlaying: false,
            canGoNext: false,
            canGoPrevious: false,
            canSeek: false
        )
    }

    private func setCommandAvailability(
        hasItem: Bool,
        isPlaying: Bool,
        canGoNext: Bool,
        canGoPrevious: Bool,
        canSeek: Bool
    ) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = hasItem && !isPlaying
        center.pauseCommand.isEnabled = hasItem && isPlaying
        center.togglePlayPauseCommand.isEnabled = hasItem
        center.nextTrackCommand.isEnabled = hasItem && canGoNext
        center.previousTrackCommand.isEnabled = hasItem && canGoPrevious
        center.changePlaybackPositionCommand.isEnabled = hasItem && canSeek
    }
}
