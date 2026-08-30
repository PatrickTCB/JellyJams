import Foundation
import JellyfinAPI

/// Sort choices exposed by the app, mapped to the SDK's ordered sort fields.
enum SortBy: String, Codable, Sendable, CaseIterable, Identifiable {
    case sortName = "SortName"
    case albumArtist = "AlbumArtist,SortName"
    case album = "Album,SortName"
    case artist = "Artist,SortName"
    case dateCreated = "DateCreated,SortName"
    case datePlayed = "DatePlayed,SortName"
    case playCount = "PlayCount,SortName"
    case productionYear = "ProductionYear,PremiereDate,SortName"
    case communityRating = "CommunityRating,SortName"
    case random = "Random"
    case runtime = "Runtime,SortName"
    /// Album track ordering (disc then track number). Not shown in sort menus.
    case discAndTrack = "ParentIndexNumber,IndexNumber,SortName"

    var id: String { rawValue }

    var sdkValues: [JellyfinAPI.ItemSortBy] {
        switch self {
        case .sortName: [.sortName]
        case .albumArtist: [.albumArtist, .sortName]
        case .album: [.album, .sortName]
        case .artist: [.artist, .sortName]
        case .dateCreated: [.dateCreated, .sortName]
        case .datePlayed: [.datePlayed, .sortName]
        case .playCount: [.playCount, .sortName]
        case .productionYear: [.productionYear, .premiereDate, .sortName]
        case .communityRating: [.communityRating, .sortName]
        case .random: [.random]
        case .runtime: [.runtime, .sortName]
        case .discAndTrack: [.parentIndexNumber, .indexNumber, .sortName]
        }
    }

    var displayName: String {
        switch self {
        case .sortName: return "Name"
        case .albumArtist: return "Album Artist"
        case .album: return "Album"
        case .artist: return "Artist"
        case .dateCreated: return "Date Added"
        case .datePlayed: return "Date Played"
        case .playCount: return "Play Count"
        case .productionYear: return "Year"
        case .communityRating: return "Rating"
        case .random: return "Random"
        case .runtime: return "Runtime"
        case .discAndTrack: return "Track Order"
        }
    }
}

extension JellyfinAPI.SortOrder {
    var toggled: SortOrder { self == .ascending ? .descending : .ascending }
}

extension JellyfinAPI.RepeatMode {
    var systemImage: String {
        switch self {
        case .repeatNone: return "repeat"
        case .repeatOne: return "repeat.1"
        case .repeatAll: return "repeat"
        }
    }
}

/// Tick helpers. Jellyfin expresses durations/positions in ticks where
/// 10,000,000 ticks == 1 second.
enum Ticks {
    static let perSecond = 10_000_000

    static func seconds(fromTicks ticks: Int?) -> Double? {
        guard let ticks else { return nil }
        return Double(ticks) / Double(perSecond)
    }

    static func ticks(fromSeconds seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        let ticks = (seconds * Double(perSecond)).rounded()
        if ticks >= Double(Int.max) { return .max }
        if ticks <= Double(Int.min) { return .min }
        return Int(ticks)
    }
}
