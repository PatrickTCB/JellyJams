import Foundation
import JellyfinAPI
@testable import JellyJams

enum TestFixtures {
    static func item(
        id: String,
        name: String? = nil,
        type: ItemType = .audio
    ) -> BaseItemDto {
        BaseItemDto(id: id, name: name ?? id, type: type)
    }

    /// An item carrying the server's favourite flag, as a real fetch does. The
    /// plain ``item(id:name:type:)`` has no `userData` at all, which stands in
    /// for the far more common "not favourited" answer.
    static func item(
        id: String,
        name: String? = nil,
        type: ItemType = .audio,
        isFavourite: Bool
    ) -> BaseItemDto {
        BaseItemDto(
            id: id,
            name: name ?? id,
            type: type,
            userData: UserItemDataDto(isFavorite: isFavourite, key: id)
        )
    }

    /// A client pointed at a closed local port. Building stream URLs succeeds,
    /// so queue state advances exactly as it does in the app, while any real
    /// request fails immediately without reaching the network.
    static func offlineClient() -> JellyfinService {
        JellyfinService(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            deviceInfo: deviceInfo,
            credentials: ServerCredentials(userId: "user-id", token: "token")
        )
    }

    /// A client whose requests are served by ``URLProtocolStub``.
    static func stubbedClient() -> JellyfinService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return JellyfinService(
            baseURL: URL(string: "https://example.com/jellyfin")!,
            deviceInfo: deviceInfo,
            credentials: ServerCredentials(userId: "user-id", token: "token"),
            sessionConfiguration: configuration
        )
    }

    /// A repository backed by ``stubbedClient()``.
    static func stubbedRepository() -> LibraryRepository {
        LibraryRepository(client: stubbedClient())
    }

    /// A repository with no client, standing in for the signed-out state.
    static func signedOutRepository() -> LibraryRepository {
        LibraryRepository(client: nil)
    }

    static let deviceInfo = DeviceInfo(
        clientName: "JellyJamsTests",
        version: "1",
        deviceName: "Test Mac",
        deviceId: "device-id"
    )
}
