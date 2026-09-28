import SwiftUI

/// Top-level navigation destinations, shared between the macOS/iPadOS sidebar
/// and the iPhone tab bar.
enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case albums
    case artists
    case songs
    case playlists
    /// The playlists AudioMuse-AI generates, where a tap plays the station
    /// rather than opening it. Only offered while the feature is switched on —
    /// see ``libraryGroup(showingAIRadio:)``.
    case aiRadio
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
        case .aiRadio: return "AI Radio"
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
        case .aiRadio: return "radio"
        case .downloads: return "arrow.down.circle"
        case .favorites: return "heart"
        case .search: return "magnifyingglass"
        }
    }

    /// Sections shown in the sidebar's main library group. Downloads and favourites gets
    /// their own top-level tabs rather than living here.
    static let libraryGroup: [LibrarySection] = [.albums, .artists, .songs, .playlists]

    /// ``libraryGroup`` with AI Radio appended when the user has switched it on.
    ///
    /// A section nobody can fill is worse than no section: with the feature off
    /// there are no stations to show, so the destination is not offered at all.
    static func libraryGroup(showingAIRadio: Bool) -> [LibrarySection] {
        showingAIRadio ? libraryGroup + [.aiRadio] : libraryGroup
    }
}
