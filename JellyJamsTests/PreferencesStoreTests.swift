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
        store.recordRegistration(address: "https://backend.example.net", suffix: "_jams", playlist: "Server Mix")

        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.jellyJamsBackendAddress, "https://backend.example.net")
        XCTAssertEqual(reloaded.mixtapeSuffix, "_jams")
        XCTAssertEqual(reloaded.serverPlaylist, "Server Mix")
        XCTAssertTrue(reloaded.isMixtapesActive)
        XCTAssertEqual(reloaded.playlistNameFilter(for: .mixtapePlaylists), .endsWith("_jams"))
        XCTAssertEqual(reloaded.playlistNameFilter(for: .playlists), .notEndsWith("_jams"))
    }

    /// A confirmed sign-out is a clean break: the address, the registration,
    /// the Server Playlist, the limits and the Infinite Queue switch all go,
    /// and they stay gone across a relaunch — the next backend starts from
    /// the same blank slate this one did, with nothing carried over behind
    /// its back. The app's other preferences are none of its business.
    func testSigningOutForgetsTheWholeBackend() {
        let store = PreferencesStore(defaults: defaults)
        store.recordRegistration(address: "https://backend.example.net", suffix: "_automatic", playlist: "Server Mix")
        store.serverPlaylistJoined = true
        store.sameAlbumLimit = 7
        store.sameArtistLimit = 2
        store.infiniteQueueEnabled = true
        store.showsSimilarItems = false

        store.forgetBackend()

        XCTAssertFalse(store.isMixtapesActive)
        XCTAssertNil(store.playlistNameFilter(for: .mixtapePlaylists))
        XCTAssertNil(store.playlistNameFilter(for: .playlists))

        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.jellyJamsBackendAddress, "")
        XCTAssertEqual(reloaded.mixtapeSuffix, "")
        XCTAssertEqual(reloaded.serverPlaylist, "")
        XCTAssertFalse(reloaded.serverPlaylistJoined)
        XCTAssertFalse(reloaded.isMixtapesActive)
        XCTAssertEqual(reloaded.sameAlbumLimit, 3, "The limits return to the backend's defaults")
        XCTAssertEqual(reloaded.sameArtistLimit, 5)
        XCTAssertFalse(reloaded.infiniteQueueEnabled)
        XCTAssertFalse(reloaded.showsSimilarItems, "A preference that is not the backend's survives the break")
    }

    /// The whole reset a server sign-out performs: not just the backend's
    /// share, but every setting back to what a fresh install reads before
    /// anyone has touched anything — persisted, so a relaunch agrees.
    func testForgettingEverythingRestoresTheFreshInstallState() {
        let store = PreferencesStore(defaults: defaults)
        store.showsSimilarItems = false
        store.showsCompleteAlbumsOnly = false
        store.defaultPlayback = DefaultPlaybackSetting(
            kind: .song,
            itemId: "song-1",
            title: "Renegade",
            shuffle: true,
            repeatMode: .repeatOne
        )
        store.recordRegistration(address: "https://backend.example.net", suffix: "_automatic", playlist: "Server Mix")
        store.infiniteQueueEnabled = true

        store.forgetEverything()

        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertTrue(reloaded.showsSimilarItems)
        XCTAssertTrue(reloaded.showsCompleteAlbumsOnly)
        XCTAssertNil(reloaded.defaultPlayback)
        XCTAssertEqual(reloaded.jellyJamsBackendAddress, "")
        XCTAssertFalse(reloaded.isMixtapesActive)
        XCTAssertFalse(reloaded.infiniteQueueEnabled)
    }

    /// An empty ending matches every name, which would hand the whole playlist
    /// library to Mixtapes and leave the ordinary list empty. A backend that
    /// answers with nothing has to stand the feature down.
    func testABlankSuffixLeavesMixtapesInactive() {
        for blank in ["", "   "] {
            let store = PreferencesStore(defaults: defaults)
            store.recordRegistration(address: "https://backend.example.net", suffix: blank, playlist: "Server Mix")

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
        store.recordRegistration(address: "https://backend.example.net", suffix: "_automatic", playlist: "Server Mix")

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
        store.recordRegistration(address: "https://backend.example.net", suffix: "  _automatic  ", playlist: "Server Mix")

        XCTAssertEqual(store.playlistNameFilter(for: .mixtapePlaylists), .endsWith("_automatic"))
    }

    func testNoSplitIsAppliedBeforeRegistration() {
        XCTAssertNil(PreferencesStore(defaults: defaults).playlistNameFilter(for: .mixtapePlaylists))
        XCTAssertNil(PreferencesStore(defaults: defaults).playlistNameFilter(for: .playlists))
    }

    // MARK: - Server Playlist

    /// Off until opted in: the blend gathers a real account's listening for
    /// everybody in it, so nobody should be in before they have asked.
    func testServerPlaylistIsOffBeforeTheUserHasChosen() {
        XCTAssertFalse(PreferencesStore(defaults: defaults).serverPlaylistJoined)
    }

    /// The remembered membership outlives a relaunch — and an offline spell:
    /// it is what the settings sheet shows when the backend cannot answer.
    func testServerPlaylistMembershipSurvivesRelaunch() {
        PreferencesStore(defaults: defaults).serverPlaylistJoined = true

        XCTAssertTrue(PreferencesStore(defaults: defaults).serverPlaylistJoined)
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
        store.recordRegistration(address: "https://backend.example.net", suffix: "_automatic", playlist: "Server Mix")

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
        store.recordRegistration(address: "https://backend.example.net", suffix: "_automatic", playlist: "Server Mix")
        let mixtape = TestFixtures.item(id: "mixtape", name: "Chill_automatic", type: .playlist)

        XCTAssertEqual(store.mixtapeName(for: mixtape), "Chill")
        XCTAssertEqual(
            off.mixtapeName(for: mixtape),
            "Chill_automatic",
            "Before registration the name is shown as the server has it"
        )
    }

    // MARK: - Infinite Queue

    /// Off before anyone asks for it: an absent key must not ship a feature
    /// that grows every queue forever and calls out to the companion service
    /// switched on.
    func testInfiniteQueueIsOffBeforeTheUserHasChosen() {
        XCTAssertFalse(PreferencesStore(defaults: defaults).infiniteQueueEnabled)
    }

    func testTurningInfiniteQueueOnSurvivesRelaunch() {
        PreferencesStore(defaults: defaults).infiniteQueueEnabled = true

        XCTAssertTrue(PreferencesStore(defaults: defaults).infiniteQueueEnabled)
        XCTAssertEqual(defaults.object(forKey: "infiniteQueueEnabled") as? Bool, true)
    }

    // MARK: - Audio normalization

    /// Off before anyone has chosen: an absent key must not ship the feature
    /// on, which is why the read goes through `object(forKey:)` rather than
    /// `bool(forKey:)`.
    func testAudioNormalizationIsOffBeforeTheUserHasChosen() {
        XCTAssertFalse(PreferencesStore(defaults: defaults).audioNormalizationEnabled)
    }

    /// The opt-in survives a relaunch, so a listener who turned normalization
    /// on keeps it — and turning it back off does too, rather than falling back
    /// to the default.
    func testTurningAudioNormalizationOnSurvivesRelaunch() {
        PreferencesStore(defaults: defaults).audioNormalizationEnabled = true

        XCTAssertTrue(PreferencesStore(defaults: defaults).audioNormalizationEnabled)
        XCTAssertEqual(defaults.object(forKey: "audioNormalizationEnabled") as? Bool, true)
    }

    func testTurningAudioNormalizationOffSurvivesRelaunch() {
        PreferencesStore(defaults: defaults).audioNormalizationEnabled = true
        PreferencesStore(defaults: defaults).audioNormalizationEnabled = false

        XCTAssertFalse(PreferencesStore(defaults: defaults).audioNormalizationEnabled)
        XCTAssertEqual(defaults.object(forKey: "audioNormalizationEnabled") as? Bool, false)
    }

    /// The sign-out reset returns it to the fresh-install state: normalization
    /// is a listening preference, so it does not survive being signed out.
    func testForgettingEverythingTurnsAudioNormalizationOff() {
        let store = PreferencesStore(defaults: defaults)
        store.audioNormalizationEnabled = true

        store.forgetEverything()

        XCTAssertFalse(store.audioNormalizationEnabled)
    }
}
