import Foundation
import MediaPlayer
import OSLog

private let nowPlayingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "net.aseriesoftubes.JellyJams",
    category: "NowPlaying"
)

/// Handlers the system remote-command center invokes (media keys, Control
/// Centre, lock screen, headphones, CarPlay's Now Playing screen).
struct RemoteCommandHandlers: Sendable {
    var play: @MainActor @Sendable () -> Void
    var pause: @MainActor @Sendable () -> Void
    var toggle: @MainActor @Sendable () -> Void
    var next: @MainActor @Sendable () -> Void
    var previous: @MainActor @Sendable () -> Void
    var seek: @MainActor @Sendable (Double) -> Void
    var like: @MainActor @Sendable () -> Void
    var shuffle: @MainActor @Sendable (Bool) -> Void
    var repeatMode: @MainActor @Sendable (RepeatMode) -> Void
}

/// Bridges playback state to `MPNowPlayingInfoCenter` and wires up
/// `MPRemoteCommandCenter`. Works on both macOS and iOS.
///
/// Updated when playback *changes* — play, pause, seek, a new track, the
/// queue, shuffle, repeat — never on a clock tick: the system works out the
/// elapsed time between updates from the last one and the playback rate.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()
    private var didConfigure = false
    private var artworkURL: URL?
    private var localArtworkURL: URL?

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
        center.likeCommand.localizedTitle = "Favourite"
        center.likeCommand.localizedShortTitle = "Favourite"
        center.likeCommand.addTarget { _ in
            Task { @MainActor in handlers.like() }
            return .success
        }
        center.changeShuffleModeCommand.addTarget { event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let enabled = event.shuffleType != .off
            Task { @MainActor in handlers.shuffle(enabled) }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode = switch event.repeatType {
            case .one: .repeatOne
            case .all: .repeatAll
            default: .repeatNone
            }
            Task { @MainActor in handlers.repeatMode(mode) }
            return .success
        }
        setCommandAvailability(
            hasItem: false,
            isPlaying: false,
            canGoNext: false,
            canGoPrevious: false,
            canSeek: false,
            isFavourite: false,
            isShuffled: false,
            repeatMode: .repeatNone
        )
    }

    func update(
        item: BaseItemDto?,
        isPlaying: Bool,
        currentTime: Double,
        duration: Double,
        artworkURL: URL?,
        localArtworkURL: URL?,
        canGoNext: Bool,
        canGoPrevious: Bool,
        isFavourite: Bool,
        isShuffled: Bool,
        repeatMode: RepeatMode
    ) {
        guard let item else { clear(); return }
        setCommandAvailability(
            hasItem: true,
            isPlaying: isPlaying,
            canGoNext: canGoNext,
            canGoPrevious: canGoPrevious,
            canSeek: duration > 0,
            isFavourite: isFavourite,
            isShuffled: isShuffled,
            repeatMode: repeatMode
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

        // Reuse existing artwork if neither source has changed.
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
           artworkURL == self.artworkURL, localArtworkURL == self.localArtworkURL {
            info[MPMediaItemPropertyArtwork] = existing
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        // macOS alone reads this, and its remote controls rely on it being
        // set whenever playback starts or stops.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif

        if artworkURL != self.artworkURL || localArtworkURL != self.localArtworkURL {
            self.artworkURL = artworkURL
            self.localArtworkURL = localArtworkURL
            loadArtwork(local: localArtworkURL, remote: artworkURL)
        }
    }

    /// Updates only the heart, for a favourite changed while the track plays
    /// — from a row, a menu, the player — without rebuilding the rest.
    func updateFavourite(_ isFavourite: Bool) {
        let likeCommand = MPRemoteCommandCenter.shared().likeCommand
        guard likeCommand.isEnabled else { return }
        likeCommand.isActive = isFavourite
    }

    private func loadArtwork(local: URL?, remote: URL?) {
        guard local != nil || remote != nil else { return }
        Task {
            // The saved file is authoritative, mirroring ``ArtworkImage``:
            // downloaded artwork comes from disk and is never requested from
            // the server, so having one ends the lookup — even when it cannot
            // be decoded, where no artwork is the honest answer.
            if let local {
                if let cached = ImageCache.shared.image(for: local) {
                    apply(artwork: cached, local: local, remote: remote)
                    return
                }
                if let decoded = await ArtworkDecoder.decode(
                    fileAt: local,
                    maxPixelSize: Self.artworkPixelSize
                ) {
                    ImageCache.shared.set(decoded, for: local)
                    apply(artwork: decoded, local: local, remote: remote)
                }
                return
            }
            guard let remote else { return }
            if let cached = ImageCache.shared.image(for: remote) {
                apply(artwork: cached, local: nil, remote: remote)
                return
            }
            do {
                let (data, response) = try await ArtworkLoader.session.data(from: remote)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let image = PlatformImage(data: data)
                else { return }
                ImageCache.shared.set(image, for: remote)
                apply(artwork: image, local: nil, remote: remote)
            } catch {
                guard !error.isCancellation else { return }
                nowPlayingLogger.debug("Could not load Now Playing artwork: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The longest side artwork is decoded at. Downloaded covers are saved at
    /// 500 px and remote artwork is requested at 600 px, so this bounds the
    /// decode without ever downsampling either source.
    private static let artworkPixelSize = 1024

    private func apply(artwork image: PlatformImage, local: URL?, remote: URL?) {
        guard local == localArtworkURL, remote == artworkURL else { return }
        let requestHandler: @Sendable (CGSize) -> PlatformImage = { _ in image }
        let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: requestHandler)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        artworkURL = nil
        localArtworkURL = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
        setCommandAvailability(
            hasItem: false,
            isPlaying: false,
            canGoNext: false,
            canGoPrevious: false,
            canSeek: false,
            isFavourite: false,
            isShuffled: false,
            repeatMode: .repeatNone
        )
    }

    private func setCommandAvailability(
        hasItem: Bool,
        isPlaying: Bool,
        canGoNext: Bool,
        canGoPrevious: Bool,
        canSeek: Bool,
        isFavourite: Bool,
        isShuffled: Bool,
        repeatMode: RepeatMode
    ) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = hasItem && !isPlaying
        center.pauseCommand.isEnabled = hasItem && isPlaying
        center.togglePlayPauseCommand.isEnabled = hasItem
        center.nextTrackCommand.isEnabled = hasItem && canGoNext
        center.previousTrackCommand.isEnabled = hasItem && canGoPrevious
        center.changePlaybackPositionCommand.isEnabled = hasItem && canSeek
        center.changeShuffleModeCommand.isEnabled = hasItem
        center.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
        center.changeRepeatModeCommand.isEnabled = hasItem
        center.changeRepeatModeCommand.currentRepeatType = switch repeatMode {
        case .repeatNone: .off
        case .repeatOne: .one
        case .repeatAll: .all
        }
        // The action is a binary favourite, not a star rating, so only the
        // like command may surface — the heart. The rating, dislike and
        // bookmark commands stay disabled so the system can't offer a star.
        center.likeCommand.isEnabled = hasItem
        center.likeCommand.isActive = isFavourite
        center.ratingCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.bookmarkCommand.isEnabled = false
    }
}
