import Foundation
import OSLog
import SwiftUI

private let sessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "net.aseriesoftubes.JellyJams",
    category: "Session"
)

/// Owns the signed-in state: the SDK-backed ``JellyfinService``, the current
/// user, and persistence of both. This is the single source of truth other
/// services and views read the client from.
@MainActor
final class SessionStore: ObservableObject {

    struct StoredUser: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var serverURL: URL
        var serverName: String?
    }

    @Published private(set) var client: JellyfinService?
    @Published private(set) var currentUser: StoredUser?
    @Published private(set) var isRestoring = true
    @Published private(set) var errorMessage: String?

    let deviceInfo = DeviceInfo.current()

    private let userDefaultsKey = "jellyjams.currentUser"

    var isSignedIn: Bool { client != nil && currentUser != nil }

    /// Every library read the UI performs goes through here. It exists whether
    /// or not a user is signed in — reads made while signed out throw
    /// ``JellyfinError/notAuthenticated`` instead of silently doing nothing.
    var library: LibraryRepository { LibraryRepository(client: client) }

    // MARK: - Restore

    func restore() {
        isRestoring = true
        defer { isRestoring = false }
        errorMessage = nil

        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }

        let user: StoredUser
        do {
            user = try JSONDecoder().decode(StoredUser.self, from: data)
        } catch {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            errorMessage = "The saved account information was damaged and has been cleared."
            return
        }

        do {
            guard let token = try Keychain.get(account: user.id) else {
                UserDefaults.standard.removeObject(forKey: userDefaultsKey)
                return
            }
            let credentials = ServerCredentials(userId: user.id, token: token)
            client = JellyfinService(baseURL: user.serverURL, deviceInfo: deviceInfo, credentials: credentials)
            currentUser = user
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Sign in / out

    func signIn(serverURLString: String, username: String, password: String) async throws {
        let baseURL = try Self.normalizeServerURL(serverURLString)
        let probe = JellyfinService(baseURL: baseURL, deviceInfo: deviceInfo)
        let info = try await probe.publicSystemInfo()
        let auth = try await probe.authenticateByName(username: username, password: password)
        guard let authenticatedUser = auth.user,
              let userId = authenticatedUser.id,
              let accessToken = auth.accessToken
        else {
            throw JellyfinError.incompleteAuthenticationResponse
        }

        let credentials = ServerCredentials(userId: userId, token: accessToken)
        let authenticatedClient = probe.authenticated(with: credentials)
        let user = StoredUser(
            id: userId,
            name: authenticatedUser.name ?? username,
            serverURL: baseURL,
            serverName: info.serverName
        )

        do {
            try Keychain.set(accessToken, account: user.id)
            let encoded = try JSONEncoder().encode(user)
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        } catch {
            do {
                try Keychain.delete(account: user.id)
            } catch {
                sessionLogger.error("Could not roll back Keychain token: \(error.localizedDescription, privacy: .public)")
            }
            do {
                try await authenticatedClient.logout()
            } catch {
                sessionLogger.error("Could not invalidate failed sign-in session: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }

        errorMessage = nil
        client = authenticatedClient
        currentUser = user
    }

    func signOut() {
        var keychainError: String?
        do {
            if let userId = currentUser?.id {
                try Keychain.delete(account: userId)
            }
        } catch {
            keychainError = "You were signed out locally, but the saved token could not be removed. \(error.userFacingMessage)"
        }

        let clientToLogout = client
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        client = nil
        currentUser = nil
        errorMessage = keychainError
        Task {
            do {
                try await clientToLogout?.logout()
            } catch {
                sessionLogger.error("Could not invalidate signed-out session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Helpers

    /// Normalises user-entered server addresses: trims whitespace, adds a
    /// scheme if missing (defaults to `http` for LAN servers), and removes a
    /// trailing slash or `/web` suffix.
    static func normalizeServerURL(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw JellyfinError.invalidServerURL }
        if !text.contains("://") { text = "http://" + text }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw JellyfinError.invalidServerURL
        }

        components.scheme = scheme
        while components.path.hasSuffix("/") { components.path.removeLast() }
        if components.path.lowercased().hasSuffix("/web") {
            components.path.removeLast(4)
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }

        guard let url = components.url else { throw JellyfinError.invalidServerURL }
        return url
    }
}
