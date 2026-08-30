import SwiftUI

/// The signed-in app shell.
///
/// - iPhone (compact width) uses a tab bar (``tabLayout``).
/// - iPad (regular width) and macOS use a sidebar-adaptable `TabView`
///   (``sidebarLayout``): a sidebar in landscape and on macOS, a top tab bar in
///   portrait on iPad.
///
/// The persistent ``NowPlayingBar`` is hosted as an iOS 26 tab bar accessory
/// where available, docked inside each tab's content on earlier iOS, and docked
/// below the tab view on macOS.
struct MainShellView: View {
    @State private var selection: LibrarySection = .albums
    @EnvironmentObject private var playerPresentation: PlayerPresentation
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var settingsPresentation: SettingsPresentation
    #endif

    var body: some View {
        settingsHost
            .sheet(isPresented: $playerPresentation.isShowingPlayer) { PlayerView() }
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
    /// The mini player is docked inside each tab rather than around the tab
    /// view so that it floats above the tab bar instead of covering it. On
    /// iOS 26.1+ the tab bar hosts it as a bottom accessory instead.
    private var tabLayout: some View {
        TabView {
            Tab("Library", systemImage: "square.stack") {
                LibraryNavigationStack {
                    LibraryHubView()
                        .toolbar { ToolbarItem(placement: .primaryAction) { AccountMenu() } }
                }
            }

            Tab("Search", systemImage: "magnifyingglass") {
                LibraryNavigationStack {
                    SectionRootView(section: .search)
                }
            }

            Tab("Favourites", systemImage: "heart") {
                LibraryNavigationStack {
                    SectionRootView(section: .favorites)
                }
            }
        }
        .nowPlayingTabAccessory()
    }
    #endif

    // MARK: - Sidebar-adaptable tabs (iPad regular width + macOS)

    private var sidebarLayout: some View {
        TabView(selection: $selection) {
            TabSection("Library") {
                ForEach(LibrarySection.libraryGroup) { section in
                    Tab(section.title, systemImage: section.systemImage, value: section) {
                        sectionTab(section)
                    }
                }
            }
            Tab(LibrarySection.favorites.title, systemImage: LibrarySection.favorites.systemImage, value: LibrarySection.favorites) {
                sectionTab(.favorites)
            }
            Tab(LibrarySection.search.title, systemImage: LibrarySection.search.systemImage, value: LibrarySection.search) {
                sectionTab(.search)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    /// One sidebar tab: the section's root wrapped in its own navigation stack.
    /// On iOS the mini player docks inside the content on OS versions without
    /// the tab bar accessory; on macOS the bar is docked around the tab view.
    @ViewBuilder private func sectionTab(_ section: LibrarySection) -> some View {
        let content = LibraryNavigationStack {
            SectionRootView(section: section)
                .toolbar { ToolbarItem(placement: .primaryAction) { AccountMenu() } }
        }
        #if os(iOS)
        content
        #else
        content
        #endif
    }
}
