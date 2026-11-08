import Foundation
import JellyfinAPI
import XCTest
@testable import JellyJams

/// The "Ban" submenu's mapping from an item to the choices it offers — the
/// labels the user reads and the ids that go to the backend, spelled out on
/// the shape of the request: "Ban Me" off "Bad Songs" by "Bad Artist" and
/// "Worse Artist" bans as the song, the album, or either artist.
final class BanMenuOptionTests: XCTestCase {
    /// A song as the server delivers one: album name and id, every artist
    /// paired by id.
    private func song(
        id: String = "song-1",
        name: String = "Ban Me",
        album: String? = "Bad Songs",
        albumID: String? = "album-1",
        artists: [NameIDPair] = [
            NameIDPair(id: "artist-1", name: "Bad Artist"),
            NameIDPair(id: "artist-2", name: "Worse Artist"),
        ]
    ) -> BaseItemDto {
        BaseItemDto(
            album: album,
            albumID: albumID,
            artistItems: artists,
            id: id,
            name: name,
            type: .audio
        )
    }

    func testASongOffersItselfItsAlbumAndEveryArtist() {
        let options = BanMenu.banOptions(for: song())

        XCTAssertEqual(options.map(\.label), [
            "Ban song: “Ban Me”",
            "Ban album: “Bad Songs”",
            "Ban artist: “Bad Artist”",
            "Ban artist: “Worse Artist”",
        ])
        XCTAssertEqual(options.map(\.itemIds), [["song-1"], ["album-1"], ["artist-1"], ["artist-2"]])
    }

    /// A selection acts as one — banning the song bans every selected song,
    /// labelled by count rather than a name that now belongs to only one
    /// of them.
    func testAMultiSelectionBansAllSelectedSongsUnderOneLabel() {
        let options = BanMenu.banOptions(for: song(), selectedSongIds: ["song-1", "song-2", "song-3"])

        XCTAssertEqual(options.first?.label, "Ban 3 songs")
        XCTAssertEqual(options.first?.itemIds, ["song-1", "song-2", "song-3"])
        // The album and artists stay the tapped row's own.
        XCTAssertEqual(options.dropFirst().map(\.label), [
            "Ban album: “Bad Songs”",
            "Ban artist: “Bad Artist”",
            "Ban artist: “Worse Artist”",
        ])
    }

    func testASingleSelectionKeepsTheNamedSongLabel() {
        let options = BanMenu.banOptions(for: song(), selectedSongIds: ["song-1"])
        XCTAssertEqual(options.first?.label, "Ban song: “Ban Me”")
    }

    /// Servers omit; the menu must offer only what there is an id to ban.
    func testFieldsWithoutIdsSimplyDropOutOfTheMenu() {
        let options = BanMenu.banOptions(
            for: song(
                albumID: nil,
                artists: [
                    NameIDPair(id: nil, name: "Nameless"),
                    NameIDPair(id: "artist-1", name: "Bad Artist"),
                ]
            )
        )
        XCTAssertEqual(options.map(\.label), [
            "Ban song: “Ban Me”",
            "Ban artist: “Bad Artist”",
        ])

        let nameless = BanMenu.banOptions(for: song(id: "song-1", album: nil, albumID: nil, artists: []))
        XCTAssertEqual(nameless.count, 1) // just the song
    }

    /// An album tile bans as itself and as its album-artists — never its
    /// track artists.
    func testAnAlbumOffersItselfAndItsAlbumArtists() {
        let album = BaseItemDto(
            albumArtists: [NameIDPair(id: "artist-1", name: "Bad Artist")],
            artistItems: [NameIDPair(id: "artist-9", name: "Track Artist Ignored")],
            id: "album-1",
            name: "Bad Songs",
            type: .musicAlbum
        )

        let options = BanMenu.banOptions(for: album)
        XCTAssertEqual(options.map(\.label), [
            "Ban album: “Bad Songs”",
            "Ban artist: “Bad Artist”",
        ])
        XCTAssertEqual(options.map(\.itemIds), [["album-1"], ["artist-1"]])
    }

    func testAnArtistOffersOnlyItself() {
        let artist = BaseItemDto(id: "artist-1", name: "Bad Artist", type: .musicArtist)

        let options = BanMenu.banOptions(for: artist)
        XCTAssertEqual(options.map(\.label), ["Ban artist: “Bad Artist”"])
        XCTAssertEqual(options.map(\.itemIds), [["artist-1"]])
    }

    /// Playlists and genres have nothing to ban here — whatever a type has
    /// no option for yields no submenu at all.
    func testKindsThatCannotBeBanOfferNothing() {
        XCTAssertEqual(BanMenu.banOptions(for: BaseItemDto(id: "p", name: "Mix", type: .playlist)), [])
        XCTAssertEqual(BanMenu.banOptions(for: BaseItemDto(id: "g", name: "Shoegaze", type: .musicGenre)), [])
        XCTAssertEqual(BanMenu.banOptions(for: BaseItemDto(id: "x", type: nil)), [])
    }
}
