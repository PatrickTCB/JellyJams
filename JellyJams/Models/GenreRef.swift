import Foundation
import JellyfinAPI

/// A reference to one of the library's genres.
///
/// Genre metadata reaches the client in two shapes. `genreItems` carries id and
/// name pairs, which is what we want: filtering by id is exact, and it sidesteps
/// the `|` character Jellyfin uses to delimit its name-based genre filter. Items
/// fetched without the `Genres` field — or served by a server that omits the
/// pairs — supply only `genres`, a bare list of names. This type collapses both
/// into one shape so views never branch on which arrived, and
/// ``LibraryRepository`` picks the matching filter.
struct GenreRef: Hashable, Sendable, Identifiable {
    /// The genre's library identifier, when the server supplied one.
    let genreId: String?
    let name: String

    /// Stable across both shapes. Genre names are unique within a library, so
    /// falling back to the name still identifies the genre uniquely.
    var id: String { genreId ?? name }

    init(id: String? = nil, name: String) {
        self.genreId = id
        self.name = name
    }

    /// Builds a reference from a `MusicGenre` item, such as a search result.
    /// Fails for an unnamed genre, which nothing downstream could display or
    /// filter by.
    init?(item: BaseItemDto) {
        guard let name = item.name, !name.isEmpty else { return nil }
        self.init(id: item.id, name: name)
    }
}

extension ItemType {
    /// Jellyfin has two kinds for one concept: `/Genres` returns `Genre` while
    /// the music-specific endpoints return `MusicGenre`. A switch that handles
    /// only one is how a genre search result ends up on the "Unsupported Item"
    /// screen, so every genre decision goes through here.
    var isGenre: Bool { self == .genre || self == .musicGenre }
}

extension BaseItemDto {
    /// The item's genres, preferring the id-carrying `genreItems` over the
    /// name-only `genres`. Unnamed entries are dropped and duplicates collapse,
    /// so the result is ready to render.
    var genreRefs: [GenreRef] {
        let paired = (genreItems ?? []).compactMap { pair -> GenreRef? in
            guard let name = pair.name, !name.isEmpty else { return nil }
            return GenreRef(id: pair.id, name: name)
        }
        guard paired.isEmpty else { return paired.uniquedByName }
        return (genres ?? [])
            .filter { !$0.isEmpty }
            .map { GenreRef(name: $0) }
            .uniquedByName
    }
}

extension Sequence where Element == GenreRef {
    /// Drops later genres whose name repeats one already seen, ignoring case.
    /// A server can list the same genre under both shapes or with inconsistent
    /// casing, and a duplicated chip would offer the user the same destination
    /// twice.
    var uniquedByName: [GenreRef] {
        var seen: Set<String> = []
        return filter { seen.insert($0.name.lowercased()).inserted }
    }
}
