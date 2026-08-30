import XCTest
@testable import JellyJams

/// Covers the persistence of user settings. The default matters as much as the
/// round trip: a preference that reads as off before anyone has touched it
/// ships the feature disabled for every existing install.
@MainActor
final class PreferencesStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// An absent key must mean on, not off. `UserDefaults.bool(forKey:)` returns
    /// false for a key nobody has written, which is the trap this guards.
    func testSimilarItemsAreOnBeforeTheUserHasChosen() {
        XCTAssertTrue(PreferencesStore(defaults: defaults).showsSimilarItems)
    }

    func testTurningSimilarItemsOffSurvivesRelaunch() {
        PreferencesStore(defaults: defaults).showsSimilarItems = false

        XCTAssertFalse(PreferencesStore(defaults: defaults).showsSimilarItems)
    }

    /// Turning it back on must persist too, rather than falling back to the
    /// default and only appearing to work.
    func testTurningSimilarItemsBackOnSurvivesRelaunch() {
        let store = PreferencesStore(defaults: defaults)
        store.showsSimilarItems = false
        store.showsSimilarItems = true

        XCTAssertTrue(PreferencesStore(defaults: defaults).showsSimilarItems)
        XCTAssertEqual(defaults.object(forKey: "showsSimilarItems") as? Bool, true)
    }
}
