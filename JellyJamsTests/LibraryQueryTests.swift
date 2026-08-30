import XCTest
@testable import JellyJams

/// The list metadata that drives paging, sort menus and cache identity.
final class LibraryListTests: XCTestCase {
    func testFavouriteListsShareTheContentOfTheirBrowseCounterpart() {
        XCTAssertEqual(LibraryList.favouriteSongs.content, LibraryList.songs.content)
        XCTAssertEqual(LibraryList.favouriteAlbums.content, LibraryList.albums.content)
        XCTAssertEqual(LibraryList.favouriteArtists.content, LibraryList.artists.content)
    }

    func testOnlyFavouriteListsCarryAFilter() {
        for list in LibraryList.allCases {
            let isFavouriteList = list.rawValue.hasPrefix("favourite")
            XCTAssertEqual(list.filters == nil, !isFavouriteList, "\(list)")
        }
        XCTAssertEqual(LibraryList.favouriteAlbums.filters, [.isFavorite])
    }

    func testTrackListsPageInSmallerBatchesThanArtworkGrids() {
        XCTAssertEqual(LibraryList.songs.pageSize, 200)
        XCTAssertEqual(LibraryList.favouriteSongs.pageSize, 200)
        XCTAssertEqual(LibraryList.albums.pageSize, 300)
        XCTAssertEqual(LibraryList.artists.pageSize, 300)
        XCTAssertEqual(LibraryList.playlists.pageSize, 300)
    }

    /// A sort menu that offered a field the list can't be sorted by would send
    /// a query the server rejects, so every option must be a real sort field.
    func testEveryOfferedSortOptionIsSelectableAndUnique() {
        for list in LibraryList.allCases {
            let options = list.sortOptions
            XCTAssertEqual(Set(options).count, options.count, "\(list) offers a duplicate sort")
            XCTAssertFalse(options.contains(.discAndTrack), "\(list) offers the internal track order")
        }
    }

    /// Lists that show a sort menu must default to one of its entries,
    /// otherwise the menu opens with nothing selected.
    func testListsWithASortMenuDefaultToOneOfItsOptions() {
        for list in LibraryList.allCases where !list.sortOptions.isEmpty {
            XCTAssertTrue(
                list.sortOptions.contains(list.defaultSortBy),
                "\(list) defaults to \(list.defaultSortBy), which its menu doesn't offer"
            )
        }
    }

    func testAlbumListsDefaultToAlbumArtistAndTheRestToName() {
        XCTAssertEqual(LibraryList.albums.defaultSortBy, .albumArtist)
        XCTAssertEqual(LibraryList.favouriteAlbums.defaultSortBy, .albumArtist)
        XCTAssertEqual(LibraryList.songs.defaultSortBy, .artist)
        XCTAssertEqual(LibraryList.artists.defaultSortBy, .sortName)
        XCTAssertEqual(LibraryList.playlists.defaultSortBy, .sortName)
    }
}

final class LibraryQueryTests: XCTestCase {
    func testQueryAdoptsTheListsDefaultsWhenNoSortIsGiven() {
        let query = LibraryQuery(list: .albums)

        XCTAssertEqual(query.sortBy, LibraryList.albums.defaultSortBy)
        XCTAssertEqual(query.sortOrder, .ascending)
    }

    func testExplicitSortOverridesTheDefault() {
        let query = LibraryQuery(list: .albums, sortBy: .random, sortOrder: .descending)

        XCTAssertEqual(query.sortBy, .random)
        XCTAssertEqual(query.sortOrder, .descending)
    }

    /// The query is the cache key: two lists, two sorts and two orders must all
    /// be distinguishable, or a screen will keep showing stale items.
    func testQueriesDifferByListSortFieldAndOrder() {
        let base = LibraryQuery(list: .albums, sortBy: .sortName, sortOrder: .ascending)

        XCTAssertEqual(base, LibraryQuery(list: .albums, sortBy: .sortName, sortOrder: .ascending))
        XCTAssertNotEqual(base, LibraryQuery(list: .favouriteAlbums, sortBy: .sortName, sortOrder: .ascending))
        XCTAssertNotEqual(base, LibraryQuery(list: .albums, sortBy: .dateCreated, sortOrder: .ascending))
        XCTAssertNotEqual(base, LibraryQuery(list: .albums, sortBy: .sortName, sortOrder: .descending))
    }
}
