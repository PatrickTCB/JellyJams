import SwiftUI

/// The tvOS section bar, rendered as scrolling content.
///
/// tvOS has no scroll-away navigation bar: the native minimization behaviors
/// are unavailable there, and toggling `toolbarVisibility` from scroll
/// geometry deadlocks the focus-driven scroll engine (the bar's safe-area
/// changes feed back into the geometry that drives them). So on tvOS the
/// section roots hide the bar once — statically — and render its contents
/// here, as the first row of the scrolling content: the bar scrolls with the
/// view, the way the iOS large title does, and nothing changes mid-scroll.
///
/// The pieces arrive through the environment so the declarations stay where
/// they already live: the section root names its title and local actions
/// (``View/tvScrollingBar(title:actions:)``), the shell adds the account menu
/// and Home's Text to Tunes button, and the refresh / new-playlist helpers
/// contribute their buttons without the sections knowing.
/// ``TVScrollingBarSlot`` — placed inside each section's scroll container —
/// composes them. Every part is a no-op on the other platforms, where the
/// system bar keeps its native behavior.

/// A section's own contribution: its title and its local toolbar actions.
struct TVScrollingBarContent {
    let title: String
    let actions: AnyView
}

// The channel carries views and view closures, which are not `Sendable`;
// every default is an immutable nil, so the shared defaults opt out of
// isolation explicitly.
private struct TVScrollingBarKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: TVScrollingBarContent? = nil
}

private struct TVShellBarActionsKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: AnyView? = nil
}

private struct TVBarRefreshKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() async -> Void)? = nil
}

private struct TVBarNewPlaylistKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: AnyView? = nil
}

extension EnvironmentValues {
    /// The section's title and local actions, set by the section root.
    var tvScrollingBar: TVScrollingBarContent? {
        get { self[TVScrollingBarKey.self] }
        set { self[TVScrollingBarKey.self] = newValue }
    }

    /// The shell's actions — the account menu, and Home's Text to Tunes.
    var tvShellBarActions: AnyView? {
        get { self[TVShellBarActionsKey.self] }
        set { self[TVShellBarActionsKey.self] = newValue }
    }

    /// The refresh action contributed by ``View/refreshToolbarItem(_:)``.
    var tvBarRefresh: (() async -> Void)? {
        get { self[TVBarRefreshKey.self] }
        set { self[TVBarRefreshKey.self] = newValue }
    }

    /// The New Playlist button contributed by ``View/newPlaylistToolbarItem(onCreated:)``.
    var tvBarNewPlaylist: AnyView? {
        get { self[TVBarNewPlaylistKey.self] }
        set { self[TVBarNewPlaylistKey.self] = newValue }
    }
}

extension View {
    /// Declares this section's scrolling bar on tvOS: the title and the
    /// actions that ride beside it. A no-op elsewhere — the system bar shows
    /// the same content through `.navigationTitle` and `.toolbar`.
    func tvScrollingBar<Actions: View>(
        title: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) -> some View {
        #if os(tvOS)
        environment(\.tvScrollingBar, TVScrollingBarContent(title: title, actions: AnyView(actions())))
        #else
        self
        #endif
    }
}

/// The bar itself. Placed as the first element of a section's scrolling
/// content; renders nothing on platforms that keep the system bar, and
/// nothing on tvOS screens that declare no bar (Search keeps its own).
struct TVScrollingBarSlot: View {
    @Environment(\.tvScrollingBar) private var bar
    @Environment(\.tvShellBarActions) private var shellActions
    @Environment(\.tvBarRefresh) private var refresh
    @Environment(\.tvBarNewPlaylist) private var newPlaylist

    var body: some View {
        #if os(tvOS)
        if let bar {
            HStack(spacing: 24) {
                Text(bar.title)
                    .font(.largeTitle.bold())
                Spacer(minLength: 16)
                bar.actions
                if let newPlaylist { newPlaylist }
                if let refresh {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                if let shellActions { shellActions }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        #endif
    }
}
