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

    // MARK: - AI Radio

    /// Off until asked for: switching it on hides playlists from the library,
    /// which must never happen to somebody who didn't choose it.
    func testAIRadioIsOffBeforeTheUserHasChosen() {
        XCTAssertFalse(PreferencesStore(defaults: defaults).aiRadioEnabled)
        XCTAssertFalse(PreferencesStore(defaults: defaults).isAIRadioActive)
    }

    /// The field arrives pre-filled with AudioMuse-AI's own convention, so
    /// switching the feature on is enough for it to work.
    func testAIRadioSuffixDefaultsToTheAudioMuseEnding() {
        XCTAssertEqual(
            PreferencesStore(defaults: defaults).aiRadioSuffix,
            PreferencesStore.defaultAIRadioSuffix
        )
        XCTAssertEqual(PreferencesStore.defaultAIRadioSuffix, "_automatic")
    }

    func testTurningAIRadioOnAndEditingItsSuffixSurvivesRelaunch() {
        let store = PreferencesStore(defaults: defaults)
        store.aiRadioEnabled = true
        store.aiRadioSuffix = "_ai"

        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertTrue(reloaded.aiRadioEnabled)
        XCTAssertEqual(reloaded.aiRadioSuffix, "_ai")
        XCTAssertTrue(reloaded.isAIRadioActive)
    }

    /// An empty ending matches every name, which would hand the whole playlist
    /// library to AI Radio and leave the ordinary list empty. A blank field has
    /// to stand the feature down instead, including mid-edit.
    func testABlankSuffixLeavesAIRadioInactive() {
        for blank in ["", "   "] {
            let store = PreferencesStore(defaults: defaults)
            store.aiRadioEnabled = true
            store.aiRadioSuffix = blank

            XCTAssertFalse(store.isAIRadioActive, "\(blank.debugDescription)")
            XCTAssertNil(store.playlistNameFilter(for: .aiRadioPlaylists))
            XCTAssertNil(store.playlistNameFilter(for: .playlists))
        }
    }

    /// The two playlist lists sit on opposite sides of one split, and nothing
    /// else is split at all — hiding a station from favourites or from an "Add
    /// to Playlist" menu would make it unreachable rather than tidier.
    func testAIRadioSplitsOnlyTheTwoPlaylistLists() {
        let store = PreferencesStore(defaults: defaults)
        store.aiRadioEnabled = true

        XCTAssertEqual(store.playlistNameFilter(for: .aiRadioPlaylists), .endsWith("_automatic"))
        XCTAssertEqual(store.playlistNameFilter(for: .playlists), .notEndsWith("_automatic"))
        XCTAssertEqual(
            Set(LibraryList.allCases.compactMap { list -> LibraryList? in
                store.playlistNameFilter(for: list) == nil ? nil : list
            }),
            [.aiRadioPlaylists, .playlists]
        )
    }

    /// The suffix is matched as typed, not as stored: trailing whitespace from
    /// the settings field must not decide what counts as a station.
    func testAIRadioSuffixIsTrimmedBeforeItIsMatched() {
        let store = PreferencesStore(defaults: defaults)
        store.aiRadioEnabled = true
        store.aiRadioSuffix = "  _automatic  "

        XCTAssertEqual(store.playlistNameFilter(for: .aiRadioPlaylists), .endsWith("_automatic"))
    }

    func testNoSplitIsAppliedWhileTheFeatureIsOff() {
        XCTAssertNil(PreferencesStore(defaults: defaults).playlistNameFilter(for: .aiRadioPlaylists))
        XCTAssertNil(PreferencesStore(defaults: defaults).playlistNameFilter(for: .playlists))
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

    // MARK: - Station recognition

    func testOnlyPlaylistsEndingWithTheSuffixAreStations() {
        let store = PreferencesStore(defaults: defaults)
        store.aiRadioEnabled = true

        let station = TestFixtures.item(id: "station", name: "Chill_automatic", type: .playlist)
        let playlist = TestFixtures.item(id: "playlist", name: "Road Trip", type: .playlist)
        let album = TestFixtures.item(id: "album", name: "Chill_automatic", type: .musicAlbum)

        let off = PreferencesStore(defaults: defaults)
        off.aiRadioEnabled = false

        XCTAssertTrue(store.isAIRadioStation(station))
        XCTAssertFalse(store.isAIRadioStation(playlist))
        XCTAssertFalse(store.isAIRadioStation(album), "Only playlists can be stations")
        XCTAssertFalse(off.isAIRadioStation(station), "With the feature off nothing is a station")
    }

    func testStationNamesDropTheMatchedEnding() {
        let store = PreferencesStore(defaults: defaults)
        store.aiRadioEnabled = true
        let off = PreferencesStore(defaults: defaults)
        off.aiRadioEnabled = false
        let station = TestFixtures.item(id: "station", name: "Chill_automatic", type: .playlist)

        XCTAssertEqual(store.aiRadioStationName(for: station), "Chill")
        XCTAssertEqual(
            off.aiRadioStationName(for: station),
            "Chill_automatic",
            "With the feature off the name is shown as the server has it"
        )
    }
}
