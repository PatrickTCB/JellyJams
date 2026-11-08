import SwiftUI

/// Top-level navigation destinations, shared between the macOS/iPadOS sidebar
/// and the iPhone tab bar.
enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    /// The app's landing screen: pinned items, recent music and Mixtapes
    /// quick links. Not part of ``libraryGroup`` — it is the shell's own
    /// destination rather than one of the library's browsing sections.
    case home
    case albums
    case artists
    case songs
    case playlists
    /// The mixtapes the Jelly Jams Backend builds, where a tap plays the
    /// mixtape rather than opening it. Only offered while the app is
    /// registered with a backend — see ``libraryGroup(showingMixtapes:)``.
    case mixtapes
    case downloads
    case favorites
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        case .playlists: return "Playlists"
        case .mixtapes: return "Mixtapes"
        case .downloads: return "Downloads"
        case .favorites: return "Favourites"
        case .search: return "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .albums: return "record.circle.fill"
        case .artists: return "music.mic"
        case .songs: return "music.note"
        case .playlists: return "music.note.list"
        case .mixtapes: return "recordingtape.circle.fill"
        case .downloads: return "arrow.down.circle"
        case .favorites: return "heart"
        case .search: return "magnifyingglass"
        }
    }

    /// Sections shown in the sidebar's main library group. Downloads and favourites gets
    /// their own top-level tabs rather than living here.
    static let libraryGroup: [LibrarySection] = [.albums, .artists, .songs, .playlists]

    /// ``libraryGroup`` with Mixtapes appended when the app has a backend
    /// registration to work from.
    ///
    /// A section nobody can fill is worse than no section: with no
    /// registration there is no name rule to gather by, so the destination is
    /// not offered at all.
    static func libraryGroup(showingMixtapes: Bool) -> [LibrarySection] {
        showingMixtapes ? libraryGroup + [.mixtapes] : libraryGroup
    }
}
