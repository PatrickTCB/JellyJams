import SwiftUI

/// A toolbar menu showing the signed-in user, with a way into Settings and a
/// Sign Out action.
struct AccountMenu: View {
    @EnvironmentObject private var session: SessionStore
    #if os(iOS)
    @EnvironmentObject private var settingsPresentation: SettingsPresentation
    #endif

    var body: some View {
        Menu {
            if let user = session.currentUser {
                Section {
                    Text("User: \(user.name)")
                }
                Section {
                    Text("Server: \(user.serverName ?? "-")")
                    Text("Address: \(user.serverURL.host() ?? "-")")
                }
            }
            Section {
                settingsButton
            }
            Button(role: .destructive) {
                session.signOut()
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
    }

    /// `SettingsLink` is the only supported way to open the macOS settings
    /// window from a button, and it leaves the app menu's ⌘, item intact. iOS
    /// has no settings scene, so the flag ``MainShellView`` watches is raised
    /// instead.
    @ViewBuilder private var settingsButton: some View {
        #if os(macOS)
        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        #else
        Button {
            settingsPresentation.isShowingSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        #endif
    }
}
