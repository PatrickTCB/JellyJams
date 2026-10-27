import SwiftUI

/// The app's settings screen: the account and its sign-out, the library,
/// the Jelly Jams Backend sheet, and the default-playback choice.
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
    @State private var isChoosingDefaultPlayback = false
    @State private var isShowingBackendSettings = false

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

            Section {
                Button {
                    isShowingBackendSettings = true
                } label: {
                    LabeledContent("Jelly Jams Backend", value: backendSettingsSummary)
                }
            } footer: {
                Text("The companion service behind generated features like Mixtapes and Family Blend. Its settings check in with the backend as they open — unreachable, they show what was last saved.")
            }

            Section {
                Button {
                    isChoosingDefaultPlayback = true
                } label: {
                    LabeledContent("Default Playback", value: defaultPlaybackSummary)
                }
            } footer: {
                Text("What Siri starts for \"play some music\" requests, and what the play button starts when nothing is queued.")
            }

            Section("About") {
                LabeledContent("Jelly Jams", value: appVersion)
            }
        }
        .sheet(isPresented: $isChoosingDefaultPlayback) {
            DefaultPlaybackSettingsView()
        }
        .sheet(isPresented: $isShowingBackendSettings) {
            JellyJamsBackendSettingsView()
        }
    }

    /// One glance at how far the backend relationship got: an address alone
    /// is ambition, registration is the fact.
    private var backendSettingsSummary: String {
        preferences.isMixtapesActive ? "Registered" : "Not registered"
    }

    private var defaultPlaybackSummary: String {
        guard let setting = preferences.defaultPlayback else { return "Favourite Songs" }
        var summary = "\(setting.title) (\(setting.kind.label))"
        if setting.shuffle { summary += ", shuffled" }
        switch setting.repeatMode {
        case .repeatAll: summary += ", repeat all"
        case .repeatOne: summary += ", repeat one"
        case .repeatNone: break
        }
        return summary
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
