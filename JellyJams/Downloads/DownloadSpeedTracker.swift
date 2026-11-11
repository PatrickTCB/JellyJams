import Foundation
import Synchronization

/// A trailing-window estimate of download throughput, fed by the byte counts
/// a download reports as data lands.
///
/// The samples sit behind a lock because those counts arrive on the session's
/// queue, off the main actor, and reading back takes `now` as an argument: a
/// stalled download must read as a falling speed while its samples age out of
/// the window, not the last value frozen.
final class DownloadSpeedTracker: Sendable {
    /// How long a landed byte still counts toward the estimate.
    private let window: TimeInterval
    private let samples = Mutex<[(at: Date, bytes: Int)]>([])

    init(window: TimeInterval = 10) {
        self.window = window
    }

    /// One landed chunk of bytes.
    func record(bytes: Int, at date: Date = Date()) {
        guard bytes > 0 else { return }
        samples.withLock { samples in
            samples.append((date, bytes))
            forgetAgedSamples(in: &samples, now: date)
        }
    }

    /// Bytes per second across the window, or `nil` when nothing has landed
    /// within it. Elapsed time is measured from the oldest surviving sample
    /// and floored at a second, so a chunk that just landed reads as its own
    /// size per second rather than spiking.
    func bytesPerSecond(asOf now: Date = Date()) -> Double? {
        samples.withLock { samples in
            forgetAgedSamples(in: &samples, now: now)
            guard let first = samples.first else { return nil }
            let bytes = samples.reduce(0) { $0 + $1.bytes }
            let elapsed = max(now.timeIntervalSince(first.at), 1)
            return Double(bytes) / elapsed
        }
    }

    /// Drops samples older than the window.
    private func forgetAgedSamples(in samples: inout [(at: Date, bytes: Int)], now: Date) {
        samples.removeAll { now.timeIntervalSince($0.at) > window }
    }
}
