import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The sheet that hands the user their Quick Connect code while the Jelly
/// Jams Backend waits on the Jellyfin server.
///
/// Registration is no longer something the app can finish alone: the
/// backend opens a Quick Connect session and the code it got only means
/// anything typed into the server's own web page. So the app's part is to
/// show the code, get it to the clipboard or the browser without fuss, and
/// wait — the user enters the code on the server, comes back, presses
/// Done, and presses Verify in the settings sheet to see how it went.
///
/// The link opens in the system's default browser rather than any webview:
/// logging in to the Jellyfin server belongs to the server, and a code
/// typed into a webview the app could inspect is a code the app is
/// standing between.
struct QuickConnectSheet: View {
    /// The account whose sign-in the server should be showing while the
    /// code is typed, for the instructions to name it.
    let userName: String
    /// The code the backend's Quick Connect session is waiting for.
    let code: String
    /// The signed-in Jellyfin server, whose web UI carries the Quick
    /// Connect page the code belongs to.
    let jellyfinHost: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        Text(code)
                            .font(.system(.largeTitle, design: .monospaced))
                            #if !os(tvOS)
                            .textSelection(.enabled)
                            #endif
                        Spacer()
                    }
                    .padding(.vertical, 4)

                    Button {
                        copyCode()
                    } label: {
                        Label("Copy Code", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("Your Code")
                } footer: {
                    Text("Enter this code on your Jellyfin server's Quick Connect page, signed in as “\(userName)”. It expires in a couple of minutes; if it gets stale, start a new Sign In from here.")
                }

                #if os(tvOS)
                // tvOS has no browser to hand the URL to, so show the address
                // to open on another device instead of a link.
                Section {
                    Text(quickConnectURL.absoluteString)
                        .font(.callout)
                } header: {
                    Text("On your server")
                } footer: {
                    Text("On another device, open this address and enter the code, signed in as “\(userName)”. Once it’s accepted, come back and press Done, then press Verify.")
                }
                #else
                Section {
                    Link(destination: quickConnectURL) {
                        Label("Open Quick Connect in your browser", systemImage: "safari")
                    }
                } header: {
                    Text("On your server")
                } footer: {
                    Text("This opens \(jellyfinHost.host() ?? "your Jellyfin server")/web/#/quickconnect in your default browser. Once the code is accepted, come back and press Done, then press Verify.")
                }
                #endif
            }
            .navigationTitle("Quick Connect")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 320)
        .remotePlayPause()
    }

    /// The server's own Quick Connect page: Jellyfin's web UI at
    /// `/web/#/quickconnect`, built by hand because `URLComponents` treats
    /// a `#` path as a fragment rather than the literal route the SPA
    /// reads.
    private var quickConnectURL: URL {
        var base = jellyfinHost.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/web/#/quickconnect") ?? jellyfinHost
    }

    private func copyCode() {
        #if os(iOS)
        UIPasteboard.general.string = code
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
    }
}
