import Foundation
import JellyfinAPI

typealias BaseItemDto = JellyfinAPI.BaseItemDto
typealias NameIDPair = JellyfinAPI.NameIDPair
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
        if let artists, !artists.isEmpty { return artists.joined(separator: ", ") }
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        return nil
    }
    
    var subtitleAlbumArtist: String? {
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        if let artists, !artists.isEmpty { return artists.joined(separator: ", ") }
        return nil
    }

    /// The sort key behind the Downloads "Album Artist (Track Order)" option:
    /// album artist, then album, then disc and track number, flattened into
    /// one string. Numbers are zero-padded and missing ones sink as `999`, so
    /// plain string comparison matches numeric order — and each album's
    /// tracks stay together, in order.
    var albumArtistSort: String {
        let artist: String
        if let albumArtist, !albumArtist.isEmpty {
            artist = albumArtist
        } else if let first = artists?.first, !first.isEmpty {
            artist = first
        } else {
            artist = ""
        }

        func padded(_ number: Int?) -> String {
            number.map { String(format: "%03d", $0) } ?? "999"
        }

        return [artist, album ?? "", padded(parentIndexNumber), padded(indexNumber)]
            .joined(separator: " - ")
    }

    var primaryImageTag: String? {
        imageTags?[JellyfinAPI.ImageType.primary.rawValue]
    }

    var mediaSourceID: String? {
        mediaSources?.first?.id
    }

    /// A minimal artist item that can be pushed to open this item's artist
    /// page: an album's first album artist, a song's first track artist. The
    /// id is what routing loads by, so a stub carries a full page (see
    /// ``AlbumDetailView``). `nil` when no artist carries an id to route on.
    var artistNavigationItem: BaseItemDto? {
        guard let pair = itemType == .musicAlbum ? albumArtists?.first : artistItems?.first,
              let id = pair.id
        else { return nil }
        return BaseItemDto(id: id, name: pair.name, type: .musicArtist)
    }

    /// A minimal album item that can be pushed to open the album this song
    /// belongs to, or `nil` for anything without an album id.
    var albumNavigationItem: BaseItemDto? {
        guard let id = albumID else { return nil }
        return BaseItemDto(id: id, name: album, type: .musicAlbum)
    }
}
