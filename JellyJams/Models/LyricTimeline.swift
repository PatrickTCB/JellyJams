import Foundation
import JellyfinAPI

/// The lyric line a listener is currently on, picked from the timestamped
/// lines a server sends back with its lyrics.
///
/// The server stamps each line with its start time in ticks — ten million per
/// second — so a line's ``LyricLine/start`` arrives as a raw count that has to be
/// scaled down to seconds before it can be compared against the player's clock.
/// Lines the server left untimestamped (`start == nil`) have no period to be
/// current in, and never get picked.
enum LyricTimeline {
    /// The line whose time period contains `time` seconds into the track, or
    /// nil when the moment falls before the first timestamped line.
    ///
    /// A line is current from its own start until the next line's start, so
    /// the last line to have started at or before the moment is the one being
    /// sung — the final line holds until the track ends. Server order is
    /// re-sorted here, so a payload that arrives unordered still resolves.
    static func currentLine(in lines: [LyricLine], at time: Double) -> LyricLine? {
        let timedLines = lines
            .filter { $0.start != nil }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        for line in timedLines.reversed() {
            if let start = Ticks.seconds(fromTicks: line.start), start <= time {
                return line
            }
        }
        return nil
    }
}