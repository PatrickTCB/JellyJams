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
        content.toolbar {
            if showsButton {
                ToolbarItem {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
    }
}

extension View {
    /// Adds a Refresh toolbar button (⌘R) on platforms without pull-to-refresh.
    /// Pass `isAvailable: false` to suppress it (e.g. offline content that
    /// cannot reload).
    func refreshToolbarItem(isAvailable: Bool = true, _ refresh: @escaping () async -> Void) -> some View {
        modifier(RefreshToolbarModifier(isAvailable: isAvailable, refresh: refresh))
    }
}
