import SwiftUI

/// The signed-in app shell.
///
/// - iPhone (compact width) uses a tab bar (``tabLayout``).
/// - iPad (regular width) and macOS use a sidebar-adaptable `TabView`
///   (``sidebarLayout``): a sidebar in landscape and on macOS, a top tab bar in
///   portrait on iPad.
///
/// The persistent ``NowPlayingBar`` is hosted as an iOS 26 tab bar accessory
/// on iOS — every supported version has the API — and docked below the tab
/// view on macOS.
struct MainShellView: View {
    @State private var selection: LibrarySection = .home
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var playerPresentation: PlayerPresentation
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var preferences: PreferencesStore
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var settingsPresentation: SettingsPresentation
    #endif

    /// The library sections the sidebar offers, Mixtapes among them only while
    /// the app is registered with a backend.
    private var librarySections: [LibrarySection] {
        LibrarySection.libraryGroup(showingMixtapes: preferences.isMixtapesActive)
    }

    var body: some View {
        settingsHost
            .sheet(isPresented: $playerPresentation.isShowingPlayer) { PlayerView() }
            .onChange(of: session.serverReachable, initial: true) { _, reachable in
                if !reachable { selection = .downloads }
            }
            // Losing the registration removes Mixtapes from under the
            // selection; left alone the shell would be showing a destination
            // that no longer exists.
            .onChange(of: preferences.isMixtapesActive) { _, active in
                if !active, selection == .mixtapes { selection = .albums }
            }
    }

    /// iOS reaches settings through a sheet rather than a scene. It is hosted
    /// here, above the tabs, so that it survives the tab bar teardown that
    /// dismisses sheets owned by toolbar items, and so every tab's
    /// ``AccountMenu`` raises the same one.
    @ViewBuilder private var settingsHost: some View {
        #if os(iOS)
        layout
            .sheet(isPresented: $settingsPresentation.isShowingSettings) { SettingsView() }
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
    /// The tab bar hosts the mini player as a bottom accessory (iOS 26.1+,
    /// which is every supported iOS), floating it above the bar instead of
    /// covering it.
    private var tabLayout: some View {
        TabView(selection: $selection) {
            Tab(LibrarySection.home.title, systemImage: LibrarySection.home.systemImage, value: LibrarySection.home) {
                LibraryNavigationStack {
                    HomeView()
                        .toolbar { ToolbarItem(placement: .primaryAction) { AccountMenu() } }
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
            .badge(downloads.batches.isEmpty ? 0 : downloads.entries.count)
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
            Tab(value: LibrarySection.downloads) {
                LibraryNavigationStack {
                    DownloadsView()
                }
            } label: {
                downloadsLabel
            }
            .badge(downloads.batches.isEmpty ? 0 : downloads.entries.count)
            Tab(LibrarySection.search.title, systemImage: LibrarySection.search.systemImage, value: LibrarySection.search) {
                sectionTab(.search)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    /// One sidebar tab: the section's root wrapped in its own navigation stack.
    /// On iOS the mini player rides the tab bar accessory applied to the whole
    /// layout; on macOS the shell docks the bar below the tab view.
    @ViewBuilder private func sectionTab(_ section: LibrarySection) -> some View {
        let content = LibraryNavigationStack {
            SectionRootView(section: section)
                .toolbar { ToolbarItem(placement: .primaryAction) { AccountMenu() } }
        }
        content
    }

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
}
