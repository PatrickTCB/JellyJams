import Foundation
import JellyfinAPI

typealias BaseItemDto = JellyfinAPI.BaseItemDto
typealias BaseItemDtoQueryResult = JellyfinAPI.BaseItemDtoQueryResult
typealias ItemType = JellyfinAPI.BaseItemKind
typealias ItemFilter = JellyfinAPI.ItemFilter
typealias SortOrder = JellyfinAPI.SortOrder
typealias RepeatMode = JellyfinAPI.RepeatMode
typealias PlaybackStateInfo = JellyfinAPI.PlaybackStateInfo
typealias PlaybackStopInfo = JellyfinAPI.PlaybackStopInfo

extension JellyfinAPI.BaseItemDto {
    var itemType: ItemType? { type }

    var displayName: String {
        guard let name, !name.isEmpty else { return "Unknown" }
        return name
    }

    var isFavorite: Bool { userData?.isFavorite ?? false }

    var runtime: Duration? {
        guard let runTimeTicks else { return nil }
        return .seconds(Double(runTimeTicks) / Double(Ticks.perSecond))
    }

    var runtimeSeconds: Double? { Ticks.seconds(fromTicks: runTimeTicks) }

    var subtitleArtist: String? {
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        if let artists, !artists.isEmpty { return artists.joined(separator: ", ") }
        return nil
    }

    var primaryImageTag: String? {
        imageTags?[JellyfinAPI.ImageType.primary.rawValue]
    }

    var mediaSourceID: String? {
        mediaSources?.first?.id
    }
}
