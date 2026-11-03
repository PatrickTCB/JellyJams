import SwiftUI

/// The Jelly Jams Backend settings sheet: the server address and its
/// registration, and beneath it the features the backend runs for this
/// account — Server Playlist, the mixtape limits and the user's bans.
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
/// rule that turns the Mixtapes section on. Sign Out is the same seam in
/// reverse, and a clean break: the sign-in rides a `DELETE /delete-me`, and
/// once the backend confirms, the app forgets the backend entirely — every
/// feature stands down and the address goes with them, so a different
/// backend can take its place from a blank slate. The Jellyfin sign-in is
/// untouched by this button; the server's own sign-out is the mirror image —
/// it never calls the backend, and forgets everything the app stored, this
/// relationship included.
struct JellyJamsBackendSettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var bans: BanStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = JellyJamsBackendSettingsModel()
    /// Owns the sheet's push stack so the bans screen can open banned
    /// artists, albums and the albums behind banned songs — the same
    /// value-based routing the library columns run, hosted here (see
    /// ``libraryNavigationDestinations(navigator:)``).
    @StateObject private var navigator = LibraryNavigator()
    @State private var saveStatus: SaveStatus?
    /// Whether the Sign Out confirmation is up. The button itself only asks;
    /// the dialog's destructive action is what runs ``signOut()`` — deleting
    /// the backend account is not a one-tap affair.
    @State private var isConfirmingSignOut = false

    /// Where the last Save or Sign Out got to. Transient by design: a retry
    /// is a fresh request, and the standing truth ("registered with ending
    /// X") lives in ``PreferencesStore`` and is read back when this view has
    /// nothing to say about the current moment.
    private enum SaveStatus {
        case saving
        case registered(suffix: String)
        case signingOut
        case signedOut
        case failed(String)
    }

    var body: some View {
        NavigationStack(path: $navigator.path) {
            List {
                addressSection
                serverPlaylistSection
                limitsSection
                bansSection
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
            .confirmationDialog(
                "Sign out of the Jelly Jams Backend?",
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) { signOut() }
            } message: {
                Text("The backend deletes your account and everything it holds for it — your mixtape recipes, your bans, and your place in the Server Playlist — and the app forgets the backend too, its address and settings included, ready for a different one. Your Jellyfin sign-in is untouched, and playlists already in your library stay put.")
            }
            .environmentObject(navigator)
            .libraryNavigationDestinations(navigator: navigator)
            .navigationDestination(for: BansScreen.self) { _ in
                BannedItemsView().environmentObject(navigator)
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
            .disabled(isBusy)

            Button("Save") { save() }
                    .disabled(!canSave)

            Button("Sign Out", role: .destructive) { isConfirmingSignOut = true }
                .disabled(!canSignOut)
            
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The Jelly Jams Backend is a companion / sidecar service. Check out the code and docs at github.com/PatrickTCB/JellyJamsBackend.")
                if !session.isSignedIn {
                    Text("Registration checks your Jellyfin credentials with the backend, so there must be someone signed in.")
                        .foregroundStyle(.secondary)
                }
                saveStatusLine
            }
        }
    }

    /// Whether a request this sheet owns is in flight — a Save or a Sign
    /// Out. While one runs the other waits, and the address stays put.
    private var isBusy: Bool {
        switch saveStatus {
        case .saving, .signingOut: return true
        default: return false
        }
    }

    private var canSave: Bool {
        let address = preferences.jellyJamsBackendAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.isSignedIn && !address.isEmpty && !isBusy
    }

    /// Sign Out is registration's undo, so it sits behind the same gate the
    /// feature switches do: `.online` is exactly "the backend is answering
    /// and it knows this account". An unreachable backend cannot delete
    /// anything, and an unregistered one has nothing to delete — in both
    /// cases the button waits rather than fails.
    private var canSignOut: Bool {
        model.connection == .online && session.isSignedIn && !isBusy
    }

    /// A line for where the save or sign-out got to: the in-flight request,
    /// the result of the last one, or the registration carried over from
    /// before this sheet opened.
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
        case .signingOut:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Signing out…")
            }
            .foregroundStyle(.secondary)
        case .signedOut:
            Label("Signed out — the backend forgot this account, and the app forgot the backend.", systemImage: "person.crop.circle.badge.xmark")
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
                    suffix: registration.playlistSuffix,
                    playlist: registration.serverPlaylist
                )
                saveStatus = .registered(suffix: registration.playlistSuffix)
                await refresh()
            } catch {
                saveStatus = .failed(error.userFacingMessage)
            }
        }
    }

    /// The undo of ``save()``, and a clean break: hand the backend the same
    /// sign-in, ask it to delete the account, and once it confirms, forget
    /// the backend entirely — address, registration, limits, all of it — so
    /// a different backend starts from the same blank slate this one did.
    /// Only the backend's answer clears anything: a refusal or an
    /// unreachable backend leaves the memory standing with the reason
    /// beside it, the same grace every other setting here gets. The
    /// Jellyfin sign-in is untouched either way: this signs out of the
    /// backend, not the server — and the server's sign-out, in turn,
    /// forgets the backend locally without ever calling it.
    private func signOut() {
        saveStatus = .signingOut
        Task {
            do {
                let baseURL = try JellyJamsBackend.normalizeAddress(preferences.jellyJamsBackendAddress)
                let backend = JellyJamsBackend(baseURL: baseURL, deviceInfo: session.deviceInfo)
                _ = try await backend.deleteAccount(try currentJellyfinAccount())
                preferences.forgetBackend()
                saveStatus = .signedOut
                await refresh()
            } catch {
                saveStatus = .failed(error.userFacingMessage)
            }
        }
    }

    /// Everything the backend needs to check this sign-in, whether it is
    /// saving the account or deleting it: the account, its token from the
    /// Keychain, and the server it belongs to.
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

    // MARK: - Server Playlist

    private var serverPlaylistSection: some View {
        Section {
            Toggle("Join the Server Playlist: '\(preferences.serverPlaylist)'.", isOn: serverPlaylistBinding)
                .disabled(!model.canEditServerPlaylist)
        } header: {
            Text("\(preferences.serverPlaylist)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The backend weaves every opted-in account's recent plays and favourites — plus its own picks — into a shared “\(preferences.serverPlaylist)” playlist, written into each member's library. Bans and repeat limits are respected.")
                connectionLine
                if let error = model.serverPlaylistError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// The toggle reads the remembered state and writes through the model,
    /// which asks the backend to agree before the memory keeps the change.
    private var serverPlaylistBinding: Binding<Bool> {
        Binding(
            get: { preferences.serverPlaylistJoined },
            set: { joined in
                Task {
                    await model.setServerPlaylist(
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

    // MARK: - Mixtape limits

    /// How many tracks from one album, and from one artist, may share a
    /// generated tape. The pair is one setting — the backend's `/limits`
    /// always takes both numbers — so the steppers settle a draft in the
    /// memory and Save sends the pair together. The backend's answer, not
    /// the tap, is what the memory keeps: a refused save keeps the draft
    /// where it can be fixed and retried, the same grace the address above
    /// gives a typo, and the next refresh replaces it if the retry never
    /// agreed.
    private var limitsSection: some View {
        Section {
            Stepper(value: $preferences.sameAlbumLimit, in: 1...20) {
                HStack {
                    Text("Same album limit")
                    Spacer()
                    Text("\(preferences.sameAlbumLimit)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(!model.canEditLimits)

            Stepper(value: $preferences.sameArtistLimit, in: 1...20) {
                HStack {
                    Text("Same artist limit")
                    Spacer()
                    Text("\(preferences.sameArtistLimit)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(!model.canEditLimits)

            Button("Save") { saveLimits() }
                .disabled(!model.canEditLimits)
        } header: {
            Text("Mixtape Limits")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use these values to limit how many tracks from the same artist or album can appear in one of the mix tapes you specified")
                if model.isApplyingLimitsChange {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving…")
                    }
                    .foregroundStyle(.secondary)
                }
                if let error = model.limitsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Send the pair the steppers settled, straight from the memory the
    /// steppers edit. The gate lives with the request: offline, nothing
    /// is accepted and the draft waits.
    private func saveLimits() {
        Task {
            await model.setLimits(
                backend: backendClient(),
                userID: session.currentUser?.id,
                preferences: preferences
            )
        }
    }

    // MARK: - Bans

    /// The door to the user's ban list. It opens only when there is a
    /// backend to open it against — signed in, an address, and a
    /// registration (``BanStore/canBan``) — because the screen behind it
    /// reads, unbans and resets against the live service; an unreachable
    /// backend has nothing to say about bans.
    @ViewBuilder private var bansSection: some View {
        if bans.canBan {
            Section {
                NavigationLink(value: BansScreen()) {
                    Label("Banned items", systemImage: "nosign")
                }
            } header: {
                Text("Bans")
            } footer: {
                Text("Songs, albums and artists banned from their menus are kept out of the playlists the backend generates. Here they can be unbanned, one at a time or all at once.")
            }
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
        JellyJamsBackend.configured(address: preferences.jellyJamsBackendAddress, deviceInfo: session.deviceInfo)
    }
}
