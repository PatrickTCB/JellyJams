import XCTest
@testable import JellyJams

@MainActor
final class LibraryCacheTests: XCTestCase {
    func testVendsAStableInstancePerList() {
        let cache = LibraryCache()

        XCTAssertTrue(cache.items(for: .albums) === cache.items(for: .albums))
        XCTAssertFalse(cache.items(for: .albums) === cache.items(for: .artists))
    }

    /// Favourites and browse lists show the same item types but are separate
    /// lists, so they must not share a model.
    func testFavouriteListsAreCachedSeparatelyFromBrowseLists() {
        let cache = LibraryCache()

        XCTAssertFalse(cache.items(for: .albums) === cache.items(for: .favouriteAlbums))
        XCTAssertFalse(cache.items(for: .songs) === cache.items(for: .favouriteSongs))
        XCTAssertFalse(cache.items(for: .artists) === cache.items(for: .favouriteArtists))
    }

    func testEveryListGetsItsOwnModel() {
        let cache = LibraryCache()
        let models = LibraryList.allCases.map { ObjectIdentifier(cache.items(for: $0)) }

        XCTAssertEqual(Set(models).count, LibraryList.allCases.count)
    }

    func testCachedModelIsConfiguredForItsList() {
        let cache = LibraryCache()
        let songs = cache.items(for: .favouriteSongs)

        XCTAssertEqual(songs.list, .favouriteSongs)
        XCTAssertEqual(songs.sortBy, LibraryList.favouriteSongs.defaultSortBy)
    }

    /// Sort is part of the retained state, so returning to a list must not
    /// reset the user's choice.
    func testSortSelectionSurvivesRevisitingAList() {
        let cache = LibraryCache()
        cache.items(for: .albums).sortBy = .dateCreated

        XCTAssertEqual(cache.items(for: .albums).sortBy, .dateCreated)
    }

    func testClearDiscardsCachedLists() {
        let cache = LibraryCache()
        let before = cache.items(for: .songs)
        before.sortBy = .runtime

        cache.clear()

        let after = cache.items(for: .songs)
        XCTAssertFalse(after === before)
        XCTAssertEqual(after.sortBy, LibraryList.songs.defaultSortBy, "A new account must not inherit the previous sort")
    }
}
