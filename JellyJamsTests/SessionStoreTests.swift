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
}
