import Foundation
import JellyfinAPI

/// Immutable authenticated session details.
struct ServerCredentials: Sendable, Hashable {
    var userId: String
    var token: String
}

/// App-level access to Jellyfin built entirely on the official Swift SDK.
final class JellyfinService: Sendable {
    let baseURL: URL
    let deviceInfo: DeviceInfo
    let credentials: ServerCredentials?
    private let apiClient: JellyfinAPI.JellyfinClient

    private static let defaultFields: [JellyfinAPI.ItemFields] = [
        .genres,
        .dateCreated,
        .childCount,
        .parentID,
        .primaryImageAspectRatio,
        .overview,
        .mediaSources,
    ]

    /// Upper bound when expanding a collection (album/artist/genre) to tracks.
    private static let maxCollectionTracks = 500
    private static let maxPlaylists = 500
    /// Jellyfin passes playlist additions as a query string, so long selections
    /// are sent in batches to stay clear of server URL length limits.
    private static let playlistBatchSize = 100

    init(
        baseURL: URL,
        deviceInfo: DeviceInfo,
        credentials: ServerCredentials? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.baseURL = baseURL
        self.deviceInfo = deviceInfo
        self.credentials = credentials

        let networkConfiguration: URLSessionConfiguration
        if let sessionConfiguration {
            networkConfiguration = sessionConfiguration
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = true
            networkConfiguration = config
        }

        apiClient = JellyfinAPI.JellyfinClient(
            configuration: .init(
                url: baseURL,
                accessToken: credentials?.token,
                client: deviceInfo.clientName,
                deviceName: deviceInfo.deviceName,
                deviceID: deviceInfo.deviceId,
                version: deviceInfo.version
            ),
            sessionConfiguration: networkConfiguration
        )
    }

    func authenticated(with credentials: ServerCredentials) -> JellyfinService {
        JellyfinService(baseURL: baseURL, deviceInfo: deviceInfo, credentials: credentials)
    }

    var userId: String? { credentials?.userId }

    private func requireUserId() throws -> String {
        guard let userId = credentials?.userId else { throw JellyfinError.notAuthenticated }
        return userId
    }

    private func validated(_ result: BaseItemDtoQueryResult) throws -> BaseItemDtoQueryResult {
        guard (result.items ?? []).allSatisfy({ $0.id != nil }) else {
            throw JellyfinError.missingItemIdentifier
        }
        return result
    }

    // MARK: - Auth & server

    func publicSystemInfo() async throws -> JellyfinAPI.PublicSystemInfo {
        try await apiClient.send(Paths.getPublicSystemInfo).value
    }

    func authenticateByName(username: String, password: String) async throws -> JellyfinAPI.AuthenticationResult {
        try await apiClient.signIn(username: username, password: password)
    }

    func logout() async throws {
        try await apiClient.send(Paths.reportSessionEnded)
    }

    // MARK: - Library

    func getItems(
        parentId: String? = nil,
        includeItemTypes: [ItemType]? = nil,
        mediaTypes: [MediaType]? = nil,
        recursive: Bool? = nil,
        sortBy: SortBy? = nil,
        sortOrder: SortOrder? = nil,
        searchTerm: String? = nil,
        filters: [ItemFilter]? = nil,
        genres: [String]? = nil,
        genreIds: [String]? = nil,
        artistIds: [String]? = nil,
        albumArtistIds: [String]? = nil,
        albumIds: [String]? = nil,
        startIndex: Int? = nil,
        limit: Int? = nil,
        fields: [JellyfinAPI.ItemFields]? = JellyfinService.defaultFields
    ) async throws -> BaseItemDtoQueryResult {
        let userId = try requireUserId()
        let request = Paths.getItems(
            parameters: .init(
                userID: userId,
                startIndex: startIndex,
                limit: limit,
                isRecursive: recursive,
                searchTerm: searchTerm,
                sortOrder: sortOrder.map { [$0] },
                parentID: parentId,
                fields: fields,
                includeItemTypes: includeItemTypes,
                filters: filters,
                mediaTypes: mediaTypes,
                sortBy: sortBy?.sdkValues,
                genres: genres,
                enableUserData: true,
                artistIDs: artistIds,
                albumArtistIDs: albumArtistIds,
                albumIDs: albumIds,
                genreIDs: genreIds,
                enableTotalRecordCount: true,
                enableImages: true
            )
        )
        let result = try await apiClient.send(request).value
        return try validated(result)
    }

    func getAlbumArtists(
        searchTerm: String? = nil,
        sortBy: SortBy? = .sortName,
        sortOrder: SortOrder? = .ascending,
        filters: [ItemFilter]? = nil,
        startIndex: Int? = nil,
        limit: Int? = nil
    ) async throws -> BaseItemDtoQueryResult {
        try await getItems(
            includeItemTypes: [.musicArtist],
            recursive: true,
            sortBy: sortBy,
            sortOrder: sortOrder,
            searchTerm: searchTerm,
            filters: filters,
            startIndex: startIndex,
            limit: limit
        )
    }

    func getGenres(
        searchTerm: String? = nil,
        startIndex: Int? = nil,
        limit: Int? = nil
    ) async throws -> BaseItemDtoQueryResult {
        let userId = try requireUserId()
        let request = Paths.getGenres(
            parameters: .init(
                startIndex: startIndex,
                limit: limit,
                searchTerm: searchTerm,
                fields: [.primaryImageAspectRatio, .itemCounts],
                includeItemTypes: [.audio, .musicGenre],
                userID: userId,
                sortBy: [.sortName],
                sortOrder: [.ascending],
                enableImages: true,
                enableTotalRecordCount: true
            )
        )
        let result = try await apiClient.send(request).value
        return try validated(result)
    }

    // MARK: - Similar items

    /// Albums the server considers similar to `itemId` (`/Albums/{id}/Similar`).
    func getSimilarAlbums(itemId: String?, limit: Int) async throws -> BaseItemDtoQueryResult {
        let userId = try requireUserId()
        guard let itemId else { throw JellyfinError.missingItemIdentifier }
        let request = Paths.getSimilarAlbums(
            itemID: itemId,
            parameters: .init(userID: userId, limit: limit, fields: Self.defaultFields)
        )
        let result = try await apiClient.send(request).value
        return try validated(result)
    }

    /// Artists the server considers similar to `itemId` (`/Artists/{id}/Similar`).
    func getSimilarArtists(itemId: String?, limit: Int) async throws -> BaseItemDtoQueryResult {
        let userId = try requireUserId()
        guard let itemId else { throw JellyfinError.missingItemIdentifier }
        let request = Paths.getSimilarArtists(
            itemID: itemId,
            parameters: .init(userID: userId, limit: limit, fields: Self.defaultFields)
        )
        let result = try await apiClient.send(request).value
        return try validated(result)
    }

    func getPlaylistItems(playlistId: String?) async throws -> BaseItemDtoQueryResult {
        let userId = try requireUserId()
        guard let playlistId else { throw JellyfinError.missingItemIdentifier }
        let request = Paths.getPlaylistItems(
            playlistID: playlistId,
            parameters: .init(
                userID: userId,
                fields: Self.defaultFields,
                enableImages: true,
                enableUserData: true
            )
        )
        let result = try await apiClient.send(request).value
        return try validated(result)
    }

    /// Resolves every audio track belonging to a collection item (album,
    /// artist, playlist or genre) in its natural playback order. An item that
    /// is already a track resolves to itself.
    func tracks(for item: BaseItemDto) async throws -> [BaseItemDto] {
        guard let itemId = item.id else { throw JellyfinError.missingItemIdentifier }
        switch item.itemType {
        case .audio:
            return [item]
        case .playlist:
            return try await getPlaylistItems(playlistId: itemId).items ?? []
        case .musicArtist:
            return try await getItems(
                includeItemTypes: [.audio],
                recursive: true,
                sortBy: .album,
                sortOrder: .ascending,
                artistIds: [itemId],
                limit: Self.maxCollectionTracks
            ).items ?? []
        // Jellyfin labels genre entries `Genre` when they come from `/Genres`
        // and `MusicGenre` from the music-specific endpoints. They are the same
        // entity, so a genre filters tracks rather than parenting them.
        case let type? where type.isGenre:
            return try await getItems(
                includeItemTypes: [.audio],
                recursive: true,
                sortBy: .album,
                sortOrder: .ascending,
                genreIds: [itemId],
                limit: Self.maxCollectionTracks
            ).items ?? []
        default:
            return try await getItems(
                parentId: itemId,
                includeItemTypes: [.audio],
                recursive: true,
                sortBy: .discAndTrack,
                sortOrder: .ascending,
                limit: Self.maxCollectionTracks
            ).items ?? []
        }
    }

    // MARK: - Playlists

    func getPlaylists() async throws -> [BaseItemDto] {
        try await getItems(
            includeItemTypes: [.playlist],
            mediaTypes: [.audio],
            recursive: true,
            sortBy: .sortName,
            sortOrder: .ascending,
            limit: Self.maxPlaylists
        ).items ?? []
    }

    func addItemsToPlaylist(playlistId: String?, itemIds: [String]) async throws {
        let userId = try requireUserId()
        guard let playlistId, !itemIds.isEmpty else { throw JellyfinError.missingItemIdentifier }
        for chunk in itemIds.chunked(into: Self.playlistBatchSize) {
            _ = try await apiClient.send(
                Paths.addItemToPlaylist(playlistID: playlistId, parameters: .init(ids: chunk, userID: userId))
            )
        }
    }

    /// Creates a new audio playlist seeded with `itemIds` and returns its id.
    @discardableResult
    func createPlaylist(name: String, itemIds: [String]) async throws -> String {
        let userId = try requireUserId()
        let seed = Array(itemIds.prefix(Self.playlistBatchSize))
        let body = JellyfinAPI.CreatePlaylistDto(
            ids: seed.isEmpty ? nil : seed,
            isPublic: false,
            mediaType: .audio,
            name: name,
            userID: userId
        )
        let result = try await apiClient.send(Paths.createPlaylist(body)).value
        guard let playlistId = result.id else { throw JellyfinError.missingItemIdentifier }
        let remaining = Array(itemIds.dropFirst(seed.count))
        if !remaining.isEmpty {
            try await addItemsToPlaylist(playlistId: playlistId, itemIds: remaining)
        }
        return playlistId
    }

    // MARK: - Favourites

    func setFavourite(itemId: String?, isFavorite: Bool) async throws {
        let userId = try requireUserId()
        guard let itemId else { throw JellyfinError.missingItemIdentifier }
        if isFavorite {
            _ = try await apiClient.send(Paths.markFavoriteItem(itemID: itemId, userID: userId))
        } else {
            _ = try await apiClient.send(Paths.unmarkFavoriteItem(itemID: itemId, userID: userId))
        }
    }

    // MARK: - Playback reporting

    func reportPlaybackStart(_ info: PlaybackStateInfo) async throws {
        try await apiClient.send(Paths.reportPlaybackStart(info))
    }

    func reportPlaybackProgress(_ info: PlaybackStateInfo) async throws {
        try await apiClient.send(Paths.reportPlaybackProgress(info))
    }

    func reportPlaybackStopped(_ info: PlaybackStopInfo) async throws {
        try await apiClient.send(Paths.reportPlaybackStopped(info))
    }

    // MARK: - URL builders

    func streamURL(
        itemId: String?,
        mediaSourceId: String?,
        playSessionId: String? = nil
    ) throws -> URL {
        guard let itemId else { throw JellyfinError.missingItemIdentifier }
        let request = Paths.getAudioStream(
            itemID: itemId,
            parameters: .init(
                isStatic: true,
                playSessionID: playSessionId,
                mediaSourceID: mediaSourceId,
                deviceID: deviceInfo.deviceId,
                allowAudioStreamCopy: true
            )
        )
        guard let url = apiClient.url(with: request, queryAPIKey: true) else {
            throw JellyfinError.invalidMediaURL
        }
        return url
    }

    func artworkURL(
        itemId: String?,
        tag: String? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        quality: Int = 90,
        type: JellyfinAPI.ImageType = .primary
    ) -> URL? {
        guard let itemId else { return nil }
        let request = Paths.getItemImage(
            itemID: itemId,
            imageType: type.rawValue,
            parameters: .init(
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                quality: quality,
                tag: tag,
                format: .jpg
            )
        )
        return apiClient.url(with: request, queryAPIKey: true)
    }

    func artworkURL(for item: BaseItemDto, size: Int) -> URL? {
        if let tag = item.primaryImageTag {
            return artworkURL(itemId: item.id, tag: tag, maxWidth: size, maxHeight: size)
        }
        if let albumId = item.albumID, let tag = item.albumPrimaryImageTag {
            return artworkURL(itemId: albumId, tag: tag, maxWidth: size, maxHeight: size)
        }
        switch item.itemType {
        case .musicAlbum, .musicArtist, .playlist:
            return artworkURL(itemId: item.id, maxWidth: size, maxHeight: size)
        case let type? where type.isGenre:
            return artworkURL(itemId: item.id, maxWidth: size, maxHeight: size)
        default:
            return nil
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
