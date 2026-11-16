import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The sheet a Quick Connect sign-in shows while it waits on the user: the
/// code to enter on the Jellyfin server, and the wait for the approval that
/// signs this device in.
///
/// Unlike the backend registration's ``QuickConnectSheet``, there is no
/// Verify step to come back to: the app polls the server itself while this
/// sheet is up, and the sheet closes on its own once the sign-in lands.
/// The user's half is only to enter the code — on the server's own web
/// page, signed in as the account this app should become — so the link
/// opens in the system browser rather than any webview the app could
/// inspect.
struct QuickConnectSignInSheet: View {
    /// Where the flow has got to: asking the server for a code, showing one
    /// while it waits for approval, or the failure that ended the wait.
    enum State {
        case starting
        case waiting(code: String)
        case failed(message: String)
    }

    let state: State
    /// The server the code belongs to, for the browser link — or, on tvOS,
    /// the address to open on another device. Nil while the typed address
    /// has not parsed; the flow reports that as a failure of its own.
    let jellyfinHost: URL?
    /// Starts a fresh flow — a new code — after a failure.
    let onRetry: () -> Void
    /// Abandons the flow and closes the sheet.
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                switch state {
                case .starting:
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Asking the server for a code…")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Quick Connect signs you in without a password: the server gives this app a code, and you approve it while signed in to your Jellyfin server.")
                    }
                case .waiting(let code):
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

                        #if !os(tvOS)
                        Button {
                            copyCode(code)
                        } label: {
                            Label("Copy Code", systemImage: "doc.on.doc")
                        }
                        #endif

                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for approval…")
                        }
                        .foregroundStyle(.secondary)
                    } header: {
                        Text("Your Code")
                    } footer: {
                        Text("Enter this code on your Jellyfin server’s Quick Connect page. The account that approves it is the one Jelly Jams signs in as. Codes expire after a couple of minutes.")
                    }
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("Try Again") { onRetry() }
                    }
                }

                if let quickConnectURL {
                    Section {
                        #if os(tvOS)
                        // tvOS has no browser to hand the URL to, so show the
                        // address to open on another device instead of a link.
                        Text(quickConnectURL.absoluteString)
                            .font(.callout)
                        #else
                        Link(destination: quickConnectURL) {
                            Label("Open Quick Connect in your browser", systemImage: "safari")
                        }
                        #endif
                    } header: {
                        Text("On your server")
                    } footer: {
                        #if os(tvOS)
                        Text("On another device, open this address and sign in to your Jellyfin server, then enter the code on its Quick Connect page. Once it’s approved, Jelly Jams signs in here automatically.")
                        #else
                        Text("Opens \(quickConnectURL.host() ?? "your Jellyfin server")/web/#/quickconnect in your default browser — sign in there if you aren’t already, then enter the code. Once it’s approved, Jelly Jams signs in here automatically.")
                        #endif
                    }
                }
            }
            .navigationTitle("Quick Connect")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
        #if os(tvOS)
        .frame(minWidth: 1280, minHeight: 720)
        #elseif os(macOS)
        // macOS sheets size to their content, so they need a floor. iOS
        // sheets are sized by the system to fit the device — a minimum here
        // would only overflow the smaller phones — so they get none.
        .frame(minWidth: 500, minHeight: 500)
        #endif
    }

    /// The server's own Quick Connect page: Jellyfin's web UI at
    /// `/web/#/quickconnect`, built by hand because `URLComponents` treats
    /// a `#` path as a fragment rather than the literal route the SPA
    /// reads.
    private var quickConnectURL: URL? {
        guard let jellyfinHost else { return nil }
        var base = jellyfinHost.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/web/#/quickconnect") ?? jellyfinHost
    }

    private func copyCode(_ code: String) {
        #if os(iOS)
        UIPasteboard.general.string = code
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
    }
}
