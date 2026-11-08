import XCTest
@testable import JellyJams

@MainActor
final class SessionStoreTests: XCTestCase {
    func testNormalizesCommonServerAddresses() throws {
        XCTAssertEqual(
            try SessionStore.normalizeServerURL(" jellyfin.example.com:8096/web/ ").absoluteString,
            "http://jellyfin.example.com:8096"
        )
        XCTAssertEqual(
            try SessionStore.normalizeServerURL("HTTPS://example.com/jellyfin/web///").absoluteString,
            "https://example.com/jellyfin"
        )
    }

    func testRejectsUnsupportedOrAmbiguousServerAddresses() {
        for address in [
            "",
            "ftp://example.com",
            "https://user:password@example.com",
            "https://example.com?token=secret",
            "https://example.com/#fragment",
        ] {
            XCTAssertThrowsError(try SessionStore.normalizeServerURL(address), address)
        }
    }

    /// The sign-out reset takes the device identity too: a new id is
    /// generated and persisted, so the next sign-in appears on the server as
    /// a brand-new device — what a fresh install would present.
    func testRegeneratingTheDeviceIdentityTakesANewOneAndPersistsIt() {
        let key = DeviceInfo.deviceIdDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = SessionStore()
        let old = store.deviceInfo.deviceId

        store.regenerateDeviceIdentity()

        XCTAssertNotEqual(store.deviceInfo.deviceId, old)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), store.deviceInfo.deviceId)
    }
}
