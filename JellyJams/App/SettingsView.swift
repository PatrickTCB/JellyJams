import SwiftUI

/// The app's settings screen: the account and its sign-out, the library,
/// the Jelly Jams Backend sheet, and the default-playback choice.
///
/// On macOS this is the content of the `Settings` scene — the standard
/// settings window, opened from the app menu with ⌘, or from ``AccountMenu``.
/// iOS and tvOS have no settings scene, so ``MainShellView`` presents the same
/// form as a sheet and this view supplies its own navigation chrome. On tvOS
/// that chrome scrolls with the content instead of pinning a glass bar over it,
/// and the sheet is sized to stay within the screen so every row can be scrolled
/// to. The first and last rows are focusable so the focus-driven scroll can reach
/// both ends.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(PreferencesStore.self) private var preferences
    #if !os(macOS)
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
        #if !os(macOS)
        NavigationStack {
            form
                #if os(tvOS)
                // tvOS has no scroll-away navigation bar, and a pinned glass bar
                // lets rows scroll up behind it — the focus-scroll safe-area
                // feedback the library sections sidestep with ``TVScrollingBar``.
                // Hide the bar and let the title ride the scrolling content
                // instead; the remote's Menu button still dismisses.
                .toolbarVisibility(.hidden, for: .navigationBar)
                // Inset the form from the sheet's edge so the rows' rounded
                // leading/trailing corners aren't clipped by the card. Horizontal
                // only, and inside the stack: padding outside the frame would
                // resize the sheet, and vertical padding would push the scroll
                // viewport past the bottom edge again.
                .padding(.horizontal, 40)
                // The focus lift draws a highlighted row larger than its frame.
                // The form clips its content to its own bounds, so that lift was
                // cut off at the (inset) edge no matter how much padding was added.
                // Letting the scroll content draw past those bounds gives the lift
                // room to render fully inside the padding above.
                .scrollClipDisabled(true)
                #else
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #endif
        }
        #if os(tvOS)
        // Keep the sheet shorter than the 1080pt screen. An ideal height at the
        // full screen height (the old 1080 plus padding) pushes the form's scroll
        // viewport past the bottom edge, so the last rows fade out behind it and
        // can never be scrolled to. 1000 leaves room for the sheet's own margins.
        .frame(minWidth: 1280, idealWidth: 1920, minHeight: 720, idealHeight: 1000)
        #endif
        .remotePlayPause()
        #else
        form
            .formStyle(.grouped)
            // Ideal rather than fixed: a fixed frame is what makes a settings
            // window refuse to resize. The minimums stop it being dragged
            // narrower than the toggle labels or shorter than a couple of rows;
            // the grouped form scrolls below that.
            .frame(
                minWidth: 420,
                maxWidth: .infinity,
                minHeight: 320,
                maxHeight: .infinity
            )
            .background(ResizableWindow())
        #endif
    }

    private var form: some View {
        Form {
            #if os(tvOS)
            // The title scrolls with the content (the navigation bar is hidden
            // on tvOS). It is a section header — never a focus target — while
            // Done is a real row beneath it: tvOS scrolls by moving focus, so the
            // top of the form needs a focusable row to scroll back up to, and to
            // dismiss from. A header alone is unreachable once focus moves down.
            Section {
                Button("Done") { dismiss() }
            } header: {
                Text("Settings")
                    .font(.largeTitle.bold())
                    .textCase(nil)
            }
            #endif

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
                Toggle("Show Similar Albums & Artists", isOn: Bindable(preferences).showsSimilarItems)
            } header: {
                Text("Library")
            } footer: {
                Text("Suggests similar music at the foot of album and artist screens. Turning this off skips the lookup rather than hiding its results, so your server is never asked.")
            }

            Section {
                Toggle("Normalize Volume", isOn: Bindable(preferences).audioNormalizationEnabled)
            } header: {
                Text("Audio")
            } footer: {
                Text("Normalizes volume for each track using Jellyfin's data. On by default.")
            }

            Section {
                Button {
                    isShowingBackendSettings = true
                } label: {
                    LabeledContent("Jelly Jams Backend", value: backendSettingsSummary)
                }
            } footer: {
                Text("The companion / sidecar service behind generated features like Mixtapes and the Server Playlist '\(preferences.serverPlaylist)'. Its settings check in with the backend as they open — unreachable, they show what was last saved.")
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
                #if os(tvOS)
                // A focusable row so the focus-driven scroll can reach the very
                // bottom of the form; selecting it does nothing.
                Button {} label: {
                    LabeledContent("Jelly Jams", value: appVersion)
                }
                #else
                LabeledContent("Jelly Jams", value: appVersion)
                #endif
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
        preferences.isBackendConfigured ? "Registered" : "Not registered"
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
        #if !os(macOS)
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
