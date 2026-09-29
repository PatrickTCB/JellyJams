import Foundation

/// The items the user has pinned to the home screen.
///
/// Pins outlive a session and are persisted to `UserDefaults`, keyed by the
/// account they belong to: an id only means something on the server that
/// issued it, so switching servers must not resolve one server's pins against
/// another's library.
///
/// A pinned item can disappear at any time — the user deletes an album,
/// playlist or artist on the Jellyfin server and this app finds out only when
/// it next asks. ``refresh(using:)`` resolves every pin in one request and
/// prunes the ones the server no longer knows; a request that fails prunes
/// nothing, because "the server didn't answer" is not "the item is gone".
@MainActor
final class PinnedItemsStore: ObservableObject {
    /// How many items can be pinned at once.
    static let maxPins = 5

    /// The kinds of item that can be pinned.
    enum Kind: String, Codable, Sendable {
        case album
        case artist
        case playlist

        init?(itemType: ItemType?) {
            switch itemType {
            case .musicAlbum: self = .album
            case .musicArtist: self = .artist
            case .playlist: self = .playlist
            default: return nil
            }
        }

        var itemType: ItemType {
            switch self {
            case .album: .musicAlbum
            case .artist: .musicArtist
            case .playlist: .playlist
            }
        }
    }

    /// A pin as stored: enough to identify the item and to show a fallback,
    /// without carrying a stale copy of its metadata.
    struct PinnedItem: Codable, Identifiable, Hashable, Sendable {
        var itemId: String
        var name: String
        var kind: Kind

        var id: String { itemId }
    }

    /// A pin together with the item the server returned for it, ready to show.
    struct Entry: Identifiable {
        var pin: PinnedItem
        var item: BaseItemDto

        var id: String { pin.itemId }
    }

    @Published private(set) var pins: [PinnedItem] = []
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private enum Key {
        static let storage = "jellyjams.pinnedItems"
    }

    private let defaults: UserDefaults
    /// Every account's pins, as persisted. Only the active account's slice is
    /// published; the rest is kept so signing back in restores it.
    private var stored: [String: [PinnedItem]] = [:]
    private var accountKey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = defaults.data(forKey: Key.storage).flatMap {
            try? JSONDecoder().decode([String: [PinnedItem]].self, from: $0)
        } ?? [:]
    }

    /// Points the store at an account, publishing that account's pins. Pass
    /// `nil` on sign-out; nothing is deleted, so signing back in restores it.
    func configure(accountKey: String?) {
        guard accountKey != self.accountKey else { return }
        self.accountKey = accountKey
        pins = accountKey.flatMap { stored[$0] } ?? []
        entries = []
        errorMessage = nil
        isLoading = false
    }

    var isFull: Bool { pins.count >= Self.maxPins }

    func contains(_ item: BaseItemDto) -> Bool {
        guard let id = item.id else { return false }
        return pins.contains { $0.itemId == id }
    }

    /// The pin kind for an item, or nil for a kind that cannot be pinned.
    func kind(for item: BaseItemDto) -> Kind? {
        Kind(itemType: item.itemType)
    }

    /// Pins an item and publishes it immediately, before the server has
    /// confirmed anything. Refuses when the list is full, when the item has no
    /// id, and when it is already pinned.
    @discardableResult
    func pin(_ item: BaseItemDto, kind: Kind) -> Bool {
        guard let id = item.id, !isFull else { return false }
        guard !pins.contains(where: { $0.itemId == id }) else { return false }
        let pin = PinnedItem(itemId: id, name: item.displayName, kind: kind)
        pins.append(pin)
        entries.append(Entry(pin: pin, item: item))
        persist()
        return true
    }

    func unpin(_ item: BaseItemDto) {
        guard let id = item.id else { return }
        pins.removeAll { $0.itemId == id }
        entries.removeAll { $0.pin.itemId == id }
        persist()
    }

    /// Resolves every pin against the server in one request, replacing the
    /// optimistic copies with fresh items and dropping pins the server no
    /// longer has. A failed request changes nothing and reports its error.
    func refresh(using library: LibraryRepository) async {
        guard !pins.isEmpty else {
            entries = []
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let resolved = try await library.items(withIds: pins.map(\.itemId))
            apply(resolved)
        } catch {
            // Cancellation is a view going away, not a failure to report.
            if !error.isCancellation {
                errorMessage = error.userFacingMessage
            }
        }
    }

    /// Rebuilds entries from what the server returned and prunes pins that
    /// came back missing or as a different kind of item — either way, the pin
    /// no longer points at what the user pinned.
    private func apply(_ resolved: [BaseItemDto]) {
        let byId = Dictionary(
            resolved.compactMap { item -> (String, BaseItemDto)? in
                guard let id = item.id else { return nil }
                return (id, item)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let kept = pins.filter { pin in
            byId[pin.itemId]?.itemType == pin.kind.itemType
        }
        if kept.count != pins.count {
            pins = kept
            persist()
        }
        entries = kept.compactMap { pin in
            byId[pin.itemId].map { Entry(pin: pin, item: $0) }
        }
    }

    private func persist() {
        guard let accountKey else { return }
        if pins.isEmpty {
            stored.removeValue(forKey: accountKey)
        } else {
            stored[accountKey] = pins
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Key.storage)
    }
}