import XCTest
@testable import JellyJams

/// The list metadata that drives paging, sort menus and cache identity.
final class LibraryListTests: XCTestCase {
    func testFavouriteListsShareTheContentOfTheirBrowseCounterpart() {
        XCTAssertEqual(LibraryList.favouriteSongs.content, LibraryList.songs.content)
        XCTAssertEqual(LibraryList.favouriteAlbums.content, LibraryList.albums.content)
        XCTAssertEqual(LibraryList.favouriteArtists.content, LibraryList.artists.content)
    }

    /// AI Radio is the same item type as the playlist list — the two are split
    /// by name, not by what they ask the server for.
    func testAIRadioListHoldsPlaylists() {
        XCTAssertEqual(LibraryList.aiRadioPlaylists.content, LibraryList.playlists.content)
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
        XCTAssertEqual(LibraryList.aiRadioPlaylists.pageSize, 300)
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
        XCTAssertEqual(LibraryList.aiRadioPlaylists.defaultSortBy, .sortName)
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

    /// Turning AI Radio on, or editing the ending it matches, has to re-key the
    /// query — that is the only thing telling a playlist list to refetch.
    func testQueriesDifferByNameFilter() {
        let base = LibraryQuery(list: .playlists)

        XCTAssertEqual(base.nameFilter, nil)
        XCTAssertNotEqual(base, LibraryQuery(list: .playlists, nameFilter: .notEndsWith("_automatic")))
        XCTAssertNotEqual(
            LibraryQuery(list: .playlists, nameFilter: .notEndsWith("_automatic")),
            LibraryQuery(list: .playlists, nameFilter: .notEndsWith("_ai"))
        )
        XCTAssertNotEqual(
            LibraryQuery(list: .playlists, nameFilter: .notEndsWith("_automatic")),
            LibraryQuery(list: .playlists, nameFilter: .endsWith("_automatic"))
        )
    }
}

/// The rule that splits AudioMuse-AI's generated playlists out of the library.
/// Getting it wrong either hides playlists the user made or shows stations that
/// aren't there, and neither is visible from the screen that broke.
final class PlaylistNameFilterTests: XCTestCase {
    func testEndsWithKeepsOnlyNamesCarryingTheEnding() {
        let filter = PlaylistNameFilter.endsWith("_automatic")

        XCTAssertTrue(filter.matches("Chill_automatic"))
        XCTAssertTrue(filter.matches("_automatic"))
        XCTAssertFalse(filter.matches("Road Trip"))
        XCTAssertFalse(filter.matches(""))
    }

    /// The ending is the generator's convention rather than something the user
    /// typed to match it, so case must not decide what counts as a station.
    func testTheEndingIsMatchedWithoutRegardToCase() {
        let filter = PlaylistNameFilter.endsWith("_automatic")

        XCTAssertTrue(filter.matches("Chill_AUTOMATIC"))
        XCTAssertTrue(filter.matches("Chill_Automatic"))
        XCTAssertTrue(PlaylistNameFilter.endsWith("_AUTOMATIC").matches("Chill_automatic"))
    }

    /// A name that merely contains the ending is a playlist the user made —
    /// AudioMuse-AI appends it, so only a name ending in it is a station.
    func testTheEndingMustActuallyEndTheName() {
        let filter = PlaylistNameFilter.endsWith("_automatic")

        XCTAssertFalse(filter.matches("_automatic_mixes"))
        XCTAssertFalse(filter.matches("my _automatic thing"))
    }

    /// The ordinary playlist list is the same rule inverted: between them the
    /// two lists must account for every playlist exactly once.
    func testNotEndsWithIsTheInverseOfEndsWith() {
        let names = ["Chill_automatic", "Road Trip", "Focus_AUTOMATIC", "_automatic", ""]

        for name in names {
            XCTAssertNotEqual(
                PlaylistNameFilter.endsWith("_automatic").matches(name),
                PlaylistNameFilter.notEndsWith("_automatic").matches(name),
                name
            )
        }
    }

    func testNotEndsWithKeepsTheNamesWithoutTheEnding() {
        let filter = PlaylistNameFilter.notEndsWith("_automatic")

        XCTAssertTrue(filter.matches("Road Trip"))
        XCTAssertFalse(filter.matches("Chill_automatic"))
    }

    /// The ending identified the playlist as a station; on the station's own
    /// screen it is noise repeated on every tile.
    func testTrimmingTakesTheEndingOffAStationName() {
        let filter = PlaylistNameFilter.endsWith("_automatic")

        XCTAssertEqual(filter.trimmingMatchedEnding(from: "Chill_automatic"), "Chill")
        XCTAssertEqual(filter.trimmingMatchedEnding(from: "Chill_AUTOMATIC"), "Chill")
        XCTAssertEqual(filter.trimmingMatchedEnding(from: "Focus_ai_automatic"), "Focus_ai")
        XCTAssertEqual(PlaylistNameFilter.endsWith("_ai").trimmingMatchedEnding(from: "Focus_ai"), "Focus")
    }

    /// Trimming must not rename anything it didn't recognise, or the ordinary
    /// playlists would lose part of their names too.
    func testTrimmingLeavesNamesWithoutTheEndingAlone() {
        let filter = PlaylistNameFilter.endsWith("_automatic")

        XCTAssertEqual(filter.trimmingMatchedEnding(from: "Road Trip"), "Road Trip")
        XCTAssertEqual(filter.trimmingMatchedEnding(from: "_automatic_mixes"), "_automatic_mixes")
    }

    /// A playlist named after the ending and nothing else has no other name to
    /// go by, so it keeps the whole thing rather than showing an empty tile.
    func testTrimmingKeepsANameThatIsOnlyTheEnding() {
        let filter = PlaylistNameFilter.endsWith("_automatic")

        XCTAssertEqual(filter.trimmingMatchedEnding(from: "_automatic"), "_automatic")
        XCTAssertEqual(filter.trimmingMatchedEnding(from: "  _automatic"), "  _automatic")
    }

    /// The ending is appended to whatever the generator called the station, so
    /// a space before it belongs to the name's spacing rather than to it.
    func testTrimmingTakesTheWhitespaceLeftBehindWithTheEnding() {
        XCTAssertEqual(
            PlaylistNameFilter.endsWith("_automatic").trimmingMatchedEnding(from: "Chill _automatic"),
            "Chill"
        )
    }
}
