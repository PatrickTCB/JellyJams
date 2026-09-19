#if os(iOS)
import AppIntents
import Foundation

/// The owner of a playlist, as far as the audio schema describes one.
/// Jellyfin does not expose playlist ownership to clients, so the value is
/// declared (the schema property requires the type) but never populated.
@UnionValue
enum PlaylistOwnerUnion {
    case curator(String)
    case person(IntentPerson)
}

/// A playlist in the Jellyfin library, in the form Siri understands.
///
/// Schema properties are computed from the stored ``item`` snapshot. An entity
/// with no item is a synthetic playlist — see ``FavouriteSongsPlaylist``.
@AppEntity(schema: .audio.playlist)
struct PlaylistEntity {
    static let defaultQuery = PlaylistQuery()

    // MARK: Schema properties

    @ComputedProperty
    var title: String {
        if let item { return item.displayName }
        return id == FavouriteSongsPlaylist.id ? FavouriteSongsPlaylist.title : "Unknown Playlist"
    }
    @ComputedProperty
    var owner: PlaylistOwnerUnion? { nil }
    @ComputedProperty
    var trackCount: Int { item?.childCount ?? 0 }
    @ComputedProperty
    var totalDuration: TimeInterval { item?.runtimeSeconds ?? 0 }
    @ComputedProperty
    var createdByMe: Bool? { nil }
    @ComputedProperty
    var curatedForMe: Bool? { nil }

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

    /// Builds a playlist entity that has no server-side counterpart, such as
    /// ``FavouriteSongsPlaylist``.
    init(id: String) {
        self.id = id
        item = nil
        artworkURL = nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: trackCount > 0 ? "\(trackCount) songs" : "playlist",
            synonyms: ["\(title) playlist"]
        ) {
            if let artworkURL {
                DisplayRepresentation.Image(url: artworkURL)
            } else {
                DisplayRepresentation.Image(systemName: "music.note.list")
            }
        }
    }
}

extension PlaylistEntity: Equatable {
    static func == (lhs: PlaylistEntity, rhs: PlaylistEntity) -> Bool { lhs.id == rhs.id }
}

extension PlaylistEntity: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Favourite songs pseudo-playlist

/// The playlist handed to Siri for open-ended "play something" requests.
///
/// It has no server-side counterpart: ``PlayAudioIntent`` recognises the id
/// and plays a shuffle of the user's favourite songs (all songs when nothing
/// is favourited). Encoding this as a real entity means the behaviour
/// survives the system's identifier-based rehydration, which would strip any
/// in-memory marker.
enum FavouriteSongsPlaylist {
    static let id = "jellyjams.favourite-songs"
    static let title = "Favourite Songs"

    static func entity() -> PlaylistEntity {
        PlaylistEntity(id: id)
    }
}

// MARK: - PlaylistQuery

/// Rehydrates playlist entities from the server when Siri asks for a
/// previously resolved playlist. The synthetic favourites playlist resolves
/// without a server.
struct PlaylistQuery {}

extension PlaylistQuery: EntityQuery {
    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        var entities: [PlaylistEntity] = []
        let client = await AppServices.shared.session.client
        for id in identifiers {
            if id == FavouriteSongsPlaylist.id {
                entities.append(FavouriteSongsPlaylist.entity())
                continue
            }
            if let client, let item = try await client.item(byId: id), item.itemType == .playlist {
                entities.append(PlaylistEntity(item: item, artworkURL: client.artworkURL(for: item, size: 600)))
            }
        }
        return entities
    }

    /// The favourites shuffle plus every server playlist, prefilling the
    /// Shortcuts parameter picker before any search text is typed.
    func suggestedEntities() async throws -> [PlaylistEntity] {
        var entities = [FavouriteSongsPlaylist.entity()]
        let client = await AppServices.shared.session.client
        guard let client else { return entities }
        let result = try await client.getItems(
            includeItemTypes: [.playlist], mediaTypes: [.audio], recursive: true, sortBy: .sortName, sortOrder: .ascending, limit: 25
        )
        entities.append(contentsOf: (result.items ?? []).map {
            PlaylistEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))
        })
        return entities
    }
}

extension PlaylistQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        var entities: [PlaylistEntity] = []
        if string.localizedCaseInsensitiveContains("favourite") || string.localizedCaseInsensitiveContains("favorite") {
            entities.append(FavouriteSongsPlaylist.entity())
        }
        let client = await AppServices.shared.session.client
        guard let client else { return entities }
        let result = try await client.getItems(
            includeItemTypes: [.playlist], mediaTypes: [.audio], recursive: true, searchTerm: string, limit: 10
        )
        entities.append(contentsOf: (result.items ?? []).map {
            PlaylistEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))
        })
        return entities
    }
}
#endif
