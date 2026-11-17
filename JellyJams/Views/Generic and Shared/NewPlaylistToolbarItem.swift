import SwiftUI

/// Adds the standard "New Playlist" toolbar button with its naming alert.
///
/// Creates an empty playlist via ``PlaylistStore``; pass `onCreated` to react
/// (e.g. reload the visible list). Failures surface in an error alert.
private struct NewPlaylistModifier: ViewModifier {
    @Environment(PlaylistStore.self) private var playlistStore

    let onCreated: () async -> Void

    @State private var isPresenting = false
    @State private var name = ""
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        let toolbared = content.toolbar {
            ToolbarItem {
                newPlaylistButton
            }
        }
        #if os(tvOS)
        // tvOS browsing screens hide the system bar; their scrolling bar
        // renders the button from here. The alerts stay attached either way.
        let placed = toolbared.environment(\.tvBarNewPlaylist, AnyView(newPlaylistButton))
        #else
        let placed = toolbared
        #endif
        return placed
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

    private var newPlaylistButton: some View {
        Button {
            isPresenting = true
        } label: {
            Label("New Playlist", systemImage: "plus")
        }
        #if !os(tvOS)
        .keyboardShortcut("n", modifiers: .command)
        #endif
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
