import SwiftUI

/// The Jelly Jams Backend settings sheet: the server address and its
/// registration, and beneath it the features the backend runs for this
/// account — Server Playlist, the mixtape limits, the Infinite Queue and the
/// user's bans.
///
/// The sheet speaks the backend's pattern: opening it pings the backend, and
/// only while that ping answers do the feature switches take input. The
/// backend lives on a home LAN as often as on the internet, so an
/// unreachable one does not hide anything — the last state the app stored is
/// shown in the switches, read-only, with the reason beside it. The address
/// itself stays editable regardless: it is how you get the backend back.
///
/// Registration is the gate everything else sits behind, and it is a
/// conversation with the user's Jellyfin server rather than a handover of
/// credentials: Sign In starts a Quick Connect flow on the backend, the
/// sheet shows the code it hands back, and the user types it into the
/// server's own web page to give the backend a token of its own.
/// The app never sends its access token anywhere. Verify then asks the
/// backend how that went: a saved account is recorded the way an
/// old-style registration was, a flow still in progress re-presents the
/// code, and an expired one signs the app out of the backend locally.
/// Verify does not need a Sign In from this sheet, though: it asks
/// whatever address the field holds, so a second device can press Verify
/// and adopt the account the backend already knows instead of running
/// Quick Connect again. A backend that simply has no account for this
/// user — and no flow either — is answered with a line saying so, and
/// what this device remembers stands.
/// Sign Out is a clean break, and local by default: the app forgets the
/// backend entirely — every feature
/// stands down and the address goes with them, so a different backend can
/// take its place from a blank slate — without owing the backend a request,
/// which is what lets a dead one be left behind. Its confirmation carries
/// one checkbox, off unless asked for: also ride `DELETE /delete-me`, and
/// the backend deletes the account and everything it holds before anything
/// is forgotten. The Jellyfin sign-in is untouched by this button; the
/// server's own sign-out forgets everything the app stored, this
/// relationship included, and never calls the backend.
struct JellyJamsBackendSettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(PreferencesStore.self) private var preferences
    @Environment(BanStore.self) private var bans
    @Environment(\.dismiss) private var dismiss

    @State private var model = JellyJamsBackendSettingsModel()
    /// Owns the sheet's push stack so the bans screen can open banned
    /// artists, albums and the albums behind banned songs — the same
    /// value-based routing the library columns run, hosted here (see
    /// ``libraryNavigationDestinations(navigator:)``).
    @State private var navigator = LibraryNavigator()
    /// The address being typed, while it differs from the saved one; `nil`
    /// shows the saved address. Edits stay here until Verify registers
    /// them: the saved address is the one bans and Infinite Queue talk to,
    /// so it must never be a half-typed host.
    @State private var addressDraft: String?
    @State private var saveStatus: SaveStatus?
    /// The normalised address the pending Quick Connect flow was started
    /// against, and the one Verify asks while it is pending. A flow belongs
    /// to a backend as much as a registration does, and the typed draft is
    /// free to wander while the user is away typing the code. Without a
    /// flow, Verify asks the typed address instead — the field names the
    /// backend either way.
    @State private var pendingSignInAddress: String?
    /// The Quick Connect flow the user still owes their server a code to,
    /// while it is on the books this sheet keeps. Presenting it as an item
    /// means a fresh code from `/verify` simply replaces the old one.
    @State private var quickConnect: PendingQuickConnect?
    /// Whether the expired-flow pop-up is up. Its one button signs the app
    /// out of the backend locally — there is nothing left to delete there
    /// if the flow was never finished. Only a flow this sheet started can
    /// raise it: a Verify standing alone never wipes a registration.
    @State private var isReportingExpiredFlow = false
    /// Whether the Sign Out confirmation is up. The button itself only asks;
    /// the alert's destructive action is what runs ``signOut()`` — leaving
    /// the backend is not a one-tap affair.
    @State private var isConfirmingSignOut = false
    /// The confirmation's checkbox: whether signing out also asks the
    /// backend to delete the account (`DELETE /delete-me`) rather than only
    /// forgetting it locally. Reset to off at every presentation —
    /// deleting the account is an explicit extra, never a default.
    @State private var alsoDeletesAccount = false

    /// A Sign In the backend accepted and the user has not finished: the
    /// code to show, the account it belongs to, and the server whose
    /// Quick Connect page takes it.
    private struct PendingQuickConnect: Identifiable {
        let userName: String
        let code: String
        let jellyfinHost: URL
        var id: String { code }
    }

    /// Where the last Sign In, Verify, or Sign Out got to. Transient by
    /// design: a retry is a fresh request, and the standing truth
    /// ("registered with ending X") lives in ``PreferencesStore`` and is
    /// read back when this view has nothing to say about the current
    /// moment.
    private enum SaveStatus {
        /// The `/register` request that starts a Quick Connect flow.
        case starting
        /// The sheet showed the code; the user's half — typing it on the
        /// Jellyfin server — is what is outstanding, and Verify is how the
        /// app finds out they did.
        case awaitingVerification
        /// The `/verify` request checking how the flow got on.
        case verifying
        case registered(suffix: String)
        /// The deletion the confirmation's checkbox asked for is in flight.
        case signingOut
        /// The app forgot the backend; the account there still stands.
        case signedOut
        /// The backend deleted the account, and the app forgot the backend.
        case accountDeleted
        case failed(String)
    }

    var body: some View {
        NavigationStack(path: $navigator.path) {
            List {
                addressSection
                serverPlaylistSection
                limitsSection
                infiniteQueueSection
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
            .alert("Sign out of the Jelly Jams Backend?", isPresented: $isConfirmingSignOut) {
                Toggle("Also delete my account on the backend", isOn: $alsoDeletesAccount)
                Button("Sign Out", role: .destructive) { signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if alsoDeletesAccount {
                    Text("The backend deletes your account and everything it holds for it — your mixtape recipes, your bans, and your place in the Server Playlist — and then the app forgets the backend. Playlists already in your library stay put, and your Jellyfin sign-in is untouched.")
                } else {
                    Text("The app forgets this backend — its address, your registration, limits, and Server Playlist membership. The account on the backend is left standing, with everything it holds. Your Jellyfin sign-in is untouched either way.")
                }
            }
            .alert("Quick Connect", isPresented: $isReportingExpiredFlow) {
                Button("Ok") { forgetBackendLocally() }
            } message: {
                Text("Either the Quick Connect flow you started expired, or you have not started a Sign In Flow on this Jelly Jams Backend.")
            }
            .sheet(item: $quickConnect) { flow in
                QuickConnectSheet(
                    userName: flow.userName,
                    code: flow.code,
                    jellyfinHost: flow.jellyfinHost
                )
            }
            .libraryNavigationDestinations(navigator: navigator)
            .navigationDestination(for: BansScreen.self) { _ in
                BannedItemsView()
                    .environment(navigator)
            }
        }
        .environment(navigator)
        .frame(minWidth: 300, minHeight: 420, idealHeight: 800)
        .task { await refresh() }
        .remotePlayPause()
        #if os(macOS)
        //.background(ResizableWindow())
        #endif
    }

    // MARK: - The backend's address

    private var addressSection: some View {
        Section {
            TextField(
                "Server address",
                text: addressField,
                prompt: Text("https://jellyjams.example.net")
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            #endif
            .disabled(isBusy)

            Button("Sign In") { signIn() }
                    .disabled(!canSignIn)

            Button("Verify") { verify() }
                    .disabled(!canVerify)

            Button("Sign Out", role: .destructive) {
                alsoDeletesAccount = false
                isConfirmingSignOut = true
            }
                .disabled(!canSignOut)
            
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The Jelly Jams Backend is a companion / sidecar service. Check out the code and docs at [github.com/PatrickTCB/JellyJamsBackend](https://github.com/PatrickTCB/JellyJamsBackend).")
                if !session.isSignedIn {
                    Text("Sign In starts a Quick Connect flow on your Jellyfin server, so there must be someone signed in.")
                        .foregroundStyle(.secondary)
                }
                Text("Verify asks the backend whether it already knows this Jellyfin account, so a backend set up on another device can be adopted here without signing in again.")
                    .foregroundStyle(.secondary)
                saveStatusLine
            }
        }
    }

    /// Whether a request this sheet owns is in flight — a Sign In, a
    /// Verify, or a Sign Out. While one runs the others wait, and the
    /// address stays put.
    private var isBusy: Bool {
        switch saveStatus {
        case .starting, .verifying, .signingOut: return true
        default: return false
        }
    }

    /// What the address field shows: the draft while there is one, the saved
    /// address otherwise.
    private var typedAddress: String {
        addressDraft ?? preferences.jellyJamsBackendAddress
    }

    private var addressField: Binding<String> {
        Binding(get: { typedAddress }, set: { addressDraft = $0 })
    }

    private var canSignIn: Bool {
        let address = typedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.isSignedIn && !address.isEmpty && !isBusy
    }

    /// Verify asks the backend whether this account is registered, so the
    /// only things that can hold it back are a request of its own already in
    /// flight and having no Jellyfin account to ask about. It deliberately
    /// does not wait on a Sign In from this sheet: that is what lets a
    /// second device adopt the registration the first one made — press
    /// Verify, and the backend's own answer settles it.
    private var canVerify: Bool {
        !isBusy && session.currentUser != nil
    }

    /// Where Verify sends its question: the address the field shows — the one
    /// Sign In would use, and the one the user can point anywhere — with a
    /// pending flow's own address only standing in when the field is empty.
    /// That is the shape both jobs share: a device following a Sign In it
    /// started asks at that backend, and a device adopting a backend it
    /// never signed in to asks at the address typed for it.
    private var verifyTargetAddress: String {
        let typed = typedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (pendingSignInAddress ?? "") : typedAddress
    }

    /// Sign Out forgets the backend locally, so it is available whenever
    /// there is anything to forget — a registration, or even just a typed
    /// address — and it works with the backend dead or unreachable, which
    /// is half the point: a backend that no longer answers must not hold
    /// the install hostage to its registration. The confirmation's
    /// deletion checkbox needs more — a sign-in and a live backend — and
    /// that path says so in its own words when the more turns out not to
    /// be there.
    private var canSignOut: Bool {
        let address = typedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isBusy && (preferences.isMixtapesActive || !address.isEmpty)
    }

    /// A line for where the sign-in, verification or sign-out got to: the
    /// in-flight request, the result of the last one, or the registration
    /// carried over from before this sheet opened.
    @ViewBuilder private var saveStatusLine: some View {
        switch currentSaveStatus {
        case nil:
            EmptyView()
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting Quick Connect…")
            }
            .foregroundStyle(.secondary)
        case .awaitingVerification:
            Label("Almost there — enter the code on your Jellyfin server, press Done, then press Verify.", systemImage: "arrow.forward.circle.fill")
                .foregroundStyle(.secondary)
        case .verifying:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Asking the backend about this account…")
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
            Label("Signed out — the app forgot this backend; the account there still stands.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .accountDeleted:
            Label("Signed out — the backend deleted this account, and the app forgot the backend.", systemImage: "person.crop.circle.badge.xmark")
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

    /// The whole Sign In: normalise the typed address and ask the backend
    /// to start a Quick Connect flow for this account. Nothing is saved
    /// here — the backend earns its own token from the Jellyfin server
    /// while the user types the code into the server's web page, and only
    /// ``verify()`` settles the outcome. The typed address stays a draft
    /// beside the flow's own copy: a half-registered backend must not take
    /// over what bans and Infinite Queue talk to.
    private func signIn() {
        saveStatus = .starting
        let address = typedAddress
        Task {
            do {
                let baseURL = try JellyJamsBackend.normalizeAddress(address)
                let backend = JellyJamsBackend(baseURL: baseURL, deviceInfo: session.deviceInfo)
                let registration = try await backend.register(try currentJellyfinAccount())
                pendingSignInAddress = baseURL.absoluteString
                if settle(registration, at: baseURL) { await refresh() }
            } catch {
                saveStatus = .failed(error.userFacingMessage)
            }
        }
    }

    /// Ask the backend whether this account is registered there. Saved means
    /// the account is on the books and the app adopts the backend the way it
    /// always has — which is how a second device joins a backend configured
    /// on another one, without a fresh Quick Connect; in progress means the
    /// user's half is still outstanding, and the sheet goes back up with the
    /// code `/verify` says is live — which may be a fresh one, and may have
    /// been started from another device; and the 400 means the backend has
    /// no account and no flow for this user. That is the expired-flow pop-up
    /// (whose button signs out locally) when this sheet started the Sign In,
    /// and a plain explanation asking for a Sign In when it did not — a
    /// Verify standing alone must not wipe a registration that is not
    /// actually known to be gone. Other refusals land on the failure line
    /// beside the address.
    private func verify() {
        guard let userID = session.currentUser?.id else { return }
        let address = verifyTargetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            saveStatus = .failed("Enter the backend's address above, then press Verify.")
            return
        }
        let baseURL: URL
        do {
            baseURL = try JellyJamsBackend.normalizeAddress(address)
        } catch {
            saveStatus = .failed(error.userFacingMessage)
            return
        }
        // The pop-up's local sign-out is only owed when this sheet's own
        // flow is the thing that came back empty; a 400 from a backend the
        // user merely pointed the field at says nothing about what this
        // device remembers.
        let askedAboutThePendingFlow = pendingSignInAddress == baseURL.absoluteString
        saveStatus = .verifying
        Task {
            do {
                let backend = JellyJamsBackend(baseURL: baseURL, deviceInfo: session.deviceInfo)
                let answer = try await backend.verify(userID: userID)
                // An answer that is not the finished registration is a flow:
                // it becomes this sheet's pending one, so the code stays on
                // the books here and the next Verify asks the same backend
                // even if the address draft wanders.
                if !(answer.saved && !answer.inProgress) {
                    pendingSignInAddress = baseURL.absoluteString
                }
                if settle(answer, at: baseURL) { await refresh() }
            } catch let error as BackendError where error.isQuickConnectExpired {
                if askedAboutThePendingFlow {
                    saveStatus = nil
                    isReportingExpiredFlow = true
                } else {
                    saveStatus = .failed("The backend doesn't know this account yet. Press Sign In above to start the Quick Connect flow it needs.")
                }
            } catch {
                saveStatus = .failed(error.userFacingMessage)
            }
        }
    }

    /// Settle what a `/register` or `/verify` answer means for the sheet.
    /// `Saved` with nothing in progress is the registration — the address
    /// becomes the saved one, the backend's rules are remembered, and this
    /// returns true so the caller knows a refresh is owed, the same proof
    /// the old Save took as its cue that the backend answers. Anything else
    /// is a flow still waiting on the user: the code goes back up in the
    /// sheet, and the address stays put.
    @discardableResult
    private func settle(_ answer: BackendRegistration, at baseURL: URL) -> Bool {
        if answer.saved && !answer.inProgress {
            preferences.recordRegistration(
                address: baseURL.absoluteString,
                suffix: answer.playlistSuffix,
                playlist: answer.serverPlaylist
            )
            // The field now shows the saved, normalised address.
            addressDraft = nil
            pendingSignInAddress = nil
            quickConnect = nil
            saveStatus = .registered(suffix: answer.playlistSuffix)
            return true
        }

        guard let user = session.currentUser else {
            pendingSignInAddress = nil
            saveStatus = .failed(BackendError.notSignedIn.userFacingMessage)
            return false
        }
        quickConnect = PendingQuickConnect(
            userName: user.name,
            code: answer.code,
            jellyfinHost: user.serverURL
        )
        saveStatus = .awaitingVerification
        return false
    }

    /// The clean break, at one of two depths. By default it is local and
    /// instant: the app forgets the backend — address, registration,
    /// limits, membership — and owes it no request, so a backend that no
    /// longer answers can still be left behind, and the account there
    /// simply stands. With the confirmation's checkbox on, the account's
    /// identity rides `DELETE /delete-me` first and only the backend's
    /// confirmation forgets anything: a refusal leaves the whole memory
    /// standing with the reason beside it — the same grace every other
    /// setting here gets — because "memory gone, account still on the
    /// books" is exactly the half-state the checkbox exists to prevent;
    /// uncheck it to leave without the backend's say. The Jellyfin sign-in
    /// is untouched either way: this signs out of the backend, not the
    /// server.
    private func signOut() {
        guard alsoDeletesAccount else {
            forgetBackendLocally()
            return
        }
        saveStatus = .signingOut
        Task {
            do {
                let baseURL = try JellyJamsBackend.normalizeAddress(preferences.jellyJamsBackendAddress)
                let backend = JellyJamsBackend(baseURL: baseURL, deviceInfo: session.deviceInfo)
                _ = try await backend.deleteAccount(try currentJellyfinAccount())
                preferences.forgetBackend()
                addressDraft = nil
                pendingSignInAddress = nil
                quickConnect = nil
                saveStatus = .accountDeleted
                await refresh()
            } catch {
                saveStatus = .failed(error.userFacingMessage)
            }
        }
    }

    /// The local half of a sign-out: the app forgets the backend outright,
    /// and owes it no request — which is also the whole sign-out for the
    /// expired-Quick-Connect pop-up, where there is no finished account to
    /// delete, and for a backend that stopped answering. A pending flow
    /// goes with the rest of the memory: its code has no backend to be
    /// verified against anymore.
    private func forgetBackendLocally() {
        preferences.forgetBackend()
        addressDraft = nil
        pendingSignInAddress = nil
        quickConnect = nil
        saveStatus = .signedOut
        Task { await refresh() }
    }

    /// Who the backend is talking about, whether it is starting a sign-in
    /// flow, verifying one, or deleting the account: the signed-in user
    /// and the server they belong to. There is no token in this anymore —
    /// the backend earns its own through Quick Connect, and the app keeps
    /// its Keychain to itself.
    private func currentJellyfinAccount() throws -> JellyfinAccount {
        guard let user = session.currentUser else {
            throw BackendError.notSignedIn
        }
        return JellyfinAccount(
            userName: user.name,
            userID: user.id,
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
            Text("The backend is answering, but it doesn't know this account yet. If you've already set it up on another device, press Verify. Otherwise press Sign In above, enter the code it gives you on your Jellyfin server, and press Verify when you're back.")
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
            #if os(tvOS)
            TextField("Same album limit", value: Bindable(preferences).sameAlbumLimit, format: .number)
                .disabled(!model.canEditLimits)
            #else
            Stepper(value: Bindable(preferences).sameAlbumLimit, in: 1...20) {
                HStack {
                    Text("Same album limit")
                    Spacer()
                    Text("\(preferences.sameAlbumLimit)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(!model.canEditLimits)
            #endif

            #if os(tvOS)
            TextField("Same artist limit", value: Bindable(preferences).sameArtistLimit, format: .number)
                .disabled(!model.canEditLimits)
            #else
            Stepper(value: Bindable(preferences).sameArtistLimit, in: 1...20) {
                HStack {
                    Text("Same artist limit")
                    Spacer()
                    Text("\(preferences.sameArtistLimit)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(!model.canEditLimits)
            #endif

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

    // MARK: - Infinite Queue

    /// The listener's opt-in to the backend's queue extension: whenever the
    /// running queue gets near its end, the backend picks the next tracks —
    /// the next album in the listen, or an alchemy set seeded from the queue
    /// so far — and appends them.
    ///
    /// Unlike the backend's other feature switches, this one is the app's own
    /// preference rather than something the backend keeps a copy of, so it is
    /// editable however the connection stands: an unreachable backend simply
    /// means nothing ever extends, and the remembered state keeps the switch
    /// where the user left it.
    private var infiniteQueueSection: some View {
        Section {
            Toggle("Infinite Queue", isOn: Bindable(preferences).infiniteQueueEnabled)
        } header: {
            Text("Infinite Queue")
        } footer: {
            Text("When the queue runs short the backend picks the next tracks — the next album in the listen, or an alchemy set from the queue so far — and appends them. Turn it off and the queue ends where it ran out; while the backend is unreachable it simply never extends.")
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
