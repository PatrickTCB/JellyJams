import Foundation
import AVFoundation
import OSLog
#if os(iOS)
import UIKit
#endif

private let playbackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "net.aseriesoftubes.JellyJams",
    category: "Playback"
)

struct QueueEntry: Identifiable, Sendable {
    let id: UUID
    let item: BaseItemDto

    init(item: BaseItemDto) {
        id = UUID()
        self.item = item
    }
}

/// Owns audio playback: the queue, the `AVPlayer`, transport controls, shuffle
/// and repeat, system Now Playing integration, and server playback reporting.
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var queue: [QueueEntry] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isShuffled = false
    /// A user-facing message set when a track fails to load or play. Views
    /// observe this to present an alert offering Retry / Skip.
    @Published private(set) var errorMessage: String?
    @Published var repeatMode: RepeatMode = .repeatNone {
        didSet { updateNowPlaying() }
    }

    private let player = AVPlayer()
    private var client: JellyfinService?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var originalQueue: [QueueEntry]?
    private var playSessionId = UUID().uuidString
    private var lastProgressReport = Date.distantPast
    private var hasActivePlayback = false
    private var reportingTask: Task<Void, Never>?
    private var itemStatusObserver: NSKeyValueObservation?
    private var failedToEndObserver: NSObjectProtocol?
    /// Whether the user has asked for playback, as distinct from whether the
    /// `AVPlayer` is producing sound right now.
    ///
    /// ``isPlaying`` tracks the player, so it drops to false on its own when
    /// the system pauses us for an interruption — and the periodic time
    /// observer can write that before the interruption notification is even
    /// delivered. This flag only moves when something *asks* for a state
    /// change, which is what "was it playing before the call?" has to mean.
    private var isPlaybackRequested = false
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    /// Whether this app currently holds the audio session. Claiming it is what
    /// silences whatever else is playing, so it is tracked rather than
    /// re-requested on every transport action.
    private var isAudioSessionActive = false
    /// Whether playback was running when an interruption began, so it is only
    /// resumed if it was actually interrupted.
    private var wasPlayingBeforeInterruption = false
    #endif

    var currentItem: BaseItemDto? {
        guard let index = currentIndex, queue.indices.contains(index) else { return nil }
        return queue[index].item
    }

    var hasQueue: Bool { !queue.isEmpty }

    var canGoNext: Bool {
        guard let index = currentIndex else { return false }
        return index + 1 < queue.count || (repeatMode == .repeatAll && !queue.isEmpty)
    }

    var canGoPrevious: Bool { currentIndex != nil }

    init() {
        player.actionAtItemEnd = .pause
        setupTimeObserver()
        setupEndObserver()
        setupFailureObserver()
        prepareAudioSession()
        setupAudioSessionObservers()
        NowPlayingCenter.shared.configure(RemoteCommandHandlers(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] time in self?.seek(to: time) }
        ))
    }

    func configure(client: JellyfinService?) {
        self.client = client
    }

    /// Tears down the observers that keep the `AVPlayer` (and this controller)
    /// alive. Without this, every discarded controller leaves a periodic time
    /// observer running and several notification registrations behind.
    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedToEndObserver { NotificationCenter.default.removeObserver(failedToEndObserver) }
        #if os(iOS)
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        #endif
        itemStatusObserver?.invalidate()
    }

    // MARK: - Transport

    func play(_ items: [BaseItemDto], startAt index: Int = 0, shuffled: Bool = false) {
        let indexedAudioItems = items.enumerated().filter {
            $0.element.itemType == .audio || $0.element.itemType == nil
        }
        let audioItems = indexedAudioItems.map(\.element)
        guard !audioItems.isEmpty else { return }
        reportStopped()
        let entries = audioItems.map(QueueEntry.init)
        originalQueue = nil
        if shuffled {
            var shuffledEntries = entries
            shuffledEntries.shuffle()
            originalQueue = entries
            queue = shuffledEntries
            isShuffled = true
            startPlayback(at: 0, reportingPreviousItem: false)
        } else {
            queue = entries
            isShuffled = false
            let requestedIndex = indexedAudioItems.firstIndex { $0.offset == index } ?? 0
            startPlayback(at: requestedIndex, reportingPreviousItem: false)
        }
    }

    func playNext(_ item: BaseItemDto) {
        playNext([item])
    }

    /// Inserts a whole collection directly after the current track, preserving
    /// its order. Starts playback instead when nothing is queued yet.
    func playNext(_ items: [BaseItemDto]) {
        let audioItems = items.filter { $0.itemType == .audio || $0.itemType == nil }
        guard !audioItems.isEmpty else { return }
        guard let index = currentIndex, queue.indices.contains(index) else {
            play(audioItems)
            return
        }
        let entries = audioItems.map(QueueEntry.init)
        let currentEntryID = queue[index].id
        queue.insert(contentsOf: entries, at: index + 1)
        if isShuffled {
            if let originalIndex = originalQueue?.firstIndex(where: { $0.id == currentEntryID }) {
                originalQueue?.insert(contentsOf: entries, at: originalIndex + 1)
            } else {
                originalQueue?.append(contentsOf: entries)
            }
        }
    }

    func addToQueue(_ items: [BaseItemDto]) {
        let audioItems = items.filter { $0.itemType == .audio || $0.itemType == nil }
        if queue.isEmpty {
            play(audioItems)
        } else {
            let entries = audioItems.map(QueueEntry.init)
            queue.append(contentsOf: entries)
            if isShuffled {
                originalQueue?.append(contentsOf: entries)
            }
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentItem != nil else { return }
        startPlayer()
        isPlaying = true
        updateNowPlaying()
        if hasActivePlayback {
            reportProgress(force: true)
        } else {
            reportStart()
        }
    }

    func pause() {
        isPlaybackRequested = false
        player.pause()
        isPlaying = false
        updateNowPlaying()
        reportProgress(force: true)
    }

    func next() {
        guard let index = currentIndex else { return }
        if index + 1 < queue.count {
            startPlayback(at: index + 1)
        } else if repeatMode == .repeatAll, !queue.isEmpty {
            startPlayback(at: 0)
        } else {
            finishPlayback()
        }
    }

    func previous() {
        guard let index = currentIndex else { return }
        if currentTime > 3 {
            seek(to: 0)
        } else if index > 0 {
            startPlayback(at: index - 1)
        } else {
            seek(to: 0)
        }
    }

    func play(atQueueIndex index: Int) {
        guard queue.indices.contains(index) else { return }
        startPlayback(at: index)
    }

    /// Rebuilds and replays the current track. A failed `AVPlayerItem` is
    /// terminal, so recovering means creating a fresh item, not calling `play()`.
    func retry() {
        guard let index = currentIndex else { return }
        startPlayback(at: index, reportingPreviousItem: false)
    }

    func dismissError() {
        errorMessage = nil
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
        updateNowPlaying()
        reportProgress(force: true)
    }

    func toggleShuffle() { setShuffle(!isShuffled) }

    func cycleRepeatMode() {
        switch repeatMode {
        case .repeatNone: repeatMode = .repeatAll
        case .repeatAll: repeatMode = .repeatOne
        case .repeatOne: repeatMode = .repeatNone
        }
    }

    func clearQueue() {
        reportStopped()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        player.replaceCurrentItem(with: nil)
        queue = []
        originalQueue = nil
        currentIndex = nil
        isPlaybackRequested = false
        isPlaying = false
        isShuffled = false
        currentTime = 0
        duration = 0
        errorMessage = nil
        NowPlayingCenter.shared.clear()
        // A full stop, unlike a pause, is the point at which whatever we
        // interrupted should be allowed to pick up again.
        deactivateAudioSession()
    }

    /// Removes every track after the currently playing one. When the current
    /// track is already last (or nothing is playing), the whole queue is cleared.
    func clearUpcoming() {
        guard let index = currentIndex, index + 1 < queue.count else {
            clearQueue()
            return
        }
        removeFromQueue(atOffsets: IndexSet(integersIn: (index + 1) ..< queue.count))
    }

    func removeFromQueue(atOffsets offsets: IndexSet) {
        guard !offsets.isEmpty else { return }
        if offsets.count == queue.count {
            clearQueue()
            return
        }

        let oldCurrentIndex = currentIndex
        let currentEntryID = oldCurrentIndex.flatMap { queue.indices.contains($0) ? queue[$0].id : nil }
        let removedCurrentItem = oldCurrentIndex.map(offsets.contains) ?? false
        if removedCurrentItem {
            reportStopped()
        }
        let removedEntryIDs = Set(offsets.compactMap { queue.indices.contains($0) ? queue[$0].id : nil })
        queue.remove(atOffsets: offsets)
        originalQueue?.removeAll { removedEntryIDs.contains($0.id) }
        if let currentEntryID,
           let newCurrentIndex = queue.firstIndex(where: { $0.id == currentEntryID }) {
            currentIndex = newCurrentIndex
        } else if let oldCurrentIndex {
            // The playing track was removed: start the item that shifted into
            // its slot, but stay paused if that is how the user left us.
            let removedBefore = offsets.filter { $0 < oldCurrentIndex }.count
            let target = min(oldCurrentIndex - removedBefore, queue.count - 1)
            startPlayback(at: target, reportingPreviousItem: false, resuming: isPlaying)
        }
    }

    func moveQueue(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let currentEntryID = currentIndex.flatMap { queue.indices.contains($0) ? queue[$0].id : nil }
        queue.move(fromOffsets: offsets, toOffset: destination)
        if let currentEntryID {
            currentIndex = queue.firstIndex(where: { $0.id == currentEntryID })
        }
    }

    // MARK: - Shuffle

    private func setShuffle(_ enabled: Bool) {
        guard enabled != isShuffled else { return }
        let current = currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil }
        if enabled {
            originalQueue = queue
            var rest = queue
            if let current, let idx = rest.firstIndex(where: { $0.id == current.id }) {
                rest.remove(at: idx)
            }
            rest.shuffle()
            queue = (current.map { [$0] } ?? []) + rest
            currentIndex = current != nil ? 0 : currentIndex
        } else if let original = originalQueue {
            queue = original
            if let current, let idx = queue.firstIndex(where: { $0.id == current.id }) {
                currentIndex = idx
            }
            originalQueue = nil
        }
        isShuffled = enabled
        updateNowPlaying()
    }

    // MARK: - Playback internals

    private func startPlayback(
        at index: Int,
        reportingPreviousItem: Bool = true,
        resuming: Bool = true
    ) {
        guard let client, queue.indices.contains(index) else { return }
        let item = queue[index].item
        let nextPlaySessionId = UUID().uuidString
        let streamURL: URL
        do {
            streamURL = try client.streamURL(
                itemId: item.id,
                mediaSourceId: item.mediaSourceID,
                playSessionId: nextPlaySessionId
            )
        } catch {
            playbackLogger.error("Could not create audio stream URL: \(error.localizedDescription, privacy: .public)")
            if reportingPreviousItem {
                reportStopped()
            }
            player.replaceCurrentItem(with: nil)
            currentIndex = index
            currentTime = 0
            duration = 0
            failPlayback(reason: error.userFacingMessage)
            return
        }
        if reportingPreviousItem {
            reportStopped()
        }
        currentIndex = index
        playSessionId = nextPlaySessionId
        errorMessage = nil
        let asset = AVURLAsset(url: streamURL)
        let playerItem = AVPlayerItem(asset: asset)
        observeStatus(of: playerItem)
        player.replaceCurrentItem(with: playerItem)
        currentTime = 0
        duration = item.runtimeSeconds ?? 0
        if resuming {
            startPlayer()
            isPlaying = true
            updateNowPlaying()
            reportStart()
        } else {
            isPlaybackRequested = false
            player.pause()
            isPlaying = false
            updateNowPlaying()
        }
    }

    private func finishPlayback() {
        clearQueue()
    }

    private func handleTrackEnd() {
        if repeatMode == .repeatOne {
            seek(to: 0)
            startPlayer()
            isPlaying = true
            reportStart()
        } else {
            next()
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                // `.waitingToPlayAtSpecifiedRate` means buffering or stalling,
                // which is still "playing" to the user and to the transport.
                // Treating only `.playing` as playing flipped the button back
                // to Play mid-stream and undid what `resume()` had just set.
                self.isPlaying = self.player.timeControlStatus != .paused
                self.updateNowPlaying()
                self.reportProgress(force: false)
            }
        }
    }

    private func setupEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let endedItemIdentifier = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self,
                      let endedItemIdentifier,
                      let currentItem = self.player.currentItem,
                      ObjectIdentifier(currentItem) == endedItemIdentifier
                else { return }
                self.handleTrackEnd()
            }
        }
    }

    /// Handles failures that happen *during* playback (e.g. the connection drops
    /// mid-track), which arrive as a notification rather than a status change.
    private func setupFailureObserver() {
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let failedItemID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            let failedItem = notification.object as? AVPlayerItem
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let reason = Self.reason(from: error, statusCode: failedItem?.errorLog()?.events.last?.errorStatusCode)
            Task { @MainActor [weak self] in
                guard let self,
                      let failedItemID,
                      let current = self.player.currentItem,
                      ObjectIdentifier(current) == failedItemID
                else { return }
                self.failPlayback(reason: reason)
            }
        }
    }

    /// Observes the freshly-created item so a load failure (unreachable server,
    /// auth error, unplayable file) surfaces to the user instead of silently
    /// stalling — `AVPlayerItemDidPlayToEndTime` never fires for these.
    private func observeStatus(of item: AVPlayerItem) {
        itemStatusObserver?.invalidate()
        let observedItemID = ObjectIdentifier(item)
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let current = self.player.currentItem,
                      ObjectIdentifier(current) == observedItemID,
                      current.status == .failed
                else { return }
                let reason = Self.reason(
                    from: current.error,
                    statusCode: current.errorLog()?.events.last?.errorStatusCode
                )
                self.failPlayback(reason: reason)
            }
        }
    }

    /// Stops on the failed track and publishes a message. We deliberately do not
    /// auto-skip: if the cause is server-wide (expired token, server asleep) that
    /// would storm through the whole queue firing errors and hide the real cause.
    private func failPlayback(reason: String) {
        reportStopped(failed: true)
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        isPlaybackRequested = false
        player.pause()
        isPlaying = false
        let name = currentItem?.displayName ?? "this track"
        errorMessage = "Couldn’t play “\(name)”. \(reason)"
        updateNowPlaying()
        playbackLogger.error("Playback failed: \(reason, privacy: .public)")
    }

    /// Builds a plain-language reason from an `AVFoundation`/`URL` error, favouring
    /// the concrete underlying error and the server's HTTP status when present.
    nonisolated static func reason(from error: Error?, statusCode: Int?) -> String {
        var parts: [String] = []
        if let statusCode, statusCode > 0 {
            parts.append("The server responded \(statusCode).")
            if let hint = httpHint(statusCode) { parts.append(hint) }
        }
        if let nsError = error as NSError? {
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            let detail = underlying?.localizedDescription ?? nsError.localizedDescription
            if !detail.isEmpty, !parts.contains(detail) {
                parts.append(detail)
            }
        }
        if parts.isEmpty {
            parts.append("The file couldn’t be played — it may be missing or in a format this device can’t decode.")
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func httpHint(_ statusCode: Int) -> String? {
        switch statusCode {
        case 401: return "Your session may have expired — try signing out and back in."
        case 403: return "This account may not have permission to play it."
        case 404: return "The file wasn’t found on the server."
        case 500...599: return "The server had a problem sending the file."
        default: return nil
        }
    }

    // MARK: - Audio session

    /// Every path that starts the `AVPlayer` goes through here, so the audio
    /// session is claimed exactly once and only at the moment sound is about to
    /// come out.
    private func startPlayer() {
        isPlaybackRequested = true
        activateAudioSession()
        player.play()
    }

    /// Declares what kind of audio this app plays, without claiming the session.
    ///
    /// The category only takes effect on activation, so setting it up front is
    /// free. Activation is the part that silences whatever else is playing,
    /// which is why it is deferred to ``activateAudioSession()``.
    private func prepareAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            playbackLogger.error("Could not set audio session category: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Claims the audio session, interrupting other apps.
    ///
    /// Deliberately not done at sign-in: launching Jelly Jams, or signing in to
    /// browse, would stop whatever the user was already listening to before
    /// they had asked for a single track.
    private func activateAudioSession() {
        #if os(iOS)
        guard !isAudioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            isAudioSessionActive = true
        } catch {
            playbackLogger.error("Could not activate audio session: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Releases the audio session so another app can resume.
    ///
    /// Only on a full stop. A pause keeps the session, so resuming is instant
    /// and doesn't interrupt anything that filled the silence.
    private func deactivateAudioSession() {
        #if os(iOS)
        guard isAudioSessionActive else { return }
        isAudioSessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            playbackLogger.error("Could not deactivate audio session: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Watches for the two ways playback stops without anyone touching this
    /// app's controls: an interruption (a phone call, another app taking the
    /// session) and an output route disappearing (headphones unplugged).
    ///
    /// Without these the transport goes on claiming to play silence after a
    /// call, and pulling headphones out sends the music to the built-in speaker
    /// at whatever volume it happened to be.
    private func setupAudioSessionObservers() {
        #if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      let rawType,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType)
                else { return }
                switch type {
                case .began:
                    self.handleInterruptionBegan()
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
                    self.handleInterruptionEnded(shouldResume: options.contains(.shouldResume))
                @unknown default:
                    break
                }
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      let rawReason,
                      AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
                else { return }
                self.handleOutputDeviceLost()
            }
        }
        #endif
    }

    #if os(iOS)
    /// The system has already stopped our audio and taken the session away, so
    /// this only catches the published state up with what the user can hear.
    private func handleInterruptionBegan() {
        // Captured before `pause()`, which clears it.
        wasPlayingBeforeInterruption = isPlaybackRequested
        isAudioSessionActive = false
        guard isPlaybackRequested else { return }
        pause()
    }

    /// Resumes only when the system says so. An interruption that ends without
    /// `.shouldResume` — the user switched to another audio app — should leave
    /// us paused rather than fight for the speaker.
    private func handleInterruptionEnded(shouldResume: Bool) {
        let shouldRestart = shouldResume && wasPlayingBeforeInterruption
        wasPlayingBeforeInterruption = false
        guard shouldRestart, currentItem != nil else { return }
        resume()
    }

    /// Headphones or a Bluetooth device went away. `AVAudioSession` has already
    /// rerouted to the built-in speaker, so pause instead of playing the user's
    /// music out loud to the room.
    private func handleOutputDeviceLost() {
        guard isPlaybackRequested else { return }
        pause()
    }
    #endif

    // MARK: - Now Playing

    private func updateNowPlaying() {
        NowPlayingCenter.shared.update(
            item: currentItem,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            artworkURL: currentItem.flatMap { client?.artworkURL(for: $0, size: 600) },
            canGoNext: canGoNext,
            canGoPrevious: canGoPrevious
        )
    }

    // MARK: - Reporting

    private func playbackState() -> PlaybackStateInfo? {
        guard let item = currentItem, let itemId = item.id else { return nil }
        return PlaybackStateInfo(
            canSeek: true,
            isMuted: false,
            isPaused: !isPlaying,
            itemID: itemId,
            mediaSourceID: item.mediaSourceID,
            playMethod: .directPlay,
            playSessionID: playSessionId,
            playlistItemID: item.playlistItemID,
            positionTicks: Ticks.ticks(fromSeconds: currentTime),
            repeatMode: repeatMode
        )
    }

    private func playbackStop(failed: Bool = false) -> PlaybackStopInfo? {
        guard let item = currentItem, let itemId = item.id else { return nil }
        return PlaybackStopInfo(
            isFailed: failed,
            itemID: itemId,
            mediaSourceID: item.mediaSourceID,
            playSessionID: playSessionId,
            playlistItemID: item.playlistItemID,
            positionTicks: Ticks.ticks(fromSeconds: currentTime)
        )
    }

    private func reportStart() {
        guard let client, let info = playbackState() else { return }
        hasActivePlayback = true
        lastProgressReport = Date()
        enqueuePlaybackReport("start") {
            try await client.reportPlaybackStart(info)
        }
    }

    private func reportProgress(force: Bool) {
        guard hasActivePlayback, let client, let info = playbackState() else { return }
        if !force && Date().timeIntervalSince(lastProgressReport) < 5 { return }
        lastProgressReport = Date()
        enqueuePlaybackReport("progress") {
            try await client.reportPlaybackProgress(info)
        }
    }

    private func reportStopped(failed: Bool = false) {
        guard hasActivePlayback else { return }
        hasActivePlayback = false
        guard let client, let info = playbackStop(failed: failed) else { return }
        enqueuePlaybackReport(failed ? "failed" : "stop") {
            try await client.reportPlaybackStopped(info)
        }
    }

    private func enqueuePlaybackReport(
        _ event: String,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        let previousTask = reportingTask
        reportingTask = Task {
            if let previousTask {
                await previousTask.value
            }
            do {
                try await operation()
            } catch {
                playbackLogger.error("Could not report playback \(event, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
