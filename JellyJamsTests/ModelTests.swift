import Foundation
import JellyfinAPI
import XCTest
@testable import JellyJams

/// The display-facing derivations on `BaseItemDto`. Every one of these feeds a
/// label the user actually reads, and all have to cope with a server that
/// omits fields.
final class ItemPresentationTests: XCTestCase {
    func testDisplayNameFallsBackWhenTheServerOmitsAName() {
        XCTAssertEqual(BaseItemDto(id: "x", name: "Song").displayName, "Song")
        XCTAssertEqual(BaseItemDto(id: "x", name: nil).displayName, "Unknown")
        XCTAssertEqual(BaseItemDto(id: "x", name: "").displayName, "Unknown")
    }

    func testSubtitleArtistPrefersTheTrackArtistsThenFallsBackToTheAlbumArtist() {
        XCTAssertEqual(
            BaseItemDto(albumArtist: "Album Artist", artists: ["A", "B"]).subtitleArtist,
              "A, B"
        )
        XCTAssertEqual(
            BaseItemDto(albumArtist: nil, artists: ["A", "B"]).subtitleArtist,
              "A, B"
        )
        XCTAssertEqual(
            BaseItemDto(albumArtist: "Album Artist", artists: []).subtitleArtist,
              "Album Artist"
        )
        XCTAssertNil(BaseItemDto(albumArtist: "", artists: []).subtitleArtist)
        XCTAssertNil(BaseItemDto().subtitleArtist)
    }

    /// A multi-artist song yields one navigation stub per artist, in server
    /// order, so the context menu can offer a button for each; artists
    /// without an id to route on are dropped and repeats of an id collapse.
    /// An album navigates on its album artists, like ``artistNavigationItem``.
    func testArtistNavigationItemsOfferOneEntryPerArtist() {
        let track = BaseItemDto(
            artistItems: [
                NameIDPair(id: "a2", name: "Second"),
                NameIDPair(id: nil, name: "Nameless"),
                NameIDPair(id: "a1", name: "First"),
                NameIDPair(id: "a1", name: "First Again"),
            ],
            id: "t",
            type: .audio
        )

        let items = track.artistNavigationItems
        XCTAssertEqual(items.map(\.id), ["a2", "a1"])
        XCTAssertEqual(items.map(\.displayName), ["Second", "First"])
        XCTAssertTrue(items.allSatisfy { $0.type == .musicArtist })

        let album = BaseItemDto(
            albumArtists: [NameIDPair(id: "ab1", name: "Album Artist")],
            artistItems: [NameIDPair(id: "ta1", name: "Track Artist")],
            id: "al",
            type: .musicAlbum
        )
        XCTAssertEqual(album.artistNavigationItems.map(\.id), ["ab1"])

        XCTAssertEqual(BaseItemDto(id: "x").artistNavigationItems, [])
    }

    /// The key puts the album artist first, then the album, then the disc and
    /// track numbers — zero-padded, so the string order is the numeric order.
    func testAlbumArtistSortComposesTheWholeKey() {
        let item = BaseItemDto(
            album: "Album",
            albumArtist: "Artist",
            id: "t",
            indexNumber: 10,
            name: "Song",
            parentIndexNumber: 2,
            type: .audio
        )

        XCTAssertEqual(item.albumArtistSort, "Artist - Album - 002 - 010")
    }

    /// A track without the album artist falls back to its first artist, the
    /// way the downloaded-artist grouping does; missing numbers sink as 999.
    func testAlbumArtistSortFallsBackAndSinksMissingNumbers() {
        let item = BaseItemDto(
            album: "Album",
            artists: ["A", "B"],
            id: "t",
            name: "Song",
            type: .audio
        )

        XCTAssertEqual(item.albumArtistSort, "A - Album - 999 - 999")
    }

    func testRuntimeConvertsTicksAndToleratesAbsentDurations() throws {
        let threeMinutes = BaseItemDto(runTimeTicks: 180 * Ticks.perSecond)

        XCTAssertEqual(try XCTUnwrap(threeMinutes.runtimeSeconds), 180, accuracy: 0.0001)
        XCTAssertEqual(threeMinutes.runtime, .seconds(180))
        XCTAssertNil(BaseItemDto().runtimeSeconds)
        XCTAssertNil(BaseItemDto().runtime)
    }

    func testIsFavoriteDefaultsToFalseWithoutUserData() {
        XCTAssertTrue(BaseItemDto(userData: UserItemDataDto(isFavorite: true, key: "k")).isFavorite)
        XCTAssertFalse(BaseItemDto(userData: UserItemDataDto(isFavorite: false, key: "k")).isFavorite)
        XCTAssertFalse(BaseItemDto(userData: UserItemDataDto(key: "k")).isFavorite)
        XCTAssertFalse(BaseItemDto().isFavorite)
    }

    func testPrimaryImageTagIsReadFromTheImageTagMap() {
        let tagged = BaseItemDto(imageTags: ["Primary": "abc123", "Backdrop": "zzz"])

        XCTAssertEqual(tagged.primaryImageTag, "abc123")
        XCTAssertNil(BaseItemDto(imageTags: ["Backdrop": "zzz"]).primaryImageTag)
        XCTAssertNil(BaseItemDto().primaryImageTag)
    }

    func testMediaSourceIDUsesTheFirstSource() {
        let item = BaseItemDto(mediaSources: [
            MediaSourceInfo(id: "source-1"),
            MediaSourceInfo(id: "source-2"),
        ])

        XCTAssertEqual(item.mediaSourceID, "source-1")
        XCTAssertNil(BaseItemDto().mediaSourceID)
    }
}

/// Tick maths. Jellyfin reports positions in ticks, so a rounding or overflow
/// mistake here becomes a wrong scrubber and bad resume points.
final class TickConversionTests: XCTestCase {
    func testTickConversionHandlesUntrustedNumericExtremes() {
        XCTAssertEqual(Ticks.ticks(fromSeconds: .nan), 0)
        XCTAssertEqual(Ticks.ticks(fromSeconds: .infinity), 0)
        XCTAssertEqual(Ticks.ticks(fromSeconds: .greatestFiniteMagnitude), .max)
        XCTAssertEqual(Ticks.ticks(fromSeconds: -.greatestFiniteMagnitude), .min)
    }

    func testSecondsFromTicksRoundTripsAndPropagatesNil() throws {
        XCTAssertEqual(try XCTUnwrap(Ticks.seconds(fromTicks: Ticks.perSecond)), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(Ticks.seconds(fromTicks: 0)), 0, accuracy: 0.0001)
        XCTAssertNil(Ticks.seconds(fromTicks: nil))
    }

    func testTicksFromSecondsRoundsToTheNearestTick() {
        XCTAssertEqual(Ticks.ticks(fromSeconds: 1), Ticks.perSecond)
        XCTAssertEqual(Ticks.ticks(fromSeconds: 0), 0)
        XCTAssertEqual(Ticks.ticks(fromSeconds: 1.5), 15_000_000)
    }

    func testARoundTripThroughTicksPreservesAPlaybackPosition() throws {
        let position = 137.5
        let recovered = try XCTUnwrap(Ticks.seconds(fromTicks: Ticks.ticks(fromSeconds: position)))

        XCTAssertEqual(recovered, position, accuracy: 0.0001)
    }
}

/// Duration and count strings shown in headers and track rows.
final class FormatTests: XCTestCase {
    func testDurationUsesMinutesAndSecondsBelowAnHour() {
        XCTAssertEqual(Format.duration(0), "0:00")
        XCTAssertEqual(Format.duration(5), "0:05")
        XCTAssertEqual(Format.duration(65), "1:05")
        XCTAssertEqual(Format.duration(599), "9:59")
    }

    func testDurationAddsAnHoursComponentWhenNeeded() {
        XCTAssertEqual(Format.duration(3600), "1:00:00")
        XCTAssertEqual(Format.duration(3661), "1:01:01")
        XCTAssertEqual(Format.duration(45296), "12:34:56")
    }

    /// `--:--` is the "we don't know yet" state: an unloaded track, or a stream
    /// with no duration. It must never render as `0:00` or crash.
    func testDurationShowsAPlaceholderForUnknownOrInvalidValues() {
        XCTAssertEqual(Format.duration(nil), "--:--")
        XCTAssertEqual(Format.duration(.nan), "--:--")
        XCTAssertEqual(Format.duration(.infinity), "--:--")
        XCTAssertEqual(Format.duration(-1), "--:--")
    }

    func testCountsArePluralisedAndTreatNilAsZero() {
        XCTAssertEqual(Format.songCount(0), "0 songs")
        XCTAssertEqual(Format.songCount(1), "1 song")
        XCTAssertEqual(Format.songCount(2), "2 songs")
        XCTAssertEqual(Format.songCount(nil), "0 songs")

        XCTAssertEqual(Format.albumCount(1), "1 album")
        XCTAssertEqual(Format.albumCount(3), "3 albums")
        XCTAssertEqual(Format.albumCount(nil), "0 albums")

        XCTAssertEqual(Format.playlistCount(1), "1 playlist")
        XCTAssertEqual(Format.playlistCount(3), "3 playlists")
        XCTAssertEqual(Format.playlistCount(nil), "0 playlists")

        XCTAssertEqual(Format.artistCount(1), "1 artist")
        XCTAssertEqual(Format.artistCount(3), "3 artists")
        XCTAssertEqual(Format.artistCount(nil), "0 artists")
    }

    /// Space totals are the system's own file-size formatting — the same
    /// spelling the download speed already used. The expectations are built
    /// with the formatter itself, because both the decimal separator and the
    /// unit symbols are locale-dependent.
    func testByteCountsFormatAsSystemFileSizes() {
        func system(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        XCTAssertEqual(Format.byteCount(0), system(0))
        XCTAssertEqual(Format.byteCount(750), system(750))
        XCTAssertEqual(Format.byteCount(150_000_000), system(150_000_000))
        XCTAssertEqual(Format.byteCount(1_500_000_000), system(1_500_000_000))
    }
}

/// Sort options are sent to the server as ordered field lists; a mismatch
/// between the raw value and the SDK values silently sorts the wrong way.
final class SortByTests: XCTestCase {
    func testEverySortOptionMapsToANonEmptySDKFieldList() {
        for option in SortBy.allCases {
            XCTAssertFalse(option.sdkValues.isEmpty, "\(option) has no SDK sort fields")
            XCTAssertFalse(option.displayName.isEmpty, "\(option) has no display name")
        }
    }

    /// The raw value is the comma-joined form of the SDK fields; the SDK
    /// values are what reach Jellyfin, so the two have to agree for the raw
    /// value to keep describing the request.
    func testRawValuesMatchTheSDKFieldOrder() {
        for option in SortBy.allCases {
            XCTAssertEqual(
                option.rawValue,
                option.sdkValues.map(\.rawValue).joined(separator: ","),
                "\(option) raw value disagrees with its SDK fields"
            )
        }
    }

    func testSortOrderTogglesBothWays() {
        XCTAssertEqual(SortOrder.ascending.toggled, .descending)
        XCTAssertEqual(SortOrder.descending.toggled, .ascending)
    }
}

/// The local track sort the Downloads songs list applies. It has to order
/// the way the server orders the same fields — the same menu choice must
/// mean the same thing online and offline — and stay a real ordering even
/// when tracks are missing the field.
final class LocalSortTests: XCTestCase {
    private func track(
        _ name: String,
        album: String? = nil,
        albumArtist: String? = nil,
        artist: String? = nil,
        disc: Int? = nil,
        index: Int? = nil,
        played: Date? = nil,
        runtime: Int? = nil
    ) -> BaseItemDto {
        BaseItemDto(
            album: album,
            albumArtist: albumArtist,
            artists: artist.map { [$0] },
            id: name,
            indexNumber: index,
            name: name,
            parentIndexNumber: disc,
            runTimeTicks: runtime,
            sortName: name,
            type: .audio,
            userData: played.map { UserItemDataDto(key: "k", lastPlayedDate: $0) }
        )
    }

    func testNameSortsBothWays() {
        let tracks = [track("Beta"), track("Alpha"), track("Gamma")]

        XCTAssertEqual(tracks.sorted(by: .sortName, order: .ascending).map(\.displayName), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(tracks.sorted(by: .sortName, order: .descending).map(\.displayName), ["Gamma", "Beta", "Alpha"])
    }

    /// Every server-side sort breaks ties on SortName; the local one must too.
    func testEqualFieldsFallBackToTheName() {
        let tracks = [track("Zeta", artist: "A"), track("Alpha", artist: "A"), track("Mid", artist: "B")]

        XCTAssertEqual(tracks.sorted(by: .artist, order: .ascending).map(\.displayName), ["Alpha", "Zeta", "Mid"])
    }

    /// A missing field must not decide the order by which side it landed on:
    /// the pair has to flip cleanly when the direction flips.
    func testAMissingFieldKeepsItsPlaceInBothDirections() {
        let missing = track("Beta")
        let present = track("Alpha", artist: "Zed")

        XCTAssertEqual([missing, present].sorted(by: .artist, order: .ascending).map(\.displayName), ["Beta", "Alpha"])
        XCTAssertEqual([missing, present].sorted(by: .artist, order: .descending).map(\.displayName), ["Alpha", "Beta"])
    }

    /// Never played is the extreme of not-recently-played: first in an
    /// ascending order, last in a descending one.
    func testDatePlayedCountsTheUnplayedAsTheOldest() {
        let older = track("Older", played: Date(timeIntervalSince1970: 100))
        let newer = track("Newer", played: Date(timeIntervalSince1970: 200))
        let never = track("Never")

        XCTAssertEqual(
            [never, newer, older].sorted(by: .datePlayed, order: .ascending).map(\.displayName),
            ["Never", "Older", "Newer"]
        )
        XCTAssertEqual(
            [never, newer, older].sorted(by: .datePlayed, order: .descending).map(\.displayName),
            ["Newer", "Older", "Never"]
        )
    }

    func testRuntimeComparesTicks() {
        let short = track("Short", runtime: Ticks.perSecond * 60)
        let long = track("Long", runtime: Ticks.perSecond * 300)

        XCTAssertEqual([long, short].sorted(by: .runtime, order: .ascending).map(\.displayName), ["Short", "Long"])
    }

    /// The downloads-only album-artist ordering: one artist's albums stay
    /// whole — album by album, in track order — and numbers compare
    /// numerically, so track 10 sorts after track 2.
    func testAlbumArtistTrackOrderKeepsAlbumsWholeAndSortsNumbersNumerically() {
        let tracks = [
            track("Track Ten", album: "Album A", albumArtist: "Artist", disc: 1, index: 10),
            track("Track Two", album: "Album A", albumArtist: "Artist", disc: 1, index: 2),
            track("Disc Two Opener", album: "Album A", albumArtist: "Artist", disc: 2, index: 1),
            track("Album B Opener", album: "Album B", albumArtist: "Artist", disc: 1, index: 1),
            track("Other Artist Song", album: "Album C", albumArtist: "Bee", disc: 1, index: 1),
        ]

        XCTAssertEqual(
            tracks.sorted(by: .albumArtistTrackOrder, order: .ascending).map(\.displayName),
            ["Track Two", "Track Ten", "Disc Two Opener", "Album B Opener", "Other Artist Song"]
        )
        XCTAssertEqual(
            tracks.sorted(by: .albumArtistTrackOrder, order: .descending).map(\.displayName),
            ["Other Artist Song", "Album B Opener", "Disc Two Opener", "Track Ten", "Track Two"]
        )
    }

    func testRandomKeepsTheSameOrderAcrossSorts() {
        let tracks = (0..<20).map { track("Song \($0)") }
        let once = tracks.sorted(by: .random, order: .ascending)
        let twice = tracks.sorted(by: .random, order: .ascending)

        XCTAssertEqual(once.map(\.displayName), twice.map(\.displayName))
        XCTAssertEqual(Set(once.compactMap(\.id)), Set(tracks.compactMap(\.id)))
    }

    // MARK: - Downloaded groups

    /// A derived group standing in for a downloaded album, carrying only the
    /// fields the Downloads grids' sort menus read.
    private func group(
        _ title: String,
        artist: String? = nil,
        added: Date? = nil,
        year: Int? = nil,
        recency: Int = 0
    ) -> DownloadStore.DownloadGroup {
        DownloadStore.DownloadGroup(
            id: title,
            kind: .album,
            title: title,
            item: BaseItemDto(
                albumArtist: artist,
                dateCreated: added,
                id: title,
                name: title,
                productionYear: year,
                type: .musicAlbum
            ),
            downloadedSongs: 1,
            totalSongs: nil,
            isExplicit: true,
            artworkKeys: [],
            artistKeys: [],
            mostRecentOrder: recency
        )
    }

    /// The albums grid offers the online list's fields; the derived album
    /// sorts by the ones its stand-in carries, with the same name tiebreak.
    func testGroupsSortByTheStandInItemsFields() {
        let groups = [
            group("Zeta", artist: "A"),
            group("Alpha", artist: "B"),
            group("Mid", artist: "A"),
        ]

        XCTAssertEqual(groups.sorted(by: .albumArtist, order: .ascending).map(\.title), ["Mid", "Zeta", "Alpha"])
        XCTAssertEqual(groups.sorted(by: .albumArtist, order: .descending).map(\.title), ["Alpha", "Zeta", "Mid"])
    }

    func testGroupsSortByDateAddedAndYear() {
        let older = group("Old", added: Date(timeIntervalSince1970: 100), year: 1990)
        let newer = group("New", added: Date(timeIntervalSince1970: 200), year: 2000)
        let undated = group("Undated")

        XCTAssertEqual(
            [newer, undated, older].sorted(by: .dateCreated, order: .ascending).map(\.title),
            ["Undated", "Old", "New"]
        )
        XCTAssertEqual(
            [newer, older].sorted(by: .productionYear, order: .descending).map(\.title),
            ["New", "Old"]
        )
    }

    /// A field the stand-in lacks must not decide the order by which side it
    /// landed on: the pair has to flip cleanly when the direction flips.
    func testGroupsWithoutTheFieldFallBackToTheName() {
        let missing = group("Beta")
        let present = group("Alpha", artist: "Zed")

        XCTAssertEqual([missing, present].sorted(by: .albumArtist, order: .ascending).map(\.title), ["Beta", "Alpha"])
        XCTAssertEqual([missing, present].sorted(by: .albumArtist, order: .descending).map(\.title), ["Alpha", "Beta"])
    }

    /// Recently Downloaded: newest arrival first, and groups that share a
    /// newest song (two artists off one compilation, say) keep name order.
    func testMostRecentFirstOrdersByNewestSongThenName() {
        let early = group("A", recency: 3)
        let late = group("B", recency: 9)
        let earlyToo = group("C", recency: 3)

        XCTAssertEqual([late, early, earlyToo].mostRecentFirst().map(\.title), ["B", "A", "C"])
    }

    func testRandomGroupOrderIsStableAcrossSorts() {
        let groups = (0..<20).map { group("Album \($0)") }
        let once = groups.sorted(by: .random, order: .ascending)
        let twice = groups.sorted(by: .random, order: .ascending)

        XCTAssertEqual(once.map(\.title), twice.map(\.title))
        XCTAssertEqual(Set(once.map(\.title)), Set(groups.map(\.title)))
    }
}

/// Cancellation is routine (a `.task(id:)` re-running, a search term changing)
/// and must never reach the user as an error.
final class ErrorClassificationTests: XCTestCase {
    func testURLSessionAndTaskCancellationAreBothRecognised() {
        XCTAssertTrue(URLError(.cancelled).isCancellation)
        XCTAssertTrue(CancellationError().isCancellation)
    }

    func testRealFailuresAreNotMistakenForCancellation() {
        XCTAssertFalse(URLError(.timedOut).isCancellation)
        XCTAssertFalse(URLError(.notConnectedToInternet).isCancellation)
        XCTAssertFalse(JellyfinError.notAuthenticated.isCancellation)
        XCTAssertFalse(NSError(domain: "test", code: 1).isCancellation)
    }

    func testEveryJellyfinErrorHasAUserFacingMessage() {
        let errors: [JellyfinError] = [
            .invalidServerURL,
            .notAuthenticated,
            .incompleteAuthenticationResponse,
            .missingItemIdentifier,
            .invalidMediaURL,
            .emptyPlaylistName,
            .emptyCollection("Greatest Hits"),
        ]

        for error in errors {
            XCTAssertFalse(error.userFacingMessage.isEmpty, "\(error) has no message")
            XCTAssertNotEqual(
                error.userFacingMessage,
                "\(error)",
                "\(error) is falling back to its debug description"
            )
        }
    }

    func testEmptyCollectionNamesTheCollection() {
        XCTAssertTrue(
            JellyfinError.emptyCollection("Greatest Hits").userFacingMessage.contains("Greatest Hits")
        )
    }
}
