import Foundation
import JellyfinAPI
import XCTest
@testable import JellyJams

/// Genre metadata arrives in two shapes and the UI must not care which. These
/// pin the normalisation, because picking the wrong shape silently strips the
/// identifiers that make genre filtering exact.
final class GenreRefTests: XCTestCase {
    func testPairedGenresWinSoFilteringCanUseIdentifiers() {
        let item = BaseItemDto(
            genreItems: [NameIDPair(id: "genre-1", name: "Shoegaze")],
            genres: ["Shoegaze"],
            id: "album-1",
            type: .musicAlbum
        )

        XCTAssertEqual(item.genreRefs, [GenreRef(id: "genre-1", name: "Shoegaze")])
        XCTAssertEqual(item.genreRefs.first?.genreId, "genre-1")
    }

    func testNameOnlyGenresAreUsedWhenNoPairsArrive() {
        let item = BaseItemDto(
            genres: ["Shoegaze", "Dream Pop"],
            id: "album-1",
            type: .musicAlbum
        )

        XCTAssertEqual(item.genreRefs, [GenreRef(name: "Shoegaze"), GenreRef(name: "Dream Pop")])
        XCTAssertNil(item.genreRefs.first?.genreId)
    }

    /// Pairs with no usable name are worthless for both display and filtering,
    /// so the name-only list is still worth falling back to.
    func testPairsWithoutNamesFallBackToTheNameOnlyList() {
        let item = BaseItemDto(
            genreItems: [NameIDPair(id: "genre-1", name: nil), NameIDPair(id: "genre-2", name: "")],
            genres: ["Shoegaze"],
            id: "album-1",
            type: .musicAlbum
        )

        XCTAssertEqual(item.genreRefs, [GenreRef(name: "Shoegaze")])
    }

    func testBlankNamesAreDropped() {
        let item = BaseItemDto(genres: ["", "Shoegaze"], id: "album-1", type: .musicAlbum)

        XCTAssertEqual(item.genreRefs, [GenreRef(name: "Shoegaze")])
    }

    func testRepeatedGenreNamesCollapseIgnoringCase() {
        let item = BaseItemDto(
            genreItems: [
                NameIDPair(id: "genre-1", name: "Shoegaze"),
                NameIDPair(id: "genre-2", name: "shoegaze"),
            ],
            id: "album-1",
            type: .musicAlbum
        )

        XCTAssertEqual(item.genreRefs.map(\.name), ["Shoegaze"], "The first spelling wins")
    }

    func testAnItemWithNoGenresHasNoReferences() {
        XCTAssertTrue(TestFixtures.item(id: "album-1", type: .musicAlbum).genreRefs.isEmpty)
    }

    /// The identity backs `ForEach` and `.task(id:)`, so it has to exist even
    /// for a genre the server described by name alone.
    func testIdentityFallsBackToTheName() {
        XCTAssertEqual(GenreRef(name: "Shoegaze").id, "Shoegaze")
        XCTAssertEqual(GenreRef(id: "genre-1", name: "Shoegaze").id, "genre-1")
    }

    func testBuildingFromAGenreItemRequiresAName() {
        XCTAssertNil(GenreRef(item: BaseItemDto(id: "genre-1", type: .musicGenre)))
        XCTAssertNil(GenreRef(item: BaseItemDto(id: "genre-1", name: "", type: .musicGenre)))

        XCTAssertEqual(
            GenreRef(item: TestFixtures.item(id: "genre-1", name: "Shoegaze", type: .musicGenre)),
            GenreRef(id: "genre-1", name: "Shoegaze")
        )
    }

    /// `/Genres` returns items typed `Genre`, not `MusicGenre`. Recognising
    /// only one of the two is what sent every search-result genre to the
    /// "Unsupported Item" screen, so this asserts against the whole of
    /// `BaseItemKind` rather than a hand-written list — a kind the SDK adds
    /// later fails here instead of in the UI.
    func testEveryGenreKindIsRecognisedAsAGenre() {
        let genreKinds = ItemType.allCases.filter { $0.rawValue.lowercased().hasSuffix("genre") }

        XCTAssertEqual(Set(genreKinds), [.genre, .musicGenre], "The SDK's genre kinds changed")
        for kind in genreKinds {
            XCTAssertTrue(kind.isGenre, "\(kind) is a genre kind but isn't recognised as one")
        }
    }

    func testNonGenreKindsAreNotMistakenForGenres() {
        for kind in [ItemType.musicAlbum, .musicArtist, .audio, .playlist, .folder] {
            XCTAssertFalse(kind.isGenre, "\(kind) is not a genre")
        }
    }

    func testDeduplicationKeepsTheOrderGenresWereListedIn() {
        let genres = [
            GenreRef(name: "Shoegaze"),
            GenreRef(name: "Dream Pop"),
            GenreRef(name: "SHOEGAZE"),
            GenreRef(name: "Noise Pop"),
        ]

        XCTAssertEqual(genres.uniquedByName.map(\.name), ["Shoegaze", "Dream Pop", "Noise Pop"])
    }
}
