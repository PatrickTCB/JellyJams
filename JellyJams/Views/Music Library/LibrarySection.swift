import SwiftUI

/// Top-level navigation destinations, shared between the macOS/iPadOS sidebar
/// and the iPhone tab bar.
enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case albums
    case artists
    case songs
    case playlists
    case favorites
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        case .playlists: return "Playlists"
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
        case .favorites: return "heart"
        case .search: return "magnifyingglass"
        }
    }

    /// Sections shown in the sidebar's main library group.
    static let libraryGroup: [LibrarySection] = [.albums, .artists, .songs, .playlists]
}
