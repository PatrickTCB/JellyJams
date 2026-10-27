import SwiftUI

/// The tapes button on the Mixtapes screen: `GET /tapes`, read back as
/// the account's recipes — what feeds each tape, how much of it is
/// alchemy, and how big it aims to be.
///
/// These are the instructions to the backend's builder, not the playlists
/// themselves; the library holds those and the grid shows them. A tape
/// rewritten by the "+" form lands here immediately, and in the library
/// only when the builder next runs.
struct ConfiguredTapes: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var tapes: [BackendMixtape] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Configured Tapes")
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
        .task { await load() }
    }

    /// Loaded recipes are a list; none yet, with a read in flight, is a
    /// spinner; none after a read is either the invitation to make the
    /// first tape, or the refusal that stopped us asking.
    @ViewBuilder private var content: some View {
        if !tapes.isEmpty {
            List {
                ForEach(tapes, id: \.name) { tape in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tape.name)
                        Text(tape.recipeSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    // A refused refresh over an older answer — the rows it
                    // could not replace stay up, with the reason under them.
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Tapes Set Up", systemImage: "recordingtape.circle")
            } description: {
                Text(errorMessage ?? "The + button asks the backend for a first tape.")
            } actions: {
                if errorMessage != nil {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let backend = JellyJamsBackend.configured(
            address: preferences.jellyJamsBackendAddress,
            deviceInfo: session.deviceInfo
        ), let userID = session.currentUser?.id else {
            isLoading = false
            errorMessage = BackendError.notSignedIn.errorDescription
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let answer = try await backend.tapes(userID: userID)
            tapes = answer.tapes
            errorMessage = nil
        } catch where error.isCancellation {
            // A dismissal mid-read; the next opening asks again.
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}

private extension BackendMixtape {
    /// One line describing what a tape is made of: the sources it may
    /// draw from, then the alchemy share, then the size. "fresh" marks
    /// alchemy that steers clear of recently-heard picks.
    var recipeSummary: String {
        var sources: [String] = []
        if usesRecents { sources.append("recent plays") }
        if usesFavourites { sources.append("favourites") }
        if usesFingerprint { sources.append("fingerprint") }
        var text = sources.isEmpty ? "no sources" : sources.joined(separator: ", ")
        text += " · \(alchemyPercent)% alchemy"
        if usesFreshAlchemy { text += " (fresh)" }
        text += " · \(Format.songCount(songCount))"
        return text
    }
}
