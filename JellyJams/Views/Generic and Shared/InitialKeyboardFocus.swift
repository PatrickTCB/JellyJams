import SwiftUI

extension View {
    /// Stops AppKit from handing keyboard focus to the first control when the
    /// enclosing window or sheet appears, without taking anything out of the Tab
    /// loop — the first Tab press focuses the first control as normal.
    ///
    /// SwiftUI has no declarative equivalent: `defaultFocus(_:_:priority:)` with a
    /// `nil` value and `prefersDefaultFocus(false, in:)` both leave the automatic
    /// first-responder assignment in place, so the window has to be told directly.
    /// No-op on platforms without a key view loop.
    func clearsInitialKeyboardFocus() -> some View {
        #if os(macOS)
        background(
            InitialKeyboardFocusClearer()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct InitialKeyboardFocusClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Clears the window's first responder once, at the point AppKit installs the
/// initial one (i.e. when the window becomes key). Never becomes first responder
/// itself, so it adds no stop to the Tab loop.
private final class ClearerView: NSView {
    private var hasCleared = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard !hasCleared, let window else { return }

        if window.isKeyWindow {
            // Focus was installed during this run loop pass; undo it on the next.
            DispatchQueue.main.async { [weak self] in self?.clearFocus() }
        } else {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }
    }

    @objc private func windowDidBecomeKey() {
        clearFocus()
    }

    private func clearFocus() {
        guard !hasCleared, let window, window.isKeyWindow else { return }
        hasCleared = true
        NotificationCenter.default.removeObserver(self)
        window.makeFirstResponder(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
#endif
