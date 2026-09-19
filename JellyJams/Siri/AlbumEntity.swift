#if os(iOS)
import AppIntents
import Foundation

/// An album in the Jellyfin library, in the form Siri understands.
///
/// `songs` is deliberately empty: Siri only needs the album's identity to hand
/// it to ``PlayAudioIntent``, which fetches the track list itself when
/// performing. Schema properties are computed from the stored ``item``
/// snapshot.
@AppEntity(schema: .audio.album)
struct AlbumEntity {
    static let defaultQuery = AlbumQuery()

    // MARK: Schema properties

    @ComputedProperty
    var title: String { item?.displayName ?? "Unknown" }
    @ComputedProperty
    var artistName: String { item?.subtitleAlbumArtist ?? "Unknown Artist" }
    @ComputedProperty
    var artists: [ArtistEntity] {
        (item?.albumArtists ?? []).compactMap { pair in
            pair.name.map(ArtistEntity.init(name:))
        }
    }
    @ComputedProperty
    var songs: [SongEntity] { [] }
    @ComputedProperty
    var universalProductCode: String? { nil }

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
            synonyms: ["album \(title)", "\(artistName) album \(title)"]
        ) {
            if let artworkURL {
                DisplayRepresentation.Image(url: artworkURL)
            } else {
                DisplayRepresentation.Image(systemName: "music.note.square.stack")
            }
        }
    }
}

extension AlbumEntity: Equatable {
    static func == (lhs: AlbumEntity, rhs: AlbumEntity) -> Bool { lhs.id == rhs.id }
}

extension AlbumEntity: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - AlbumQuery

/// Rehydrates album entities from the server when Siri asks for a
/// previously resolved album.
struct AlbumQuery {}

extension AlbumQuery: EntityQuery {
    func entities(for identifiers: [AlbumEntity.ID]) async throws -> [AlbumEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }
        var entities: [AlbumEntity] = []
        for id in identifiers {
            if let item = try await client.item(byId: id), item.itemType == .musicAlbum {
                entities.append(AlbumEntity(item: item, artworkURL: client.artworkURL(for: item, size: 600)))
            }
        }
        return entities
    }

    /// Recently added albums, prefilling the Shortcuts parameter picker
    /// before any search text is typed.
    func suggestedEntities() async throws -> [AlbumEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }
        let result = try await client.getItems(
            includeItemTypes: [.musicAlbum],
            recursive: true,
            sortBy: .dateCreated,
            sortOrder: .descending,
            limit: 25
        )
        return (result.items ?? []).map {
            AlbumEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))
        }
    }
}

extension AlbumQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [AlbumEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }
        let result = try await client.getItems(
            includeItemTypes: [.musicAlbum], recursive: true, searchTerm: string, limit: 10
        )
        return (result.items ?? []).map {
            AlbumEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))
        }
    }
}
#endif
