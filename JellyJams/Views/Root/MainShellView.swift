import SwiftUI

/// The signed-in app shell.
///
/// - iPhone (compact width) uses a tab bar (``tabLayout``).
/// - iPad (regular width), macOS and tvOS use a sidebar-adaptable `TabView`
///   (``sidebarLayout``): a sidebar in landscape, on macOS and on tvOS, a top
///   tab bar in portrait on iPad.
///
/// The persistent ``NowPlayingBar`` is hosted as an iOS 26 tab bar accessory
/// on iOS and docked below the tab view on macOS and tvOS.
struct MainShellView: View {
    @State private var selection: LibrarySection = .home
    /// Raised by the Home toolbar's sparkles button; the sheet itself is
    /// hosted above the tabs in ``body``, like the player and settings ones.
    @State private var isPresentingTextToTunes = false
    @Environment(SessionStore.self) private var session
    @Environment(PlayerController.self) private var player
    @Environment(PlayerPresentation.self) private var playerPresentation
    #if !os(tvOS)
    @Environment(DownloadStore.self) private var downloads
    #endif
    @Environment(PreferencesStore.self) private var preferences
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if !os(macOS)
    @Environment(SettingsPresentation.self) private var settingsPresentation
    #endif

    /// The library sections the sidebar offers, Mixtapes among them only while
    /// the app is registered with a backend.
    private var librarySections: [LibrarySection] {
        LibrarySection.libraryGroup(showingMixtapes: preferences.isMixtapesActive)
    }

    var body: some View {
        settingsHost
            #if os(tvOS)
            // The player owns the whole screen on TV, like the Music app's
            // Now Playing screen — a sheet would leave it a card over the
            // shell. The remote's Menu button dismisses the cover.
            .fullScreenCover(isPresented: Bindable(playerPresentation).isShowingPlayer) { PlayerView() }
            #else
            .sheet(isPresented: Bindable(playerPresentation).isShowingPlayer) { PlayerView() }
            #endif
            // Hosted here rather than by the toolbar button that raises it,
            // for the settings sheet's own reason: a sheet owned by a
            // toolbar item dies with the tab bar teardown on iOS.
            .sheet(isPresented: $isPresentingTextToTunes) { TextToTunesSheet() }
            #if !os(tvOS)
            // Losing the server moves the listener to their downloaded music.
            // tvOS has no Downloads section — the system can purge anything
            // downloaded without warning — so there it leaves them where they
            // are instead.
            .onChange(of: session.serverReachable, initial: true) { _, reachable in
                if !reachable { selection = .downloads }
            }
            #endif
            // Losing the registration removes Mixtapes from under the
            // selection; left alone the shell would be showing a destination
            // that no longer exists.
            .onChange(of: preferences.isMixtapesActive) { _, active in
                if !active, selection == .mixtapes { selection = .albums }
            }
            #if os(tvOS)
            // A playback session starting from nothing opens the player;
            // one starting while a session is already running keeps the
            // current screen — the listener is already listening. Track
            // changes and queue swaps never cross this transition, so they
            // never interrupt whatever is on screen.
            .onChange(of: player.currentItem == nil) { wasEmpty, isEmpty in
                if wasEmpty && !isEmpty {
                    playerPresentation.isShowingPlayer = true
                }
            }
            #endif
            #if !os(macOS)
            // Asked here, once someone is signed in: Siri permission is only
            // worth granting when there is a library for Siri to play from.
            // tvOS needs it as much as iOS — the SiriKit Media domain is the
            // only playback path there.
            .task { MediaIntentHandler.requestAuthorizationIfNeeded() }
            #endif
    }

    /// iOS and tvOS reach settings through a sheet rather than a scene. It is
    /// hosted here, above the tabs, so that it survives the tab bar teardown
    /// that dismisses sheets owned by toolbar items, and so every tab's
    /// ``AccountMenu`` raises the same one.
    @ViewBuilder private var settingsHost: some View {
        #if !os(macOS)
        layout
            .sheet(isPresented: Bindable(settingsPresentation).isShowingSettings) { SettingsView() }
        #else
        layout
        #endif
    }

    @ViewBuilder private var layout: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            tabLayout
        } else {
            sidebarLayout.nowPlayingTabAccessory()
        }
        #else
        VStack(spacing: 0) {
            sidebarLayout
            NowPlayingBar()
        }
        #endif
    }

    // MARK: - iPhone tabs

    #if os(iOS)
    /// The tab bar hosts the mini player as a bottom accessory, floating it
    /// above the bar instead of covering it.
    private var tabLayout: some View {
        TabView(selection: $selection) {
            Tab(LibrarySection.home.title, systemImage: LibrarySection.home.systemImage, value: LibrarySection.home) {
                LibraryNavigationStack {
                    HomeView()
                        .toolbar {
                            // Text to Tunes rides the backend's registration, so
                            // it is offered only while one is standing — the same
                            // flag that hides the Mixtapes tab and raises the
                            // sheet.
                            if preferences.isMixtapesActive {
                                ToolbarItem(placement: .primaryAction) { textToTunesButton }
                            }
                            ToolbarItem(placement: .primaryAction) { AccountMenu() }
                        }
                }
            }

            Tab("Library", systemImage: "square.stack", value: LibrarySection.albums) {
                LibraryNavigationStack {
                    LibraryHubView()
                        .toolbar { ToolbarItem(placement: .primaryAction) { AccountMenu() } }
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: LibrarySection.search) {
                LibraryNavigationStack {
                    SectionRootView(section: .search)
                }
            }

            Tab("Favourites", systemImage: "heart", value: LibrarySection.favorites) {
                LibraryNavigationStack {
                    SectionRootView(section: .favorites)
                }
            }

            Tab(value: LibrarySection.downloads) {
                LibraryNavigationStack {
                    DownloadsView()
                }
            } label: {
                downloadsLabel
            }
            .badge(downloads.remainingDownloadCount)
        }
        .nowPlayingTabAccessory()
    }
    #endif

    // MARK: - Sidebar-adaptable tabs (iPad regular width + macOS)

    private var sidebarLayout: some View {
        TabView(selection: $selection) {
            Tab(LibrarySection.home.title, systemImage: LibrarySection.home.systemImage, value: LibrarySection.home) {
                sectionTab(.home)
            }
            TabSection("Library") {
                ForEach(librarySections) { section in
                    Tab(section.title, systemImage: section.systemImage, value: section) {
                        sectionTab(section)
                    }
                }
            }
            Tab(LibrarySection.favorites.title, systemImage: LibrarySection.favorites.systemImage, value: LibrarySection.favorites) {
                sectionTab(.favorites)
            }
            #if !os(tvOS)
            // No Downloads section on tvOS: the system can delete anything the
            // user downloads without warning and without recourse, so the
            // feature is not offered there at all.
            Tab(value: LibrarySection.downloads) {
                LibraryNavigationStack {
                    DownloadsView()
                }
            } label: {
                downloadsLabel
            }
            .badge(downloads.remainingDownloadCount)
            #endif
            Tab(LibrarySection.search.title, systemImage: LibrarySection.search.systemImage, value: LibrarySection.search) {
                sectionTab(.search)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    /// One sidebar tab: the section's root wrapped in its own navigation stack.
    /// On iOS the mini player rides the tab bar accessory applied to the whole
    /// layout; on macOS the shell docks the bar below the tab view.
    ///
    /// On tvOS the system bar is hidden once, statically — toggling it from
    /// scroll geometry deadlocks the focus-driven scroll engine — and the
    /// section's scrolling bar (``TVScrollingBarSlot``) carries its contents
    /// instead. The shell's own actions ride the environment channel into it.
    @ViewBuilder private func sectionTab(_ section: LibrarySection) -> some View {
        let content = LibraryNavigationStack {
            SectionRootView(section: section)
                .toolbar {
                    // Text to Tunes is a Home-screen feature, so its button is
                    // offered there alone — declared first, which is the slot
                    // to the left of the account menu — and only while a
                    // backend is registered to serve it.
                    if section == .home, preferences.isMixtapesActive {
                        ToolbarItem(placement: .primaryAction) { textToTunesButton }
                    }
                    ToolbarItem(placement: .primaryAction) { AccountMenu() }
                }
        }
        #if os(tvOS)
        content
            // Search keeps its bar: the .searchable field lives in it.
            .toolbarVisibility(section == .search ? .visible : .hidden, for: .navigationBar)
            .environment(\.tvShellBarActions, AnyView(shellBarActions(for: section)))
        #else
        content
        #endif
    }

    #if os(tvOS)
    @ViewBuilder private func shellBarActions(for section: LibrarySection) -> some View {
        if section == .home, preferences.isMixtapesActive {
            textToTunesButton
        }
        AccountMenu()
    }
    #endif

    /// The Home toolbar's Text to Tunes button: it raises the sheet hosted
    /// above the tabs rather than owning one itself.
    private var textToTunesButton: some View {
        Button {
            isPresentingTextToTunes = true
        } label: {
            Label("Text to Tunes", systemImage: "sparkles.2")
        }
    }

    #if !os(tvOS)
    /// The Downloads tab icon: a live progress ring while batches run, the
    /// usual down-arrow otherwise.
    private var downloadsLabel: some View {
        Label {
            Text(LibrarySection.downloads.title)
        } icon: {
            if downloads.batches.isEmpty == false {
                Image(systemName: "arrow.down.circle.dotted")
            } else {
                Image(systemName: LibrarySection.downloads.systemImage)
            }
        }
    }
    #endif
}
