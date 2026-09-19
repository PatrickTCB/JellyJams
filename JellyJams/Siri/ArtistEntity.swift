#if os(iOS)
import AppIntents
import Foundation

/// An artist in the Jellyfin library, in the form Siri understands.
///
/// `albums` and `songs` are deliberately empty: Siri only needs the artist's
/// identity; ``PlayAudioIntent`` fetches (and shuffles) the catalogue itself
/// when performing. Schema properties are computed from the stored ``item``
/// snapshot.
@AppEntity(schema: .audio.artist)
struct ArtistEntity {
    static let defaultQuery = ArtistQuery()

    // MARK: Schema properties

    /// The artist's name — the item's name when backed by a server item, and
    /// otherwise the id, which for decoration-only artists is the name.
    @ComputedProperty
    var name: String { item?.displayName ?? id }
    @ComputedProperty
    var albums: [AlbumEntity] { [] }
    @ComputedProperty
    var songs: [SongEntity] { [] }

    // MARK: Entity properties

    let id: String
    /// The server item this entity stands in for.
    var item: BaseItemDto?
    /// Artwork for Siri's result cards.
    var artworkURL: URL?

    /// A lightweight artist for decoration inside song and album entities,
    /// where only the name is known. The name doubles as the id.
    init(name: String) {
        id = name
        item = nil
        artworkURL = nil
    }

    init(item: BaseItemDto, artworkURL: URL?) {
        id = item.id ?? item.displayName
        self.item = item
        self.artworkURL = artworkURL
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)") {
            if let artworkURL {
                DisplayRepresentation.Image(url: artworkURL)
            } else {
                DisplayRepresentation.Image(systemName: "music.mic")
            }
        }
    }
}

extension ArtistEntity: Equatable {
    static func == (lhs: ArtistEntity, rhs: ArtistEntity) -> Bool { lhs.id == rhs.id }
}

extension ArtistEntity: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - ArtistQuery

/// Rehydrates artist entities from the server when Siri asks for a
/// previously resolved artist.
struct ArtistQuery {}

extension ArtistQuery: EntityQuery {
    func entities(for identifiers: [ArtistEntity.ID]) async throws -> [ArtistEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }
        var entities: [ArtistEntity] = []
        for id in identifiers {
            if let item = try await client.item(byId: id), item.itemType == .musicArtist {
                entities.append(ArtistEntity(item: item, artworkURL: client.artworkURL(for: item, size: 600)))
            }
        }
        return entities
    }

    /// A sample of artists, prefilling the Shortcuts parameter picker
    /// before any search text is typed.
    func suggestedEntities() async throws -> [ArtistEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }
        let result = try await client.getAlbumArtists(limit: 25)
        return (result.items ?? []).map {
            ArtistEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))
        }
    }
}

extension ArtistQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [ArtistEntity] {
        let client = await AppServices.shared.session.client
        guard let client else { return [] }
        let result = try await client.getAlbumArtists(searchTerm: string, limit: 10)
        return (result.items ?? []).map {
            ArtistEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))
        }
    }
}
#endif
