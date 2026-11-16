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
}