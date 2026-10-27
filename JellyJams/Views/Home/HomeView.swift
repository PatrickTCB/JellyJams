import SwiftUI

/// The Home tab: pinned items, recent music and Mixtapes quick links.
///
/// Each section hides itself when it has nothing to show, so the page grows by
/// adding a view to the stack here and a fetch to ``HomeModel``.
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var pinnedItems: PinnedItemsStore
    @StateObject private var model = HomeModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !pinnedItems.entries.isEmpty {
                    PinnedItemsSection(entries: pinnedItems.entries)
                }
                if !model.mixtapes.isEmpty {
                    MixtapesQuickLinksSection(mixtapes: model.mixtapes)
                }
                if !model.latest.isEmpty {
                    RecentMusicSection(heading: model.recentHeading, latest: model.latest)
                }
            }
            .padding(.vertical)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Home")
        .refreshable { await load() }
        .refreshToolbarItem { await load() }
        // Re-runs on appear and whenever the mixtape rule itself changes, so
        // registering with a backend (or moving to one that names things
        // differently) updates the quick links without leaving the page.
        .task(id: preferences.playlistNameFilter(for: .mixtapePlaylists)) { await load() }
    }

    private func load() async {
        await model.reload(using: session.library, preferences: preferences)
        await pinnedItems.refresh(using: session.library)
    }
}
