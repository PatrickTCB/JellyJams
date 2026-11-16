import SwiftUI

extension View {
    /// Marks this view's frame as one logical focus target for the Siri
    /// Remote, so directional focus can enter it even when none of its
    /// focusable items sits directly in the path — a lone album tile at the
    /// far left of a grid is still "below" the header buttons once the whole
    /// section is the target.
    ///
    /// tvOS only: `focusSection()` exists on macOS too, but applying it
    /// there would reshape the key-view loop the keyboard navigation relies
    /// on, so elsewhere this is a no-op.
    func remoteFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    /// Wraps focus back to the top of the page when a down press would leave
    /// its bottom — the focus engine never wraps on its own.
    ///
    /// Attach to the focusable control itself, not a container around it:
    /// a handler on an ancestor of the focused button does not reliably
    /// receive the move command. Pass nil for items that aren't the page's
    /// bottom-most — elsewhere the handler would fight the engine's own
    /// downward move. No-op on platforms without the remote.
    @ViewBuilder func remoteFocusWrapItem(_ wrap: (() -> Void)?) -> some View {
        #if os(tvOS)
        if let wrap {
            onMoveCommand { direction in
                if direction == .down { wrap() }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
