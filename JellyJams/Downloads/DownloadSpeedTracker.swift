import Foundation

/// A trailing-window estimate of download throughput, fed by the byte counts
/// a download reports as data lands.
///
/// Recording is lock-guarded because those counts arrive on the session's
/// queue, off the main actor, and reading back takes `now` as an argument: a
/// stalled download must read as a falling speed while its samples age out of
/// the window, not the last value frozen.
final class DownloadSpeedTracker: @unchecked Sendable {
    /// How long a landed byte still counts toward the estimate.
    private let window: TimeInterval
    private let lock = NSLock()
    private var samples: [(at: Date, bytes: Int)] = []

    init(window: TimeInterval = 10) {
        self.window = window
    }

    /// One landed chunk of bytes.
    func record(bytes: Int, at date: Date = Date()) {
        guard bytes > 0 else { return }
        lock.lock()
        samples.append((date, bytes))
        forgetAgedSamples(now: date)
        lock.unlock()
    }

    /// Bytes per second across the window, or `nil` when nothing has landed
    /// within it. Elapsed time is measured from the oldest surviving sample
    /// and floored at a second, so a chunk that just landed reads as its own
    /// size per second rather than spiking.
    func bytesPerSecond(asOf now: Date = Date()) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        forgetAgedSamples(now: now)
        guard let first = samples.first else { return nil }
        let bytes = samples.reduce(0) { $0 + $1.bytes }
        let elapsed = max(now.timeIntervalSince(first.at), 1)
        return Double(bytes) / elapsed
    }

    /// Drops samples older than the window. Assumes the lock is held.
    private func forgetAgedSamples(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.at) > window }
    }
}
