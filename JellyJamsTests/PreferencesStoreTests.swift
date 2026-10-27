import XCTest
@testable import JellyJams

/// Covers the persistence of user settings. The default matters as much as the
/// round trip: a preference that reads as off before anyone has touched it
/// ships the feature disabled for every existing install.
@MainActor
final class PreferencesStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() async throws {
        suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
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

    // MARK: - Downloads filter

    /// On by default: the Downloads album list starts filtered to what is fully
    /// on disk, and a preference that read as off before anyone touched it would
    /// ship the filter already switched off.
    func testCompleteAlbumsFilterIsOnBeforeTheUserHasChosen() {
        XCTAssertTrue(PreferencesStore(defaults: defaults).showsCompleteAlbumsOnly)
    }

    func testShowingPartialAlbumsSurvivesRelaunch() {
        PreferencesStore(defaults: defaults).showsCompleteAlbumsOnly = false

        XCTAssertFalse(PreferencesStore(defaults: defaults).showsCompleteAlbumsOnly)
    }

    // MARK: - Mixtapes

    /// Nothing to gather by until a registration says otherwise: an app that
    /// read as active before anyone registered would split the library on a
    /// rule the backend never handed out.
    func testMixtapesAreInactiveBeforeRegistration() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.jellyJamsBackendAddress, "")
        XCTAssertEqual(store.mixtapeSuffix, "")
        XCTAssertFalse(store.isMixtapesActive)
    }

    /// The settings field edits the address directly, so a half-typed host
    /// survives a relaunch rather than vanishing; only a save turns anything
    /// on.
    func testEditingTheBackendAddressSurvivesRelaunch() {
        PreferencesStore(defaults: defaults).jellyJamsBackendAddress = "http://192.168.0.10:8000"

        XCTAssertEqual(
            PreferencesStore(defaults: defaults).jellyJamsBackendAddress,
            "http://192.168.0.10:8000"
        )
    }

    /// A successful save records both halves of what the backend said — the
    /// address it was reached at and the ending its mixtapes carry — and the
    /// feature runs on them from then on.
    func testRegistrationSurvivesRelaunch() {
        let store = PreferencesStore(defaults: defaults)
        store.recordRegistration(address: "https://backend.example.net", suffix: "_jams")

        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.jellyJamsBackendAddress, "https://backend.example.net")
        XCTAssertEqual(reloaded.mixtapeSuffix, "_jams")
        XCTAssertTrue(reloaded.isMixtapesActive)
        XCTAssertEqual(reloaded.playlistNameFilter(for: .mixtapePlaylists), .endsWith("_jams"))
        XCTAssertEqual(reloaded.playlistNameFilter(for: .playlists), .notEndsWith("_jams"))
    }

    /// An empty ending matches every name, which would hand the whole playlist
    /// library to Mixtapes and leave the ordinary list empty. A backend that
    /// answers with nothing has to stand the feature down.
    func testABlankSuffixLeavesMixtapesInactive() {
        for blank in ["", "   "] {
            let store = PreferencesStore(defaults: defaults)
            store.recordRegistration(address: "https://backend.example.net", suffix: blank)

            XCTAssertFalse(store.isMixtapesActive, "\(blank.debugDescription)")
            XCTAssertNil(store.playlistNameFilter(for: .mixtapePlaylists))
            XCTAssertNil(store.playlistNameFilter(for: .playlists))
        }
    }

    /// The two playlist lists sit on opposite sides of one split, and nothing
    /// else is split at all — hiding a mixtape from favourites or from an
    /// "Add to Playlist" menu would make it unreachable rather than tidier.
    func testMixtapesSplitsOnlyTheTwoPlaylistLists() {
        let store = PreferencesStore(defaults: defaults)
        store.recordRegistration(address: "https://backend.example.net", suffix: "_automatic")

        XCTAssertEqual(store.playlistNameFilter(for: .mixtapePlaylists), .endsWith("_automatic"))
        XCTAssertEqual(store.playlistNameFilter(for: .playlists), .notEndsWith("_automatic"))
        XCTAssertEqual(
            Set(LibraryList.allCases.compactMap { list -> LibraryList? in
                store.playlistNameFilter(for: list) == nil ? nil : list
            }),
            [.mixtapePlaylists, .playlists]
        )
    }

    /// The suffix is matched trimmed, not as stored: whitespace from a sloppy
    /// backend setting must not decide what counts as a mixtape.
    func testMixtapeSuffixIsTrimmedBeforeItIsMatched() {
        let store = PreferencesStore(defaults: defaults)
        store.recordRegistration(address: "https://backend.example.net", suffix: "  _automatic  ")

        XCTAssertEqual(store.playlistNameFilter(for: .mixtapePlaylists), .endsWith("_automatic"))
    }

    func testNoSplitIsAppliedBeforeRegistration() {
        XCTAssertNil(PreferencesStore(defaults: defaults).playlistNameFilter(for: .mixtapePlaylists))
        XCTAssertNil(PreferencesStore(defaults: defaults).playlistNameFilter(for: .playlists))
    }

    // MARK: - Family Blend

    /// Off until opted in: the blend gathers a real account's listening for
    /// everybody in it, so nobody should be in before they have asked.
    func testFamilyBlendIsOffBeforeTheUserHasChosen() {
        XCTAssertFalse(PreferencesStore(defaults: defaults).familyBlendJoined)
    }

    /// The remembered membership outlives a relaunch — and an offline spell:
    /// it is what the settings sheet shows when the backend cannot answer.
    func testFamilyBlendMembershipSurvivesRelaunch() {
        PreferencesStore(defaults: defaults).familyBlendJoined = true

        XCTAssertTrue(PreferencesStore(defaults: defaults).familyBlendJoined)
    }

    // MARK: - Default playback

    /// Unset must mean the built-in favourites shuffle: a fresh install (or a
    /// stored blob from a version that didn't write it) has to read as nil,
    /// not as some defaulted item.
    func testDefaultPlaybackIsUnsetBeforeTheUserHasChosen() {
        XCTAssertNil(PreferencesStore(defaults: defaults).defaultPlayback)
    }

    func testDefaultPlaybackSurvivesRelaunch() {
        let store = PreferencesStore(defaults: defaults)
        store.defaultPlayback = DefaultPlaybackSetting(
            kind: .album,
            itemId: "album-1",
            title: "For All Kings",
            shuffle: true,
            repeatMode: .repeatAll
        )

        XCTAssertEqual(PreferencesStore(defaults: defaults).defaultPlayback, store.defaultPlayback)
    }

    /// Editing the transport settings of a chosen item must persist too —
    /// they are part of the same blob the resolver reads at play time.
    func testEditingDefaultPlaybackTransportSettingsSurvivesRelaunch() {
        let store = PreferencesStore(defaults: defaults)
        store.defaultPlayback = DefaultPlaybackSetting(
            kind: .playlist,
            itemId: "playlist-1",
            title: "Top 40",
            shuffle: false,
            repeatMode: .repeatNone
        )
        store.defaultPlayback?.shuffle = true
        store.defaultPlayback?.repeatMode = .repeatOne

        let reloaded = PreferencesStore(defaults: defaults).defaultPlayback
        XCTAssertEqual(reloaded?.shuffle, true)
        XCTAssertEqual(reloaded?.repeatMode, .repeatOne)
    }

    /// Clearing the choice has to remove the stored blob, so the next launch
    /// reads nil rather than resurrecting the old item.
    func testClearingDefaultPlaybackSurvivesRelaunch() {
        let store = PreferencesStore(defaults: defaults)
        store.defaultPlayback = DefaultPlaybackSetting(
            kind: .artist,
            itemId: "artist-1",
            title: "Architects",
            shuffle: true,
            repeatMode: .repeatNone
        )
        store.defaultPlayback = nil

        XCTAssertNil(PreferencesStore(defaults: defaults).defaultPlayback)
        XCTAssertNil(defaults.data(forKey: "defaultPlayback"))
    }

    // MARK: - Mixtape recognition

    func testOnlyPlaylistsEndingWithTheSuffixAreMixtapes() {
        // Built before the registration below writes it through: a store that
        // shares the defaults suite would otherwise reload the very
        // registration this test is trying to contrast against.
        let off = PreferencesStore(defaults: defaults)

        let store = PreferencesStore(defaults: defaults)
        store.recordRegistration(address: "https://backend.example.net", suffix: "_automatic")

        let mixtape = TestFixtures.item(id: "mixtape", name: "Chill_automatic", type: .playlist)
        let playlist = TestFixtures.item(id: "playlist", name: "Road Trip", type: .playlist)
        let album = TestFixtures.item(id: "album", name: "Chill_automatic", type: .musicAlbum)

        XCTAssertTrue(store.isMixtape(mixtape))
        XCTAssertFalse(store.isMixtape(playlist))
        XCTAssertFalse(store.isMixtape(album), "Only playlists can be mixtapes")
        XCTAssertFalse(off.isMixtape(mixtape), "Before registration nothing is a mixtape")
    }

    func testMixtapeNamesDropTheMatchedEnding() {
        let off = PreferencesStore(defaults: defaults)
        let store = PreferencesStore(defaults: defaults)
        store.recordRegistration(address: "https://backend.example.net", suffix: "_automatic")
        let mixtape = TestFixtures.item(id: "mixtape", name: "Chill_automatic", type: .playlist)

        XCTAssertEqual(store.mixtapeName(for: mixtape), "Chill")
        XCTAssertEqual(
            off.mixtapeName(for: mixtape),
            "Chill_automatic",
            "Before registration the name is shown as the server has it"
        )
    }
}
