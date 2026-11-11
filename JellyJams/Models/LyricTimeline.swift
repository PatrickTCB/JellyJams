import Foundation
import JellyfinAPI

/// A track's lyrics as the lyrics sheet reads them: the lines to show, and
/// which of them is being sung at a given moment.
///
/// Built once, when the lyrics arrive, so each tick of the player's clock
/// costs one lookup rather than a fresh filter and sort of everything the
/// server sent.
///
/// The server stamps each line with its start in ticks — ten million per
/// second — which are scaled to seconds here, once, to compare against the
/// player's clock. A line is current from its own start until the next one's,
/// and the last line holds until the track ends. Lines without a timestamp —
/// unsynced lyrics — are shown but never current. Blank lines aren't shown,
/// but a timestamped one still ends the line before it, so an instrumental
/// break highlights nothing.
struct LyricTimeline: Sendable, Equatable {
    /// The lines with words in them, in the order the server sent them.
    let lines: [String]
    /// The timestamped lines, earliest first.
    private let cues: [Cue]

    private struct Cue: Sendable, Equatable {
        /// Seconds into the track.
        let start: Double
        /// The line's position in ``LyricTimeline/lines``, or nil for a blank
        /// line: a stretch where nothing is sung.
        let line: Int?
    }

    /// The lines of `lyrics`, or none at all for `nil` — a track the server
    /// has no lyrics for.
    init(_ lyrics: LyricDto? = nil) {
        var lines: [String] = []
        var cues: [Cue] = []
        for line in lyrics?.lyrics ?? [] {
            let text = line.text ?? ""
            let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isBlank { lines.append(text) }
            if let start = Ticks.seconds(fromTicks: line.start) {
                cues.append(Cue(start: start, line: isBlank ? nil : lines.count - 1))
            }
        }
        self.lines = lines
        // Sorted here, so lines that arrive out of order still resolve.
        self.cues = cues.sorted { $0.start < $1.start }
    }

    var isEmpty: Bool { lines.isEmpty }

    /// The index into ``lines`` of the line being sung `time` seconds into the
    /// track — nil before the first line starts, during a blank line's break,
    /// and throughout lyrics that aren't timestamped.
    func currentLineIndex(at time: Double) -> Int? {
        cues.last { $0.start <= time }?.line
    }
}
