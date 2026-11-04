import SwiftUI

/// The form behind the Home screen's sparkles button: it turns a free-text
/// description of what the listener wants to hear into one
/// `GET /text-to-tunes`, resolves the picks through the user's own Jellyfin
/// server, and hands them to the player as a fresh queue that starts right
/// away.
///
/// The backend never sends whole items — only the ids it picked — so the
/// resolution is the same one Infinite Queue does: `tracks(byIds:)` keeps
/// the backend's order, which is the order the songs play in, and drops ids
/// the server no longer knows rather than failing the batch. A pick that
/// resolves to nothing leaves the sheet open saying so instead of closing
/// over a player that stays silent.
struct TextToTunesSheet: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var songCount: Int? = 30
    @State private var isRequesting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                aboutSection
                querySection
                countSection
                errorSection
            }
            .navigationTitle("Text to Tunes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Play") { request() }
                        .disabled(!canRequest)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 360)
        .overlay {
            // One request at a time: the button that started it shows the wait.
            if isRequesting {
                ProgressView("Finding tunes…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - The fields

    private var aboutSection: some View {
        Section {
            Text("Enter a short description of what kind of music you want to hear. For example ‘Up tempo folk about Canada’ or ‘Heavy metal break-up songs’ and the Jelly Jams Backend will get you some tunes.")
        }
    }

    private var querySection: some View {
        Section {
            TextField("What do you want to hear?", text: $query, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("Description")
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
            Text("How many songs should the backend pick?")
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

    // MARK: - Requesting

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A description is the whole request, so there is nothing to send
    /// without one — and no point asking for fewer than a song. The count
    /// field can be cleared, which `songCount` reads as nil.
    private var canRequest: Bool {
        !isRequesting && !trimmedQuery.isEmpty && (songCount ?? 0) >= 1
    }

    /// `GET /text-to-tunes` with what the form settled on, and the account
    /// the picks belong to — the user id the sign-in registered with, never
    /// typed here. A success replaces the queue, starts it and closes the
    /// sheet; a refusal keeps the sheet open, with the backend's words about
    /// why beside the fields.
    private func request() {
        guard let backend = JellyJamsBackend.configured(
            address: preferences.jellyJamsBackendAddress,
            deviceInfo: session.deviceInfo
        ), let userID = session.currentUser?.id else {
            errorMessage = BackendError.notSignedIn.errorDescription
            return
        }
        guard let client = session.client else {
            errorMessage = JellyfinError.notAuthenticated.errorDescription
            return
        }
        let query = trimmedQuery
        guard !query.isEmpty, let songCount, songCount >= 1 else { return } // canRequest already holds the button
        isRequesting = true
        errorMessage = nil
        Task {
            defer { isRequesting = false }
            do {
                let answer = try await backend.textToTunes(userID: userID, query: query, limit: songCount)
                guard !answer.newTrackIDs.isEmpty else {
                    errorMessage = "The backend couldn’t find any songs for that description — try a broader one."
                    return
                }
                let tracks = try await client.tracks(byIds: answer.newTrackIDs)
                guard !tracks.isEmpty else {
                    errorMessage = "None of the songs the backend picked could be found on your server."
                    return
                }
                player.play(tracks)
                dismiss()
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }
}
