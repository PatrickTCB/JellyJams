import SwiftUI

/// Adds the standard "Refresh" toolbar button to a browsing screen.
///
/// The button is for pointer-and-keyboard contexts that have no pull-to-refresh
/// gesture: always on macOS, and on iPad (regular width) but not iPhone, where
/// the list is pulled down instead.
private struct RefreshToolbarModifier: ViewModifier {
    let refresh: () async -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isAvailable: Bool { horizontalSizeClass == .regular }
    #else
    private var isAvailable: Bool { true }
    #endif

    func body(content: Content) -> some View {
        content.toolbar {
            if isAvailable {
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
    func refreshToolbarItem(_ refresh: @escaping () async -> Void) -> some View {
        modifier(RefreshToolbarModifier(refresh: refresh))
    }
}
