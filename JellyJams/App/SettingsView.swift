import SwiftUI

/// The app's settings screen. Phase 1 exposes account details and sign out;
/// playback/download preferences arrive in a later phase.
///
/// On macOS this is the content of the `Settings` scene — the standard
/// settings window, opened from the app menu with ⌘, or from ``AccountMenu``.
/// iOS has no settings scene, so ``MainShellView`` presents the same form as a
/// sheet and this view supplies its own navigation chrome.
struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            form
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #else
        form
            .formStyle(.grouped)
            // Ideal rather than fixed: a fixed frame is what makes a settings
            // window refuse to resize. The minimums stop it being dragged
            // narrower than the toggle labels or shorter than a couple of rows;
            // the grouped form scrolls below that.
            .frame(
                minWidth: 420,
                idealWidth: 460,
                maxWidth: .infinity,
                minHeight: 320,
                idealHeight: 420,
                maxHeight: .infinity
            )
            .background(ResizableWindow())
        #endif
    }

    private var form: some View {
        Form {
            Section("Account") {
                if let user = session.currentUser {
                    LabeledContent("Signed in as", value: user.name)
                    LabeledContent("Server", value: user.serverName ?? user.serverURL.host() ?? "—")
                    LabeledContent("Address", value: user.serverURL.absoluteString)
                } else {
                    Text("Not signed in").foregroundStyle(.secondary)
                }
                Button("Sign Out", role: .destructive) { signOut() }
                    .disabled(session.currentUser == nil)
            }

            Section {
                Toggle("Show Similar Albums & Artists", isOn: $preferences.showsSimilarItems)
            } header: {
                Text("Library")
            } footer: {
                Text("Suggests similar music at the foot of album and artist screens. Turning this off skips the lookup rather than hiding its results, so your server is never asked.")
            }

            Section("About") {
                LabeledContent("Jelly Jams", value: appVersion)
            }
        }
    }

    /// Signing out swaps the app shell for onboarding. On iOS the sheet is
    /// hosted by that shell, so it is dismissed first — both so it animates out
    /// over the screen it belongs to and to clear the flag driving it.
    private func signOut() {
        #if os(iOS)
        dismiss()
        #endif
        session.signOut()
    }
}

#if os(macOS)
/// Makes the window hosting this view resizable.
///
/// SwiftUI builds the `Settings` scene's window without the resizable style
/// mask, and `windowResizability` does not change that — the zoom button stays
/// disabled and the window stays fixed however flexible the content's frame is.
/// The style mask is the only place that decision lives, so this reaches the
/// hosting window and sets it there.
///
/// Done with an `NSView` subclass rather than a callback from `updateNSView`,
/// because the window is only attached once the view is in a hierarchy and
/// `viewDidMoveToWindow` is exactly the moment that happens.
private struct ResizableWindow: NSViewRepresentable {
    final class AttachmentView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.styleMask.insert(.resizable)
        }
    }

    func makeNSView(context: Context) -> AttachmentView { AttachmentView() }

    func updateNSView(_ view: AttachmentView, context: Context) {
        view.window?.styleMask.insert(.resizable)
    }
}
#endif
