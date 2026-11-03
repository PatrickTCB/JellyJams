#if os(macOS)
import XCTest
@testable import JellyJams

/// The macOS in-app volume: clamped to 0...1 and remembered across launches.
@MainActor
final class PlayerVolumeTests: XCTestCase {
    private let volumeKey = "jellyjams.volume"
    private var savedVolume: Any?

    override func setUp() async throws {
        savedVolume = UserDefaults.standard.object(forKey: volumeKey)
        UserDefaults.standard.removeObject(forKey: volumeKey)
    }

    override func tearDown() async throws {
        if let savedVolume {
            UserDefaults.standard.set(savedVolume, forKey: volumeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: volumeKey)
        }
    }

    func testVolumeDefaultsToFull() {
        XCTAssertEqual(PlayerController().volume, 1)
    }

    func testVolumeIsClampedToTheValidRange() {
        let player = PlayerController()

        player.volume = 1.5
        XCTAssertEqual(player.volume, 1)

        player.volume = -0.5
        XCTAssertEqual(player.volume, 0)
    }

    func testVolumeIsRememberedByTheNextController() {
        PlayerController().volume = 0.4

        XCTAssertEqual(PlayerController().volume, 0.4, accuracy: 0.0001)
    }

    /// The sign-out reset takes the remembered volume too: a fresh install
    /// starts at full, so a signed-out app reads the same.
    func testForgettingEverythingReturnsTheVolumeToTheDefault() {
        let player = PlayerController()
        player.volume = 0.4

        player.forgetEverything()

        XCTAssertEqual(player.volume, 1)
        XCTAssertEqual(PlayerController().volume, 1, "The next launch reads the default too")
    }
}
#endif
