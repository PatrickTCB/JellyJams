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

    func testSubtitleArtistPrefersTheAlbumArtistThenJoinsTrackArtists() {
        XCTAssertEqual(
            BaseItemDto(albumArtist: "Album Artist", artists: ["A", "B"]).subtitleArtist,
            "Album Artist"
        )
        XCTAssertEqual(
            BaseItemDto(albumArtist: nil, artists: ["A", "B"]).subtitleArtist,
            "A, B"
        )
        XCTAssertNil(BaseItemDto(albumArtist: "", artists: []).subtitleArtist)
        XCTAssertNil(BaseItemDto().subtitleArtist)
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

    /// The raw value is the comma-joined form of the SDK fields and both reach
    /// Jellyfin, so they have to agree.
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
