import SwiftUI

/// Adds the standard "Refresh" toolbar button to a browsing screen.
///
/// The button is for pointer-and-keyboard contexts that have no pull-to-refresh
/// gesture: always on macOS, and on iPad (regular width) but not iPhone, where
/// the list is pulled down instead.
private struct RefreshToolbarModifier: ViewModifier {
    var isAvailable = true
    let refresh: () async -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var showsButton: Bool { isAvailable && horizontalSizeClass == .regular }
    #else
    private var showsButton: Bool { isAvailable }
    #endif

    func body(content: Content) -> some View {
        let toolbared = content.toolbar {
            if showsButton {
                ToolbarItem {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    #if !os(tvOS)
                    .keyboardShortcut("r", modifiers: .command)
                    #endif
                }
            }
        }
        #if os(tvOS)
        // tvOS browsing screens hide the system bar; their scrolling bar
        // renders the refresh action from here instead.
        return toolbared.environment(\.tvBarRefresh, isAvailable ? refresh : nil)
        #else
        return toolbared
        #endif
    }
}

extension View {
    /// Adds a Refresh toolbar button (⌘R) on platforms without pull-to-refresh.
    /// Pass `isAvailable: false` to suppress it (e.g. offline content that
    /// cannot reload).
    func refreshToolbarItem(isAvailable: Bool = true, _ refresh: @escaping () async -> Void) -> some View {
        modifier(RefreshToolbarModifier(isAvailable: isAvailable, refresh: refresh))
    }

    /// Adds pull-to-refresh only where a reload is possible.
    ///
    /// `.refreshable` cannot be switched off from inside its own closure: the
    /// gesture and its spinner still appear. Content that has nothing to reload
    /// — a downloaded collection, read entirely from the manifest — gets no
    /// gesture at all instead of one that lies.
    @ViewBuilder func refreshableWhenAvailable(
        _ available: Bool,
        operation: @escaping @Sendable () async -> Void
    ) -> some View {
        if available {
            refreshable(action: operation)
        } else {
            self
        }
    }
}
