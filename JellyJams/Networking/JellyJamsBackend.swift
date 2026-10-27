import Foundation

/// The Jellyfin sign-in, as the Jelly Jams Backend needs to receive it.
///
/// The backend validates these credentials against the server itself before
/// it saves the account, so the app hands over everything it holds: the
/// access token comes out of the Keychain at registration time rather than
/// being stored anywhere else.
struct JellyfinAccount: Sendable, Equatable {
    let userName: String
    let userID: String
    let userToken: String
    /// The base URL of the Jellyfin server, without a trailing slash.
    let jellyfinHost: URL
}

/// The backend's answer to a successful `POST /register`.
///
/// The field names are capitalised because that is how the backend writes
/// them; the coding keys translate. Kafka fields are carried for the events
/// integration later on — nothing in the app reads them yet, and registering
/// works whether the backend fills them or leaves them empty.
struct BackendRegistration: Codable, Sendable, Equatable {
    let user: String
    /// Whether this registration created the account or refreshed an
    /// existing one. The backend answers 200 for a known user and 201 for a
    /// new one; both are success.
    let created: Bool
    let saved: Bool
    /// The ending the backend gives the mixtape playlists it builds — what
    /// the app tells mixtapes apart by.
    let playlistSuffix: String
    let kafkaIP: String
    let kafkaPort: String

    private enum CodingKeys: String, CodingKey {
        case user = "User"
        case created = "Created"
        case saved = "Saved"
        case playlistSuffix = "PlaylistSuffix"
        case kafkaIP = "KafkaIP"
        case kafkaPort = "KafkaPort"
    }
}

enum BackendError: LocalizedError, Sendable, Equatable {
    case invalidServerURL
    case notSignedIn
    case rejected(status: Int, detail: String?)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The backend server address is not valid."
        case .notSignedIn:
            return "Registration hands your Jellyfin sign-in to the backend to be checked, so you need to be signed in first."
        case .rejected(let status, let detail):
            if let detail, !detail.isEmpty {
                return "The backend refused the registration (\(status)): \(detail)"
            }
            return "The backend refused the registration (status \(status))."
        }
    }
}

/// App-level access to the Jelly Jams Backend — the service that builds
/// Mixtapes, and later will extend queues, offer AI instant mixes, and take
/// bans.
///
/// Deliberately small for now: `/register` is the only endpoint the app
/// speaks. The other routes (`/tapes`, `/new-tape`, `/delete-tape`,
/// `/extend-queue`, `/ban`, `/instant-mix`) all key off the `userID` this
/// one hands over, so registration is the seam the rest of the integration
/// grows from.
final class JellyJamsBackend: Sendable {
    let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL,
        deviceInfo: DeviceInfo,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.baseURL = baseURL

        let networkConfiguration: URLSessionConfiguration
        if let sessionConfiguration {
            networkConfiguration = sessionConfiguration
        } else {
            let config = URLSessionConfiguration.default
            config.httpAdditionalHeaders = ["User-Agent": "\(deviceInfo.clientName)/\(deviceInfo.version) \(deviceInfo.deviceOS)"]
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = true
            networkConfiguration = config
        }
        JellyfinService.registerAuditProtocol(in: networkConfiguration)

        session = URLSession(configuration: networkConfiguration)
    }

    /// Normalises a typed-in backend address: trims whitespace, adds a
    /// scheme if missing, and removes trailing slashes.
    ///
    /// The default scheme is `https`, unlike Jellyfin's LAN-facing `http`
    /// default: the backend is an internet service by design, and someone
    /// running one on their LAN can type the scheme themselves.
    static func normalizeAddress(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BackendError.invalidServerURL }
        if !text.contains("://") { text = "https://" + text }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw BackendError.invalidServerURL
        }

        components.scheme = scheme
        while components.path.hasSuffix("/") { components.path.removeLast() }

        guard let url = components.url else { throw BackendError.invalidServerURL }
        return url
    }

    /// `POST /register` — save (or refresh) this sign-in with the backend,
    /// and get back the rules it works by, including the playlist-name
    /// ending its mixtapes carry.
    ///
    /// The backend validates the token against the Jellyfin server before
    /// storing anything, so a failure here means the sign-in was rejected
    /// or the backend could not reach the server — never a silent half-save.
    func register(_ account: JellyfinAccount) async throws -> BackendRegistration {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("register"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "userName", value: account.userName),
            URLQueryItem(name: "userID", value: account.userID),
            URLQueryItem(name: "userToken", value: account.userToken),
            URLQueryItem(name: "jellyfinHost", value: account.jellyfinHost.absoluteString),
        ]
        guard let url = components?.url else { throw BackendError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            var detail: String?
            if let errorBody = try? JSONDecoder().decode(BackendErrorResponse.self, from: data) {
                detail = errorBody.detail
            }
            throw BackendError.rejected(status: http.statusCode, detail: detail)
        }
        return try JSONDecoder().decode(BackendRegistration.self, from: data)
    }
}

/// The body FastAPI sends with its error responses; its `detail` is written
/// for humans, so it is shown rather than the bare status code.
private struct BackendErrorResponse: Decodable {
    let detail: String?
}
