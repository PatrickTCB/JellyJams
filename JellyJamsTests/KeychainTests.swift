import XCTest
@testable import JellyJams

final class KeychainTests: XCTestCase {
    func testTokenRoundTripUpdateAndDelete() throws {
        let account = "JellyJamsTests.\(UUID().uuidString)"
        defer { try? Keychain.delete(account: account) }

        try Keychain.set("first-token", account: account)
        XCTAssertEqual(try Keychain.get(account: account), "first-token")

        try Keychain.set("replacement-token", account: account)
        XCTAssertEqual(try Keychain.get(account: account), "replacement-token")

        try Keychain.delete(account: account)
        XCTAssertNil(try Keychain.get(account: account))
    }
}
