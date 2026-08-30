import SwiftUI


/// Onboarding screen: enter a Jellyfin server address and sign in.
struct ServerLoginView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    @FocusState private var focusedField: Field?
    private enum Field { case server, username, password }

    private var canSubmit: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !isSigningIn
    }

    var body: some View {
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
            signInButton
            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .submitLabel(.next)
                    .onSubmit { focusedField = .username }
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
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
        .textFieldStyle(.roundedBorder)
    }

    private func labeledField(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
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
        .keyboardShortcut(.defaultAction)
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
}

#Preview {
    ServerLoginView()
}
