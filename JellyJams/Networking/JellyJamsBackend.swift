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

/// The backend's answer about one account's Family Blend membership.
///
/// Unlike `/register`, this model's fields arrive lower-cased-first, so the
/// default coding keys fit as they are.
struct BackendFamilyBlend: Codable, Sendable, Equatable {
    let id: String
    let inFamilyBlend: Bool
}

/// The repeat limits the backend applies to one account's tapes: the most
/// tracks from a single album, and from a single artist, that may share a
/// generated mixtape.
///
/// Like ``BackendFamilyBlend``, this model's fields arrive lower-cased
/// first, so the default coding keys fit as they are. An account that has
/// never set limits is answered with the backend's own defaults — album 3,
/// artist 5 — so there is no first-read mystery for the app to paper over.
struct BackendLimits: Codable, Sendable, Equatable {
    let id: String
    let sameAlbumLimit: Int
    let sameArtistLimit: Int
}

/// The backend's answer to a `POST /ban`.
///
/// `Success` says the ban was recorded just now, `AlreadyBanned` that it was
/// on the books before — either way the item is banned from here on, and the
/// app reads the answer without acting on it. The echo in `Items` carries
/// the one banned item under its type; the bans screen reads the whole list
/// from ``BackendBans`` instead of leaning on this echo.
struct BackendBan: Codable, Sendable, Equatable {
    let success: Bool
    let alreadyBanned: Bool

    private enum CodingKeys: String, CodingKey {
        case success = "Success"
        case alreadyBanned = "AlreadyBanned"
    }
}

/// The banned items as `GET /bans` sorts them: three lists, by the kind of
/// Jellyfin item that was banned.
///
/// `Items` keys each category by its Jellyfin type name — `MusicArtist`,
/// `MusicAlbum`, `Audio` — and the entries are complete server DTOs, the
/// backend having fetched each ban from the user's own server; they arrive
/// as the app's own ``BaseItemDto``. A kind nobody has banned simply has no
/// entry in the dictionary. Other keys (a genre ban, say) are ignored: the
/// app's screens and menus only reach songs, albums and artists, so there
/// is nothing to show or unbannable from here for anything else.
struct BackendBans: Decodable, Sendable, Equatable {
    let artists: [BaseItemDto]
    let albums: [BaseItemDto]
    let songs: [BaseItemDto]

    init(artists: [BaseItemDto] = [], albums: [BaseItemDto] = [], songs: [BaseItemDto] = []) {
        self.artists = artists
        self.albums = albums
        self.songs = songs
    }

    private enum CodingKeys: String, CodingKey {
        case items = "Items"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decodeIfPresent([String: [BaseItemDto]].self, forKey: .items) ?? [:]
        artists = items["MusicArtist"] ?? []
        albums = items["MusicAlbum"] ?? []
        songs = items["Audio"] ?? []
    }
}

/// One tape the backend has been told to build: the recipe `GET /tapes`
/// answers with, and what the composer and the configured-tapes sheet show.
///
/// The four source switches arrive as the strings the backend stores them
/// as — lower-cased `"true"` and `"false"`, which is the shape its builder
/// reads back and compares against — and FastAPI's response model fills
/// every field, so the reader takes the contract as it is rather than
/// fishing for spellings this service never wrote.
struct BackendMixtape: Decodable, Sendable, Equatable {
    let name: String
    let usesRecents: Bool
    let usesFavourites: Bool
    let usesFingerprint: Bool
    let usesFreshAlchemy: Bool
    let alchemyPercent: Int
    let songCount: Int

    private enum CodingKeys: String, CodingKey {
        case name
        case recents
        case favourites
        case fingerprint
        case freshAlchemy
        case alchemyPercent
        case songCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        usesRecents = try Self.switchedOn(container, .recents)
        usesFavourites = try Self.switchedOn(container, .favourites)
        usesFingerprint = try Self.switchedOn(container, .fingerprint)
        usesFreshAlchemy = try Self.switchedOn(container, .freshAlchemy)
        alchemyPercent = try container.decode(Int.self, forKey: .alchemyPercent)
        songCount = try container.decode(Int.self, forKey: .songCount)
    }

    /// Whether a switch is on, read from the stored string the backend
    /// answers with.
    private static func switchedOn(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Bool {
        try container.decode(String.self, forKey: key) == "true"
    }
}

/// The whole `GET /tapes` answer. The `User` echo is dropped: the sheet
/// shows the account's own tapes and already knows whose they are.
struct BackendTapes: Decodable, Sendable, Equatable {
    let tapes: [BackendMixtape]

    private enum CodingKeys: String, CodingKey {
        case tapes = "Playlists"
    }

    init(tapes: [BackendMixtape] = []) {
        self.tapes = tapes
    }
}

/// A tape to ask the backend to build, as the composer form settles it.
struct BackendTapeDraft: Sendable, Equatable {
    var name: String
    var recents: Bool
    var favourites: Bool
    var fingerprint: Bool
    var freshAlchemy: Bool
    var alchemyPercent: Int
    var songCount: Int

    /// The least a tape needs to be worth sending: a name to build under,
    /// and songs to build of. The backend takes any integers it is handed,
    /// so the form's numbers are checked here rather than trusted there —
    /// a zero-song tape is a recipe for nothing.
    var isSendable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (0...100).contains(alchemyPercent)
            && songCount >= 1
    }
}

/// The backend's answer to a `POST /new-tape`.
///
/// `Created` says the recipe is on the books; `Updated` says it replaced a
/// same-named one rather than joining fresh company — the backend deletes
/// and rewrites either way, and the tape itself lands in the library when
/// the builder next runs, not in this answer.
struct BackendTapeCreated: Decodable, Sendable, Equatable {
    let created: Bool
    let updated: Bool
    let tape: BackendMixtape

    private enum CodingKeys: String, CodingKey {
        case created = "Created"
        case updated = "Updated"
        case tape = "Details"
    }
}

/// The backend's answer to a `DELETE /delete-tape` — which tape came off
/// the books. The row has already left the app's list by the time this
/// arrives, so the echo is confirmation, not news.
struct BackendTapeDeleted: Decodable, Sendable, Equatable {
    let deleted: Bool
    let name: String

    private enum CodingKeys: String, CodingKey {
        case deleted = "Deleted"
        case name = "Name"
    }
}

/// The backend's answer to both queue-extension endpoints: the ids of the
/// tracks to append, in the order they should play, and how many that is.
///
/// The field names are capitalised because that is how the backend writes
/// them. `Count` always agrees with the list beside it — the backend fills
/// both from the same songs — so the app reads the list and treats the count
/// as confirmation, not as a second source of truth.
struct BackendExtendedQueue: Decodable, Sendable, Equatable {
    let newTrackIDs: [String]
    let count: Int

    private enum CodingKeys: String, CodingKey {
        case newTrackIDs = "NewTrackIDs"
        case count = "Count"
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
                return "The backend refused the request (\(status)): \(detail)"
            }
            return "The backend refused the request (status \(status))."
        }
    }
}

/// App-level access to the Jelly Jams Backend — the companion service for
/// the app, whose features so far are building Mixtapes, the Family Blend,
/// taking bans, and extending running queues, and which will later offer AI
/// instant mixes.
///
/// Every endpoint but `/ping` keys off the `userID` that `/register` hands
/// over, so registration is the seam the rest of the integration grows
/// from — the app is not a backend account until a Save says so.
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

    /// A client for the address the settings hold — nil when there is none,
    /// or the text will not parse. Every screen that only *uses* the
    /// backend asks here instead of re-doing the normalisation dance; a
    /// refusal's *why* (no address, bad address) is for the settings sheet,
    /// which reads the raw text beside this to say it.
    static func configured(address: String, deviceInfo: DeviceInfo) -> JellyJamsBackend? {
        guard let url = try? normalizeAddress(address) else { return nil }
        return JellyJamsBackend(baseURL: url, deviceInfo: deviceInfo)
    }

    /// `POST /register` — save (or refresh) this sign-in with the backend,
    /// and get back the rules it works by, including the playlist-name
    /// ending its mixtapes carry.
    ///
    /// The backend validates the token against the Jellyfin server before
    /// storing anything, so a failure here means the sign-in was rejected
    /// or the backend could not reach the server — never a silent half-save.
    func register(_ account: JellyfinAccount) async throws -> BackendRegistration {
        let data = try await perform(
            .post,
            path: "register",
            queryItems: [
                URLQueryItem(name: "userName", value: account.userName),
                URLQueryItem(name: "userID", value: account.userID),
                URLQueryItem(name: "userToken", value: account.userToken),
                URLQueryItem(name: "jellyfinHost", value: account.jellyfinHost.absoluteString),
            ]
        )
        return try JSONDecoder().decode(BackendRegistration.self, from: data)
    }

    /// `GET /ping` — is this backend instance awake?
    ///
    /// Only the status is of interest: it answers 200 or it does not, and
    /// the settings sheet gates its feature switches on "it does". The
    /// body (a `PingPong`) is read and discarded.
    func ping() async throws {
        _ = try await perform(.get, path: "ping")
    }

    // MARK: - Family Blend

    /// `GET /family-blend` — whether this account is in the blend right now.
    ///
    /// The backend answers a read with 201 (it was copied from the write
    /// endpoints); any 2xx is success as far as the app is concerned.
    func familyBlendStatus(userID: String) async throws -> BackendFamilyBlend {
        let data = try await perform(.get, path: "family-blend", queryItems: familyBlendQuery(userID: userID))
        return try JSONDecoder().decode(BackendFamilyBlend.self, from: data)
    }

    /// `POST /family-blend` — join the blend, and the shared playlist that
    /// comes from it being built out of every member's listening.
    func joinFamilyBlend(userID: String) async throws -> BackendFamilyBlend {
        let data = try await perform(.post, path: "family-blend", queryItems: familyBlendQuery(userID: userID))
        return try JSONDecoder().decode(BackendFamilyBlend.self, from: data)
    }

    /// `DELETE /family-blend` — leave the blend.
    func leaveFamilyBlend(userID: String) async throws -> BackendFamilyBlend {
        let data = try await perform(.delete, path: "family-blend", queryItems: familyBlendQuery(userID: userID))
        return try JSONDecoder().decode(BackendFamilyBlend.self, from: data)
    }

    private func familyBlendQuery(userID: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "userID", value: userID),
            // The endpoint insists on an `itemID` because it was copied from
            // `/ban`'s signature; its handler never reads the value, but
            // FastAPI refuses the request without it — so an empty one goes
            // along, and FastAPI ignores unknown parameters whenever the
            // backend drops this one.
            URLQueryItem(name: "itemID", value: ""),
        ]
    }

    // MARK: - Repeat limits

    /// `GET /limits` — the repeat limits the backend keeps for this
    /// account: how many tracks from one album, and from one artist, may
    /// share a generated mixtape.
    ///
    /// An account that never set limits is answered with the backend's own
    /// defaults — album 3, artist 5 — rather than zeros, and the read
    /// comes back 201 like the blend status: copied from the write
    /// endpoint, so any 2xx is success as far as the app is concerned.
    func limits(userID: String) async throws -> BackendLimits {
        let data = try await perform(
            .get,
            path: "limits",
            queryItems: [URLQueryItem(name: "userID", value: userID)]
        )
        return try JSONDecoder().decode(BackendLimits.self, from: data)
    }

    /// `POST /limits` — the pair of limits to keep for this account. The
    /// backend always takes both numbers, so the number that did not
    /// change rides along as it was remembered; the integers travel as
    /// strings like everything else in the query. The answer is what the
    /// backend stored — clamped on read — so the app learns the standing
    /// numbers rather than assuming them.
    func setLimits(
        userID: String,
        sameAlbumLimit: Int,
        sameArtistLimit: Int
    ) async throws -> BackendLimits {
        let data = try await perform(
            .post,
            path: "limits",
            queryItems: [
                URLQueryItem(name: "userID", value: userID),
                URLQueryItem(name: "sameAlbumLimit", value: String(sameAlbumLimit)),
                URLQueryItem(name: "sameArtistLimit", value: String(sameArtistLimit)),
            ]
        )
        return try JSONDecoder().decode(BackendLimits.self, from: data)
    }

    // MARK: - Bans

    /// `POST /ban` — tell the backend to keep one item out of every playlist
    /// it generates for this user.
    ///
    /// The endpoint takes a bare Jellyfin item id and works out the kind for
    /// itself: stored bans are matched against the ids each candidate song
    /// carries — the song's own, its album's, its artists', its genres' — so
    /// a song, album or artist id bans exactly what it names, and the app
    /// never resolves a collection into song ids just to keep it out.
    func ban(userID: String, itemID: String) async throws -> BackendBan {
        let data = try await perform(
            .post,
            path: "ban",
            queryItems: [
                URLQueryItem(name: "userID", value: userID),
                URLQueryItem(name: "itemID", value: itemID),
            ]
        )
        return try JSONDecoder().decode(BackendBan.self, from: data)
    }

    /// `GET /bans` — everything the backend currently keeps out of the
    /// playlists it generates for this user, sorted into banned artists,
    /// albums and songs.
    func bans(userID: String) async throws -> BackendBans {
        let data = try await perform(
            .get,
            path: "bans",
            queryItems: [URLQueryItem(name: "userID", value: userID)]
        )
        return try Self.itemsDecoder().decode(BackendBans.self, from: data)
    }

    /// `DELETE /ban` — undo one ban, keyed on the item id it was made with.
    ///
    /// The backend answers whether the item had been banned (`AlreadyBanned`)
    /// and echoes it one more time; the app has already taken the row out of
    /// its own list, so the echo is read for success and discarded.
    func unban(userID: String, itemID: String) async throws -> BackendBan {
        let data = try await perform(
            .delete,
            path: "ban",
            queryItems: [
                URLQueryItem(name: "userID", value: userID),
                URLQueryItem(name: "itemID", value: itemID),
            ]
        )
        return try JSONDecoder().decode(BackendBan.self, from: data)
    }

    /// `DELETE /reset-bans` — undo every ban the user has, in one sweep.
    ///
    /// Success is the status: the cleared list is whatever the screen reads
    /// back from `GET /bans` next time it opens.
    func resetBans(userID: String) async throws {
        _ = try await perform(
            .delete,
            path: "reset-bans",
            queryItems: [URLQueryItem(name: "userID", value: userID)]
        )
    }

    // MARK: - Mixtapes

    /// `GET /tapes` — the tapes this account has set up: the recipes the
    /// builder turns into playlists, not the playlists themselves (those
    /// live in the library, where the Mixtapes screen lists them).
    func tapes(userID: String) async throws -> BackendTapes {
        let data = try await perform(
            .get,
            path: "tapes",
            queryItems: [URLQueryItem(name: "userID", value: userID)]
        )
        return try JSONDecoder().decode(BackendTapes.self, from: data)
    }

    /// `POST /new-tape` — set a tape up (or re-set one under a name the
    /// account already uses, which the backend takes as a rewrite).
    ///
    /// The switches travel as `"true"`/`"false"` because FastAPI parses its
    /// booleans from text; the name carries whatever punctuation the user
    /// typed and rides the query string, where `URLComponents` escapes it.
    func createTape(_ draft: BackendTapeDraft, userID: String) async throws -> BackendTapeCreated {
        let trimmed = BackendTapeDraft(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            recents: draft.recents,
            favourites: draft.favourites,
            fingerprint: draft.fingerprint,
            freshAlchemy: draft.freshAlchemy,
            alchemyPercent: draft.alchemyPercent,
            songCount: draft.songCount
        )
        let data = try await perform(
            .post,
            path: "new-tape",
            queryItems: [
                URLQueryItem(name: "userID", value: userID),
                URLQueryItem(name: "name", value: trimmed.name),
                URLQueryItem(name: "recents", value: trimmed.recents ? "true" : "false"),
                URLQueryItem(name: "favourites", value: trimmed.favourites ? "true" : "false"),
                URLQueryItem(name: "fingerprint", value: trimmed.fingerprint ? "true" : "false"),
                URLQueryItem(name: "alchemyPercent", value: String(trimmed.alchemyPercent)),
                URLQueryItem(name: "freshAlchemy", value: trimmed.freshAlchemy ? "true" : "false"),
                URLQueryItem(name: "songCount", value: String(trimmed.songCount)),
            ]
        )
        return try JSONDecoder().decode(BackendTapeCreated.self, from: data)
    }

    /// `DELETE /delete-tape` — take a tape's recipe off the backend's
    /// books, so the builder stops rebuilding it. The playlist it last
    /// wrote stays in the library until the custodian clears it or the
    /// user does; the recipe, which is what the tapes sheet shows, is
    /// what this deletes. The name is matched exactly as stored — without
    /// the suffix — so the row on screen is the name to send.
    ///
    /// A name the backend no longer has answers 404. Callers deleting
    /// optimistically read that as the state they asked for rather than a
    /// failure to roll back.
    func deleteTape(name: String, userID: String) async throws -> BackendTapeDeleted {
        let data = try await perform(
            .delete,
            path: "delete-tape",
            queryItems: [
                URLQueryItem(name: "userID", value: userID),
                URLQueryItem(name: "name", value: name),
            ]
        )
        return try JSONDecoder().decode(BackendTapeDeleted.self, from: data)
    }

    // MARK: - Infinite Queue

    /// `GET /extend-queue` — the tracks to append to a queue that is running
    /// short, chosen by the backend's alchemy from the songs handed over.
    ///
    /// The existing queue travels as one `existingQueue` query parameter
    /// formatted as a normal comma-separated string — the Jellyfin item ids
    /// joined in order — because a GET has no payload of its own to carry
    /// them in. An empty queue sends an empty value; an empty answer is
    /// possible and is not an error: there is simply nothing to append.
    func extendQueue(userID: String, existingQueue: [String]) async throws -> BackendExtendedQueue {
        let data = try await perform(
            .get,
            path: "extend-queue",
            queryItems: [
                URLQueryItem(name: "userID", value: userID),
                URLQueryItem(name: "existingQueue", value: existingQueue.joined(separator: ",")),
            ]
        )
        return try JSONDecoder().decode(BackendExtendedQueue.self, from: data)
    }

    /// `GET /extend-queue-by-album` — the tracks to append for a listener who
    /// is playing an album in track order and is about to run off its end.
    ///
    /// The backend works out what comes next itself: the album's artist's
    /// next release, or an album by a similar artist, or — failing all of
    /// that — alchemy seeded from the album being listened to. The app only
    /// names the album the queue currently ends with.
    func extendQueueByAlbum(userID: String, currentAlbumID: String) async throws -> BackendExtendedQueue {
        let data = try await perform(
            .get,
            path: "extend-queue-by-album",
            queryItems: [
                URLQueryItem(name: "userID", value: userID),
                URLQueryItem(name: "currentAlbumID", value: currentAlbumID),
            ]
        )
        return try JSONDecoder().decode(BackendExtendedQueue.self, from: data)
    }

    // MARK: - The request plumbing

    /// A decoder for answers that carry whole Jellyfin items — the ban
    /// list today. Every item's timestamps arrive exactly as the user's
    /// server wrote them, and Jellyfin gives fractional seconds as many
    /// digits as it has non-zero ones: three, seven, none. The SDK's own
    /// parser (which it sets on every `JellyfinClient`) handles that with
    /// two forms; these are the same two, and a bare `JSONDecoder` would
    /// fail the whole read on the first date.
    private static func itemsDecoder() -> JSONDecoder {
        // `ISO8601DateFormatter` is not marked `Sendable`, but this pair
        // is built per decoder and a decoder decodes one document at a
        // time, so the closure's capture is safe whatever the annotation.
        struct Forms: @unchecked Sendable {
            let fractional = {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter
            }()
            let plain = {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter
            }()
        }
        let forms = Forms()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = forms.fractional.date(from: text) ?? forms.plain.date(from: text) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unrecognised date: \(text)"
                    )
                )
            }
            return date
        }
        return decoder
    }

    private enum Method: String {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    /// One request against the backend: query items in, JSON out, with
    /// anything outside 2xx turned into a `BackendError` carrying the
    /// backend's own human-readable refusal when it bothers to send one.
    ///
    /// Every endpoint the app calls puts all of its input in the query
    /// string; none of them carries a request body.
    private func perform(
        _ method: Method,
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { throw BackendError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue

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
        return data
    }
}

/// The body FastAPI sends with its error responses; its `detail` is written
/// for humans, so it is shown rather than the bare status code.
private struct BackendErrorResponse: Decodable {
    let detail: String?
}
