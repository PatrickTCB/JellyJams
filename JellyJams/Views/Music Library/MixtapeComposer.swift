import SwiftUI

/// The form behind the Mixtapes screen's "+" button: it turns the user's
/// choices into one `POST /new-tape` and leaves.
///
/// Leaving is the whole success path. The backend schedules the tape and its
/// builder writes the playlist into the library on the next build pass, so
/// the mixtape appears when the backend gets around to it — not when Create
/// is pressed. The tape's settings can be read back meanwhile through the
/// screen's tapes button (``ConfiguredTapes``).
///
/// The name is asked for without the suffix, because the suffix is the
/// backend's own rule: it appends the ending Jelly Jams identifies
/// mixtapes by, so typing it here would double it.
struct MixtapeComposer: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var usesRecents = true
    @State private var usesFavourites = true
    @State private var usesFingerprint = false
    @State private var alchemyPercent = 10.0
    @State private var freshAlchemy = true
    @State private var songCount: Int? = 100
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                nameSection
                toggleSection(title: "Recent Plays", isOn: $usesRecents, hint: "Pull songs from recent listens.")
                toggleSection(title: "Favourites", isOn: $usesFavourites, hint: "Pull songs from favourites.")
                toggleSection(title: "Fingerprint", isOn: $usesFingerprint, hint: "Pull songs from the AudioMuse-AI fingerprint.")
                alchemySection
                toggleSection(title: "Fresh Alchemy", isOn: $freshAlchemy, hint: "Only use Alchemy songs that haven't been listened to recently.")
                countSection
                errorSection
            }
            .navigationTitle("New Mixtape")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!canCreate)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 480)
        .overlay {
            // One send at a time: the button that started it shows the wait.
            if isCreating {
                ProgressView("Creating…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - The fields

    private var nameSection: some View {
        Section {
            TextField("Name", text: $name)
        } header: {
            Text("Name")
        } footer: {
            Text("Name the mixtape. The backend appends “\(preferences.mixtapeSuffix)” to what you write here so that Jelly Jams treats it like a mixtape and not a playlist.")
        }
    }

    private func toggleSection(title: String, isOn: Binding<Bool>, hint: String) -> some View {
        Section {
            Toggle(title, isOn: isOn)
        } footer: {
            Text(hint)
        }
    }

    private var alchemySection: some View {
        Section {
            Slider(value: $alchemyPercent, in: 0...100, step: 1)
        } header: {
            HStack {
                Text("Alchemy Percentage")
                Spacer()
                Text("\(Int(alchemyPercent))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } footer: {
            Text("What percentage of the mixtape's songs should come from AudioMuse-AI alchemy?")
        }
    }

    private var countSection: some View {
        Section {
            TextField("Songs", value: $songCount, format: .number)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        } header: {
            Text("Song Count")
        } footer: {
            Text("How many songs should be on the mixtape?")
        }
    }

    @ViewBuilder private var errorSection: some View {
        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Creating

    /// The form's current answer as the backend would receive it. The send
    /// trims the name; `isSendable` reads the untrimmed text so a name of
    /// spaces alone fails here, not as an empty-named tape on the server.
    private var draft: BackendTapeDraft {
        BackendTapeDraft(
            name: name,
            recents: usesRecents,
            favourites: usesFavourites,
            fingerprint: usesFingerprint,
            freshAlchemy: freshAlchemy,
            alchemyPercent: Int(alchemyPercent),
            songCount: songCount ?? 0
        )
    }

    private var canCreate: Bool {
        !isCreating && draft.isSendable
    }

    /// `POST /new-tape` with everything the form settled on, and the
    /// account the tape belongs to — the user id the sign-in registered
    /// with, never typed here. A success closes the sheet; a refusal keeps
    /// it open, with the backend's words about why beside the fields.
    private func create() {
        guard let backend = JellyJamsBackend.configured(
            address: preferences.jellyJamsBackendAddress,
            deviceInfo: session.deviceInfo
        ), let userID = session.currentUser?.id else {
            errorMessage = BackendError.notSignedIn.errorDescription
            return
        }
        let draft = draft
        guard draft.isSendable else { return } // canCreate already holds the button
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                _ = try await backend.createTape(draft, userID: userID)
                dismiss()
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }
}
