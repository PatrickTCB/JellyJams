#if os(iOS)
import Foundation

/// The Jellyfin-side search behind Siri's audio requests.
///
/// Siri delivers a free-form phrase ("Whiplash by Architects"); this maps it
/// onto library queries and ranks the candidates. ``AudioSearchQuery`` shares
/// the pipeline, so Siri resolves voice requests through the exact same code
/// path that used to live in ``SearchAndPlayIntent``.
enum SiriAudioSearch {

    /// Candidates for a spoken or typed query, best matches first: songs,
    /// then albums, then artists, then playlists.
    static func search(matching query: String, client: JellyfinService) async throws -> [AudioEntity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // The request commonly arrives as "Title by Artist". Jellyfin's
        // search is literal, so the full phrase would never match; splitting
        // on the last " by " lets both halves be searched properly. The last
        // occurrence is the separator, so titles containing " by" still
        // resolve.
        if let separator = trimmed.range(of: " by ", options: [.caseInsensitive, .backwards]),
           separator.lowerBound != trimmed.startIndex,
           separator.upperBound != trimmed.endIndex {
            let titlePart = trimmed[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let artistPart = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespaces)

            if let targeted = try await targetedSearch(title: titlePart, artist: artistPart, client: client),
               !targeted.isEmpty {
                return targeted
            }
            // Nothing matched the title-and-artist reading; fall through to a
            // plain search, first with the whole phrase, then title-only if
            // even that found nothing.
            let general = try await generalSearch(term: trimmed, client: client)
            if !general.isEmpty { return general }
            return try await generalSearch(term: titlePart, client: client)
        }

        return try await generalSearch(term: trimmed, client: client)
    }

    /// Songs and albums matching a title within a specific artist's work,
    /// with the artist itself as a further candidate.
    private static func targetedSearch(
        title: String,
        artist: String,
        client: JellyfinService
    ) async throws -> [AudioEntity]? {
        let artists = try await client.getAlbumArtists(searchTerm: artist, limit: 5).items ?? []
        let artistIds = artists.compactMap(\.id)
        guard !artistIds.isEmpty else { return nil }

        async let songs = client.getItems(
            includeItemTypes: [.audio],
            recursive: true,
            searchTerm: title,
            artistIds: artistIds,
            limit: 12
        )
        async let albums = client.getItems(
            includeItemTypes: [.musicAlbum],
            recursive: true,
            searchTerm: title,
            albumArtistIds: artistIds,
            limit: 6
        )
        let (songItems, albumItems) = try await (songs, albums)

        let songEntities: [AudioEntity] = (songItems.items ?? []).map {
            .song(SongEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600)))
        }
        let albumEntities: [AudioEntity] = (albumItems.items ?? []).map {
            .album(AlbumEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600)))
        }
        let artistEntities: [AudioEntity] = artists.map {
            .artist(ArtistEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600)))
        }
        return songEntities + albumEntities + artistEntities
    }

    /// A literal search across every playable kind, songs first.
    private static func generalSearch(term: String, client: JellyfinService) async throws -> [AudioEntity] {
        async let songs = client.getItems(
            includeItemTypes: [.audio], recursive: true, searchTerm: term, limit: 20
        )
        async let albums = client.getItems(
            includeItemTypes: [.musicAlbum], recursive: true, searchTerm: term, limit: 10
        )
        async let artists = client.getAlbumArtists(searchTerm: term, limit: 8)
        async let playlists = client.getItems(
            includeItemTypes: [.playlist], mediaTypes: [.audio], recursive: true, searchTerm: term, limit: 5
        )
        let (songItems, albumItems, artistItems, playlistItems) = try await (songs, albums, artists, playlists)

        return (songItems.items ?? []).map { .song(SongEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))) }
            + (albumItems.items ?? []).map { .album(AlbumEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))) }
            + (artistItems.items ?? []).map { .artist(ArtistEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))) }
            + (playlistItems.items ?? []).map { .playlist(PlaylistEntity(item: $0, artworkURL: client.artworkURL(for: $0, size: 600))) }
    }
}
#endif
