import SwiftUI

/// Lets a grid's cells ask their enclosing grid to reload after a server-side
/// mutation, without the cell knowing anything about the grid's model.
///
/// ``ItemGrid`` provides the action; ``ItemContextMenu`` calls it after
/// destructive changes (e.g. deleting a playlist). Where no grid is present —
/// a menu shown outside a grid — the call is simply a no-op.
private struct GridRefreshActionKey: EnvironmentKey {
    static let defaultValue: (@Sendable () async -> Void)? = nil
}

extension EnvironmentValues {
    /// Reloads the enclosing grid's list, if there is one.
    var gridRefreshAction: (@Sendable () async -> Void)? {
        get { self[GridRefreshActionKey.self] }
        set { self[GridRefreshActionKey.self] = newValue }
    }
}

extension View {
    /// Provides the reload that descendants (e.g. a cell's context menu) can
    /// trigger after a server-side mutation.
    func gridRefreshAction(_ refresh: @escaping @Sendable () async -> Void) -> some View {
        environment(\.gridRefreshAction, refresh)
    }
}
