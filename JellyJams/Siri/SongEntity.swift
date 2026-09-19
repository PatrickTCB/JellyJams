#if os(iOS)
import AppIntents
import Foundation

/// A track in the Jellyfin library, in the form Siri understands.
///
/// The schema properties are computed from the stored ``item`` snapshot. The
/// audio schema wraps its properties in `EntityProperty`, which has no usable
/// initializer, so custom inits can only assign plain stored properties —
/// computed schema properties are the pattern the schema supports.
@AppEntity(schema: .audio.song)
struct SongEntity {
    static let defaultQuery = SongQuery()

    // MARK: Schema properties

    @ComputedProperty
    var title: String { item?.displayName ?? "Unknown" }
    @ComputedProperty
    var artistName: String { item?.subtitleArtist ?? "Unknown Artist" }
    @ComputedProperty
    var albumTitle: String? { item?.album }
    @ComputedProperty
    var composerName: String? { nil }
    @ComputedProperty
    var internationalStandardRecordingCode: String? { nil }
    @ComputedProperty
    var album: AlbumEntity? { nil }
    @ComputedProperty
    var artists: [ArtistEntity] { (item?.artists ?? []).map(ArtistEntity.init(name:)) }
    @ComputedProperty
    var composers: [ArtistEntity] { [] }
    @ComputedProperty
    var duration: TimeInterval { item?.runtimeSeconds ?? 0 }

    // MARK: Entity properties

    let id: String
    /// The server item this entity stands in for.
    var item: BaseItemDto?
    /// Artwork for Siri's result cards.
    var artworkURL: URL?

    init(item: BaseItemDto, artworkURL: URL?) {
        id = item.id ?? item.displayName
        self.item = item
        self.artworkURL = artworkURL
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(artistName)",
            synonyms: ["\(title) by \(artistName)"]
        ) {
            if let artworkURL {
                DisplayRepresentation.Image(url: artworkURL)
            } else {
                DisplayRepresentation.Image(systemName: "music.note")
            }
        }
    }
}

extension SongEntity: Equatable {
    static func == (lhs: SongEntity, rhs: SongEntity) -> Bool { lhs.id == rhs.id }
}

extension SongEntity: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - SongQuery

/// Rehydrates song entities from the server when Siri asks for a previously
/// resolved track (disambiguation picks, Shortcuts runs).
struct SongQuery {}

extension SongQuery: EntityQuery {
    func entities(for identifiers: [SongEntity.ID]) async throws -> [SongEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }
        var entities: [SongEntity] = []
        for id in identifiers {
            if let item = try await client.item(byId: id), item.itemType == .audio {
                entities.append(SongEntity(item: item, artworkURL: client.artworkURL(for: item, size: 600)))
            }
        }
        return entities
    }

    /// Recently played songs, prefilling the Shortcuts parameter picker
    /// before any search text is typed.
    func suggestedEntities() async throws -> [SongEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }
        let result = try await client.getItems(
            includeItemTypes: [.audio],
            recursive: true,
            sortBy: .datePlayed,
            sortOrder: .descending,
            limit: 25
        )
        return (result.items ?? []).map {
            SongEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))
        }
    }
}

extension SongQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [SongEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }
        let result = try await client.getItems(
            includeItemTypes: [.audio], recursive: true, searchTerm: string, limit: 10
        )
        return (result.items ?? []).map {
            SongEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))
        }
    }
}
#endif
