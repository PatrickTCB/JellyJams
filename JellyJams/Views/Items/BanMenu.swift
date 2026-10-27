import SwiftUI

/// The context menus' "Ban" submenu — how a user tells the Jelly Jams
/// Backend to keep something out of the playlists it generates. It mirrors
/// "Add to Playlist": one drop-down whose options name what each would ban,
/// built from the item the menu belongs to. A song offers the song, its
/// album, and each of its artists; an album offers itself and its
/// album-artists; an artist offers itself. Nothing else — playlists, genres
/// and the rest — has anything here to ban.
///
/// The submenu renders nothing while the backend cannot take bans
/// (``BanStore/canBan``) and nothing while browsing downloads — the same
/// standing-down the Instant Mix observes.
struct BanMenu: View {
    let item: BaseItemDto
    /// The songs a "ban song" choice covers when the menu belongs to a
    /// multi-selection — acting on one selected row acts on all, the rule
    /// every other row action follows. Nil bans `item` alone. Album and
    /// artist options stay the tapped row's, whatever the selection — as
    /// with its navigation buttons.
    var selectedSongIds: [String]?

    @EnvironmentObject private var bans: BanStore
    @Environment(\.offlineBrowsing) private var offlineBrowsing

    var body: some View {
        let options = Self.banOptions(for: item, selectedSongIds: selectedSongIds)
        if bans.canBan && !offlineBrowsing && !options.isEmpty {
            Menu {
                ForEach(options) { option in
                    Button(option.label) { send(option) }
                }
            } label: {
                Label("Ban", systemImage: "nosign")
            }
        }
    }

    private func send(_ option: Option) {
        // Unstructured so the request outlives a context menu that dismisses
        // the moment its button is chosen.
        Task {
            do {
                try await bans.ban(itemIds: option.itemIds)
            } catch where !error.isCancellation {
                // The root-hosted alert, as with the menu's other actions:
                // the failure lands after the menu has gone.
                bans.presentActionError(error.userFacingMessage)
            } catch {}
        }
    }
}

extension BanMenu {
    /// One choice in the submenu: the label it is offered under, and the
    /// item ids that go to the backend when it is taken.
    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
        let itemIds: [String]
    }

    /// Maps an item to the ban choices it offers. Kept free of the view so
    /// the mapping — the whole menu logic — can be tested as itself.
    static func banOptions(for item: BaseItemDto, selectedSongIds: [String]? = nil) -> [Option] {
        var options: [Option] = []
        switch item.itemType {
        case .audio:
            let songIds = selectedSongIds ?? item.id.map { [$0] } ?? []
            if !songIds.isEmpty {
                options.append(Option(
                    id: "songs",
                    label: songIds.count == 1
                        ? "Ban song: “\(item.displayName)”"
                        : "Ban \(Format.songCount(songIds.count))",
                    itemIds: songIds
                ))
            }
            if let album = item.albumNavigationItem, let albumId = album.id {
                options.append(Option(
                    id: "album",
                    label: "Ban album: “\(album.displayName)”",
                    itemIds: [albumId]
                ))
            }
            appendArtistOptions(of: item, to: &options)
        case .musicAlbum:
            if let albumId = item.id {
                options.append(Option(
                    id: "album",
                    label: "Ban album: “\(item.displayName)”",
                    itemIds: [albumId]
                ))
            }
            appendArtistOptions(of: item, to: &options)
        case .musicArtist:
            if let artistId = item.id {
                options.append(Option(
                    id: "artist-\(artistId)",
                    label: "Ban artist: “\(item.displayName)”",
                    itemIds: [artistId]
                ))
            }
        default:
            break
        }
        return options
    }

    /// One choice per artist the item credits — a song's track artists, an
    /// album's album-artists (see ``BaseItemDto/artistNavigationItems``),
    /// artists without an id already dropped and repeats already collapsed.
    private static func appendArtistOptions(of item: BaseItemDto, to options: inout [Option]) {
        for artist in item.artistNavigationItems {
            guard let artistId = artist.id else { continue }
            options.append(Option(
                id: "artist-\(artistId)",
                label: "Ban artist: “\(artist.displayName)”",
                itemIds: [artistId]
            ))
        }
    }
}
