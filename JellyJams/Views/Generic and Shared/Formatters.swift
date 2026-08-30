import Foundation

enum Format {
    /// Formats a duration in seconds as `m:ss` or `h:mm:ss`.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func songCount(_ count: Int?) -> String {
        let n = count ?? 0
        return n == 1 ? "1 song" : "\(n) songs"
    }

    static func albumCount(_ count: Int?) -> String {
        let n = count ?? 0
        return n == 1 ? "1 album" : "\(n) albums"
    }
}
