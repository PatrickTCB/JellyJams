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
    /// Apply only where a down press has nowhere native to go: the page's
    /// bottom-most section (or its last row). Elsewhere the handler would
    /// fight the engine's own downward move. No-op on platforms without the
    /// remote, and while `isEnabled` is false — which is how a section that
    /// is only sometimes the bottom (genres above a similar row that may be
    /// empty) stands down when it isn't.
    @ViewBuilder func remoteFocusWrap(isEnabled: Bool = true, _ wrap: @escaping () -> Void) -> some View {
        #if os(tvOS)
        if isEnabled {
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