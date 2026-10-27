import SwiftUI

/// The Jelly Jams Backend settings sheet: the server address and its
/// registration, and beneath it the features the backend runs for this
/// account — Family Blend today.
///
/// The sheet speaks the backend's pattern: opening it pings the backend, and
/// only while that ping answers do the feature switches take input. The
/// backend lives on a home LAN as often as on the internet, so an
/// unreachable one does not hide anything — the last state the app stored is
/// shown in the switches, read-only, with the reason beside it. The address
/// itself stays editable regardless: it is how you get the backend back.
///
/// Registration is the gate everything else sits behind — saving sends the
/// current Jellyfin sign-in to `/register`, which checks it against the
/// server and answers with the name ending the backend's mixtapes carry, the
/// rule that turns the Mixtapes section on.
struct JellyJamsBackendSettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = JellyJamsBackendSettingsModel()
    @State private var saveStatus: SaveStatus?

    /// Where the last Save got to. Transient by design: a retry is a fresh
    /// request, and the standing truth ("registered with ending X") lives in
    /// ``PreferencesStore`` and is read back when this view has nothing to
    /// say about the current moment.
    private enum SaveStatus {
        case saving
        case registered(suffix: String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                addressSection
                familyBlendSection
            }
            .navigationTitle("Jelly Jams Backend")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .task { await refresh() }
    }

    // MARK: - The backend's address

    private var addressSection: some View {
        Section {
            TextField(
                "Server address",
                text: $preferences.jellyJamsBackendAddress,
                prompt: Text("https://jellyjams.example.net")
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            #endif
            .disabled(isSaving)

            Button("Save") { save() }
                .disabled(!canSave)
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The Jelly Jams Backend is the companion service behind Jelly Jams' generated features — Mixtapes and Family Blend so far. Saving registers this sign-in with it: the backend checks your credentials against your server, then answers with the name ending its mixtapes carry.")
                if !session.isSignedIn {
                    Text("Registration checks your Jellyfin credentials with the backend, so there must be someone signed in.")
                        .foregroundStyle(.secondary)
                }
                saveStatusLine
            }
        }
    }

    private var isSaving: Bool {
        if case .saving = saveStatus { return true }
        return false
    }

    private var canSave: Bool {
        let address = preferences.jellyJamsBackendAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.isSignedIn && !address.isEmpty && !isSaving
    }

    /// A line for where the save got to: the in-flight request, the result
    /// of the last one, or the registration carried over from before this
    /// sheet opened.
    @ViewBuilder private var saveStatusLine: some View {
        switch currentSaveStatus {
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

    private var currentSaveStatus: SaveStatus? {
        if let saveStatus { return saveStatus }
        if preferences.isMixtapesActive {
            return .registered(suffix: preferences.mixtapeSuffix)
        }
        return nil
    }

    /// The whole save: normalise the address, register with it, and record
    /// what the backend says. On failure the typed address stays put — the
    /// user should be able to fix a typo rather than retype a whole host.
    /// On success the sheet refreshes: a save that worked is proof the
    /// backend answers, and the fresh registration may have just unlocked
    /// the features below it.
    private func save() {
        saveStatus = .saving
        Task {
            do {
                let baseURL = try JellyJamsBackend.normalizeAddress(preferences.jellyJamsBackendAddress)
                let backend = JellyJamsBackend(baseURL: baseURL, deviceInfo: session.deviceInfo)
                let registration = try await backend.register(try currentJellyfinAccount())
                preferences.recordRegistration(
                    address: backend.baseURL.absoluteString,
                    suffix: registration.playlistSuffix
                )
                saveStatus = .registered(suffix: registration.playlistSuffix)
                await refresh()
            } catch {
                saveStatus = .failed(error.userFacingMessage)
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

    // MARK: - Family Blend

    private var familyBlendSection: some View {
        Section {
            Toggle("Join the Family Blend", isOn: familyBlendBinding)
                .disabled(!model.canEditFamilyBlend)
        } header: {
            Text("Family Blend")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The backend weaves every opted-in account's recent plays and favourites — plus its own picks — into a shared “Family Blend” playlist, written into each member's library. Bans and repeat limits are respected.")
                connectionLine
                if let error = model.familyBlendError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// The toggle reads the remembered state and writes through the model,
    /// which asks the backend to agree before the memory keeps the change.
    private var familyBlendBinding: Binding<Bool> {
        Binding(
            get: { preferences.familyBlendJoined },
            set: { joined in
                Task {
                    await model.setFamilyBlend(
                        joined: joined,
                        backend: backendClient(),
                        userID: session.currentUser?.id,
                        preferences: preferences
                    )
                }
            }
        )
    }

    /// A line for where the connection got to. The reason an unreachable
    /// backend is shown in its own words (no address, refused connection,
    /// whatever happened); what every state that isn't `online` shares is
    /// that the switches below are remembering, not deciding.
    @ViewBuilder private var connectionLine: some View {
        switch model.connection {
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the backend…")
            }
            .foregroundStyle(.secondary)
        case .unreachable(let reason):
            Text(reason)
                .foregroundStyle(.secondary)
            Text("The saved state is shown until the backend answers again.")
                .foregroundStyle(.secondary)
        case .needsRegistration:
            Text("The backend is answering, but it doesn't know this account yet. Sign in and press Save above to register.")
                .foregroundStyle(.secondary)
        case .online:
            Text("Connected — the backend confirms what it knows about this account.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared plumbing

    /// The whole ritual the pattern prescribes: ping the backend, and when
    /// it answers, ask it what it thinks of this account.
    private func refresh() async {
        await model.refresh(
            backend: backendClient(),
            addressText: preferences.jellyJamsBackendAddress,
            userID: session.currentUser?.id,
            registered: preferences.isMixtapesActive,
            preferences: preferences
        )
    }

    /// The client for the saved address — nil when there is none, or the
    /// text will not parse. The model reads the address text itself to say
    /// which of those it was.
    private func backendClient() -> JellyJamsBackend? {
        guard let url = try? JellyJamsBackend.normalizeAddress(preferences.jellyJamsBackendAddress) else {
            return nil
        }
        return JellyJamsBackend(baseURL: url, deviceInfo: session.deviceInfo)
    }
}
