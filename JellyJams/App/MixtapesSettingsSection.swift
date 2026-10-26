import SwiftUI

/// The Mixtapes part of Settings: the Jelly Jams Backend address, and the
/// "Save" that registers this sign-in with it.
///
/// Saving sends the current Jellyfin credentials to the backend's
/// `/register`, which checks them against the server before storing the
/// account and answers with the name ending its mixtapes carry. That ending
/// is what turns the Mixtapes section on — there is no separate switch,
/// because a feature that cannot tell its playlists apart from everyone
/// else's is not a feature worth a toggle.
struct MixtapesSettingsSection: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore

    /// Where the last save got to. Transient by design: a retry is a fresh
    /// request, and the standing truth ("registered with ending X") lives in
    /// ``PreferencesStore`` and is read back when this view has nothing to
    /// say about the current moment.
    private enum Status {
        case saving
        case registered(suffix: String)
        case failed(String)
    }

    @State private var status: Status?

    var body: some View {
        Section {
            TextField(
                "Server address",
                text: $preferences.mixtapesBackendAddress,
                prompt: Text("https://jellyjams.example.net")
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            #endif
            .disabled(isSaving)

            Button("Save") { register() }
                .disabled(!canRegister)
        } header: {
            Text("Mixtapes")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The Jelly Jams Backend builds mixtapes from your listening and saves them to your server as playlists. Saving registers this sign-in with the backend; it answers with the ending its mixtapes carry, and the Mixtapes section gathers exactly those playlists.")
                if !session.isSignedIn {
                    Text("Registration checks your Jellyfin credentials with the backend, so there must be someone signed in.")
                        .foregroundStyle(.secondary)
                }
                statusLine
            }
        }
    }

    private var isSaving: Bool {
        if case .saving = status { return true }
        return false
    }

    private var canRegister: Bool {
        let address = preferences.mixtapesBackendAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.isSignedIn && !address.isEmpty && !isSaving
    }

    /// A line for where things stand: the in-flight save, the result of the
    /// last one, or the registration carried over from before this screen
    /// opened.
    @ViewBuilder private var statusLine: some View {
        switch currentStatus {
        case nil:
            EmptyView()
        case .saving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Registering…")
            }
            .foregroundStyle(.secondary)
        case .registered(let suffix):
            Label("Registered — mixtapes are the playlists ending in “\(suffix)”.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var currentStatus: Status? {
        if let status { return status }
        if preferences.isMixtapesActive {
            return .registered(suffix: preferences.mixtapeSuffix)
        }
        return nil
    }

    /// The whole save: normalise the address, register with it, and record
    /// what the backend says. On failure the typed address stays put — the
    /// user should be able to fix a typo rather than retype a whole host.
    private func register() {
        status = .saving
        Task {
            do {
                let baseURL = try JellyJamsBackend.normalizeAddress(preferences.mixtapesBackendAddress)
                let backend = JellyJamsBackend(baseURL: baseURL, deviceInfo: session.deviceInfo)
                let registration = try await backend.register(try currentJellyfinAccount())
                preferences.recordRegistration(
                    address: backend.baseURL.absoluteString,
                    suffix: registration.playlistSuffix
                )
                status = .registered(suffix: registration.playlistSuffix)
            } catch {
                status = .failed(error.userFacingMessage)
            }
        }
    }

    /// Everything the backend needs to check the sign-in and remember where
    /// to find it: the account, its token from the Keychain, and the server
    /// it belongs to.
    private func currentJellyfinAccount() throws -> JellyfinAccount {
        guard let user = session.currentUser,
              let token = try session.currentAccessToken(), !token.isEmpty
        else {
            throw BackendError.notSignedIn
        }
        return JellyfinAccount(
            userName: user.name,
            userID: user.id,
            userToken: token,
            jellyfinHost: user.serverURL
        )
    }
}
