import SwiftUI

/// Top-level navigation destinations, shared between the macOS/iPadOS sidebar
/// and the iPhone tab bar.
enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case albums
    case artists
    case songs
    case playlists
    case downloads
    case favorites
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        case .playlists: return "Playlists"
        case .downloads: return "Downloads"
        case .favorites: return "Favourites"
        case .search: return "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .albums: return "record.circle.fill"
        case .artists: return "music.mic"
        case .songs: return "music.note"
        case .playlists: return "music.note.list"
        case .downloads: return "arrow.down.circle"
        case .favorites: return "heart"
        case .search: return "magnifyingglass"
        }
    }

    /// Sections shown in the sidebar's main library group. Downloads and favourites gets
    /// their own top-level tabs rather than living here.
    static let libraryGroup: [LibrarySection] = [.albums, .artists, .songs, .playlists]
}
