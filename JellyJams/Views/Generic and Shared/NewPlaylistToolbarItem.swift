import SwiftUI

/// Adds the standard "New Playlist" toolbar button with its naming alert.
///
/// Creates an empty playlist via ``PlaylistStore``; pass `onCreated` to react
/// (e.g. reload the visible list). Failures surface in an error alert.
private struct NewPlaylistModifier: ViewModifier {
    @EnvironmentObject private var playlistStore: PlaylistStore

    let onCreated: () async -> Void

    @State private var isPresenting = false
    @State private var name = ""
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem {
                    Button {
                        isPresenting = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            .alert("New Playlist", isPresented: $isPresenting) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { name = "" }
                Button("Create") {
                    let playlistName = name
                    name = ""
                    create(named: playlistName)
                }
            } message: {
                Text("Create a new playlist.")
            }
            .alert(
                "Couldn’t Create Playlist",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func create(named playlistName: String) {
        Task {
            do {
                try await playlistStore.createPlaylist(named: playlistName, itemIds: [])
                await onCreated()
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }
}

extension View {
    /// Adds a New Playlist toolbar button (⌘N) that prompts for a name and
    /// creates an empty playlist.
    func newPlaylistToolbarItem(onCreated: @escaping () async -> Void) -> some View {
        modifier(NewPlaylistModifier(onCreated: onCreated))
    }
}
