import SwiftUI

/// The tapes button on the Mixtapes screen: `GET /tapes`, read back as
/// the account's recipes — what feeds each tape, how much of it is
/// alchemy, and how big it aims to be.
///
/// These are the instructions to the backend's builder, not the playlists
/// themselves; the library holds those and the grid shows them. A tape
/// rewritten by the "+" form lands here immediately, and in the library
/// only when the builder next runs.
///
/// Retiring one works like the queue: a swipe takes the row out on iOS,
/// a selection and the delete key on macOS, and the sheet tells the
/// backend after the row is gone — the refusal puts the row back.
struct ConfiguredTapes: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var tapes: [BackendMixtape] = []
    /// The list's selection, keyed by tape name — the row identity, and
    /// what `DELETE /delete-tape` deletes by. macOS binds it to the list
    /// and the delete key answers to it; iOS rows are never selected, so
    /// there it simply stays empty.
    @State private var selection: Set<String> = []
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
            #if os(iOS)
            List { rows }
            #else
            List(selection: $selection) { rows }
            #endif
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

    @ViewBuilder private var rows: some View {
        ForEach(tapes, id: \.name) { tape in
            VStack(alignment: .leading, spacing: 2) {
                Text(tape.name)
                Text(tape.recipeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDelete { delete(at: $0) }

        if let errorMessage {
            // A refused read or removal over an older answer — the rows it
            // could not replace stay up, with the reason under them.
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
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

    /// `DELETE /delete-tape` for each row just taken out, one name at a
    /// time — the endpoint deletes a single recipe.
    ///
    /// Removal is optimistic, the way the queue empties: the row leaves
    /// with the gesture and the backend is told after. A refusal puts the
    /// whole set back with the backend's reason beside it, and a 404 is
    /// deliberately not a refusal — a name the server no longer has is
    /// exactly the state the swipe asked for, so those rows stay gone.
    private func delete(at offsets: IndexSet) {
        guard let backend = JellyJamsBackend.configured(
            address: preferences.jellyJamsBackendAddress,
            deviceInfo: session.deviceInfo
        ), let userID = session.currentUser?.id else {
            errorMessage = BackendError.notSignedIn.errorDescription
            return
        }
        let names = offsets.map { tapes[$0].name }
        let snapshot = tapes
        tapes.remove(atOffsets: offsets)
        selection.subtract(names)

        Task {
            for name in names {
                do {
                    _ = try await backend.deleteTape(name: name, userID: userID)
                } catch let error as BackendError {
                    if case .rejected(let status, _) = error, status == 404 { continue }
                    tapes = snapshot
                    errorMessage = error.userFacingMessage
                    return
                } catch {
                    // Cancelled on the way out — the sheet is gone and so
                    // is the reading of these rows; leave them gone.
                    if error.isCancellation { return }
                    tapes = snapshot
                    errorMessage = error.userFacingMessage
                    return
                }
            }
            errorMessage = nil
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
