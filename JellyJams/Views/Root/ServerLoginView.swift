import SwiftUI


/// Onboarding screen: enter a Jellyfin server address and sign in.
///
/// Two roads lead in: a username and password, or Quick Connect — a code
/// this app shows and the user approves on their Jellyfin server, with no
/// password typed here. Quick Connect is the offered alternative on iOS,
/// iPadOS and macOS, and the default on tvOS, where typing a password with
/// the remote is the chore it exists to spare. A server with Quick Connect
/// turned off sends the user back to the password form with the reason.
struct ServerLoginView: View {
    @Environment(SessionStore.self) private var session

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    /// Which form the screen leads with. tvOS opens on Quick Connect;
    /// everywhere else the password form is the default and Quick Connect
    /// the alternative beneath it.
    #if os(tvOS)
    @State private var mode: SignInMode = .quickConnect
    #else
    @State private var mode: SignInMode = .password
    #endif
    private enum SignInMode { case password, quickConnect }

    /// The Quick Connect flow this screen is running, if any. Its state
    /// drives the sheet; nil means no sheet and no flow.
    @State private var quickConnect: QuickConnectSignInSheet.State?
    @State private var quickConnectTask: Task<Void, Never>?

    @FocusState private var focusedField: Field?
    private enum Field { case server, username, password }

    private var canSubmit: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !isSigningIn
    }

    private var canQuickConnect: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !isSigningIn &&
        quickConnect == nil
    }

    var body: some View {
        // The form scrolls: on a phone — keyboard up especially — the
        // header, fields and buttons can outrun the screen, and nothing
        // below the fold may be out of reach. The scroll view also scrolls
        // the focused field clear of the keyboard on its own.
        ScrollView {
            VStack(spacing: 24) {
                header
                form
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 380, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                actionButtons
            }
            .padding(40)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .sheet(isPresented: isShowingQuickConnect) {
            QuickConnectSignInSheet(
                state: quickConnect ?? .starting,
                jellyfinHost: try? SessionStore.normalizeServerURL(serverURL),
                onRetry: { startQuickConnect() },
                onCancel: { cancelQuickConnect() }
            )
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Jelly Jams")
                .font(.largeTitle.bold())
            Text("Sign in to your Jellyfin server")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private var form: some View {
        VStack(spacing: 14) {
            labeledField("Server", systemImage: "server.rack") {
                TextField("https://jellyfin.example.com", text: $serverURL)
                    .textContentType(.URL)
                    .focused($focusedField, equals: .server)
                    .submitLabel(mode == .password ? .next : .go)
                    .onSubmit {
                        if mode == .password {
                            focusedField = .username
                        } else {
                            startQuickConnect()
                        }
                    }
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            if mode == .password {
                labeledField("Username", systemImage: "person.fill") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                labeledField("Password", systemImage: "lock.fill") {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                }
            }
        }
        #if !os(tvOS)
        .textFieldStyle(.roundedBorder)
        #endif
    }

    private func labeledField(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// The buttons under the form, as the mode orders them: the password
    /// form leads with Sign In and offers Quick Connect beneath it; the
    /// Quick Connect form leads with its own Sign In and offers the
    /// password form as the way around a server that has it turned off.
    @ViewBuilder private var actionButtons: some View {
        switch mode {
        case .password:
            signInButton
            Button {
                startQuickConnect()
            } label: {
                Label("Sign In with Quick Connect", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!canQuickConnect)
            .frame(maxWidth: 380)
        case .quickConnect:
            Button {
                startQuickConnect()
            } label: {
                Text("Sign In with Quick Connect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canQuickConnect)
            .frame(maxWidth: 380)

            Button("Sign in with a password instead") {
                errorMessage = nil
                mode = .password
            }
            #if os(tvOS)
            .buttonStyle(.bordered)
            #else
            .buttonStyle(.borderless)
            #endif
        }
    }

    private var signInButton: some View {
        Button(action: submit) {
            HStack {
                if isSigningIn { ProgressView().controlSize(.small) }
                Text(isSigningIn ? "Signing in…" : "Sign In")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canSubmit)
        #if !os(tvOS)
        .keyboardShortcut(.defaultAction)
        #endif
        .frame(maxWidth: 380)
    }

    private func submit() {
        guard canSubmit else { return }
        errorMessage = nil
        isSigningIn = true
        Task {
            do {
                try await session.signIn(
                    serverURLString: serverURL,
                    username: username,
                    password: password
                )
            } catch {
                errorMessage = error.userFacingMessage
            }
            isSigningIn = false
        }
    }

    // MARK: - Quick Connect

    private var isShowingQuickConnect: Binding<Bool> {
        Binding(
            get: { quickConnect != nil },
            set: { if !$0 { cancelQuickConnect() } }
        )
    }

    /// Runs the Quick Connect flow to its end: the code goes up in the
    /// sheet as soon as the server issues it, and the sign-in lands — or
    /// the failure shows — without any further press. A server that has
    /// Quick Connect turned off, or an address that will not parse, comes
    /// back to the form itself with the reason beside it; every other
    /// failure stays in the sheet with a Try Again, because the code it
    /// was waiting on is the thing that went stale.
    private func startQuickConnect() {
        guard !serverURL.trimmingCharacters(in: .whitespaces).isEmpty, !isSigningIn else { return }
        errorMessage = nil
        quickConnectTask?.cancel()
        quickConnect = .starting
        quickConnectTask = Task {
            do {
                for try await code in session.quickConnectSignIn(serverURLString: serverURL) {
                    guard !Task.isCancelled else { return }
                    quickConnect = .waiting(code: code)
                }
                // A cancelled consumer's loop ends normally too, so the
                // success path needs the same guard as the failure one:
                // a dismissed flow must not close the sheet of whatever
                // took its place.
                guard !Task.isCancelled else { return }
                quickConnect = nil
            } catch {
                // A cancelled flow was dismissed or replaced on purpose;
                // its late answer must not touch the state of whatever
                // took its place.
                guard !Task.isCancelled, !error.isCancellation else { return }
                if let error = error as? JellyfinError, error == .quickConnectNotEnabled {
                    quickConnect = nil
                    mode = .password
                    errorMessage = error.userFacingMessage
                } else if let error = error as? JellyfinError, error == .invalidServerURL {
                    quickConnect = nil
                    errorMessage = error.userFacingMessage
                } else {
                    quickConnect = .failed(message: error.userFacingMessage)
                }
            }
        }
    }

    private func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnect = nil
    }
}

#Preview {
    ServerLoginView()
}
