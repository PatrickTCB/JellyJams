import Foundation
import OSLog
import SwiftUI

/// Marks a subtree as browsing *downloaded* content.
///
/// The promise it encodes is that browsing downloads issues no network requests
/// at all: rows read the ``DownloadStore`` manifest, artwork resolves from saved
/// files, and the background cache refreshes that library rows normally trigger
/// on appear stay quiet. ``DownloadStore`` itself never reads the environment —
/// the flag exists for the views and for the debug tripwire.
private struct OfflineBrowsingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the Downloads section and the screens it pushes.
    var offlineBrowsing: Bool {
        get { self[OfflineBrowsingKey.self] }
        set { self[OfflineBrowsingKey.self] = newValue }
    }
}

extension View {
    /// Declares this subtree a browser of downloaded content: descendants read
    /// ``EnvironmentValues/offlineBrowsing`` to keep off the network, and in debug
    /// builds any request issued from here is reported.
    func downloadsBrowsing() -> some View {
        environment(\.offlineBrowsing, true)
            .onAppear { DownloadsAudit.beginBrowsing() }
            .onDisappear { DownloadsAudit.endBrowsing() }
    }
}

/// A debug tripwire for the "no network while browsing downloads" rule.
///
/// In debug builds the app's Jellyfin and artwork sessions route through
/// ``DownloadsAuditProtocol``, which forwards requests untouched but notes one
/// in the console whenever it fires while a downloads screen is on screen — the
/// store's own guarantee is tested, this catches the view layer by hand.
/// Release builds register nothing and pay nothing.
///
/// The screen count below is the tripwire's only state: the environment value
/// drives the views, this count drives the protocol, and there is no second
/// copy to drift. It is a count rather than a flag because a pushed
/// downloaded-detail screen and the section behind it are both browsing, and
/// the section must stay armed until the last of them goes. It is lock-guarded
/// rather than main-actor isolated because `URLProtocol` reads it on the
/// session's own threads.
enum DownloadsAudit {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "net.aseriesoftubes.JellyJams",
        category: "DownloadsAudit"
    )

    private static let counter = ScreenCounter()

    static func beginBrowsing() { counter.begin() }

    static func endBrowsing() { counter.end() }

    /// Whether a request should be reported: only in debug, and only while a
    /// downloads screen is up.
    static var shouldReport: Bool {
        #if DEBUG
        counter.isBrowsing
        #else
        false
        #endif
    }

    static func report(_ request: URLRequest) {
        #if DEBUG
        let path = request.url.map { "\(request.httpMethod ?? "GET") \($0.path)" } ?? "unknown"
        log.notice("""
            Request issued while a Downloads screen was on screen: \(path, privacy: .public). \
            Browsing downloads should be silent; the always-visible player surfaces \
            (Now Playing bar, queue) are the expected exception.
            """)
        #endif
    }

    private final class ScreenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var screens = 0

        func begin() {
            lock.lock()
            screens += 1
            lock.unlock()
        }

        func end() {
            lock.lock()
            screens = max(0, screens - 1)
            lock.unlock()
        }

        var isBrowsing: Bool {
            lock.lock()
            defer { lock.unlock() }
            return screens > 0
        }
    }
}

#if DEBUG
/// Forwards every request while reporting any issued during downloads browsing.
///
/// `canInit` answers false whenever the audit is idle, so outside a downloads
/// screen the protocol steps aside and the session loads normally. Registered
/// only in debug builds — see ``JellyfinService`` and ``ArtworkLoader``.
final class DownloadsAuditProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        DownloadsAudit.shouldReport
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        DownloadsAudit.report(request)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        task.resume()
    }

    override func stopLoading() {}
}
#endif
