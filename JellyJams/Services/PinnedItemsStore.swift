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
/// it next asks. Nothing is ever removed automatically: one server answer is
/// not trusted with a deletion, because scans in progress, slow syncs and
/// proxy trouble all make a response temporarily incomplete. ``refresh(using:)``
/// resolves every pin in one request and marks the ones the answer no longer
/// carries as missing; the user decides their fate, prompted whenever a tap
/// tries one and finds it gone (``use(_:using:)``). A request that fails
/// changes nothing, because "the server didn't answer" is not "the item is
/// gone".
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

    /// A pin together with the server's last word on it, ready to show.
    struct Entry: Identifiable {
        /// How the server currently sees the pin.
        enum State {
            /// The item the pin names, as the server has it right now.
            case resolved(BaseItemDto)
            /// A successful server answer no longer carries this item: what
            /// the user pinned is gone. The pin stays until the user removes
            /// it, and asking again may find the item back.
            case missing
            /// The server has not had a successful say — never refreshed, or
            /// the last refresh failed. Rendered from the pin's stored name
            /// alone.
            case unresolved
        }

        var pin: PinnedItem
        var state: State

        var id: String { pin.itemId }
    }

    /// The result of trying to use a pin the user tapped.
    enum UseOutcome {
        /// The item the pin points at, as the server has it right now.
        case resolved(BaseItemDto)
        /// A successful server answer no longer carries the item.
        case missing
        /// The request failed; the message is ready to present.
        case unavailable(String)
        /// The request was cancelled; there is nothing to report.
        case cancelled
    }

    @Published private(set) var pins: [PinnedItem] = []
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// The pin a tap is currently resolving, if any, so its tile can show it.
    @Published private(set) var resolvingPinId: String?

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
    /// The pins come back as unresolved entries, shown from their stored names
    /// until the next refresh resolves them.
    func configure(accountKey: String?) {
        guard accountKey != self.accountKey else { return }
        self.accountKey = accountKey
        pins = accountKey.flatMap { stored[$0] } ?? []
        entries = pins.map { Entry(pin: $0, state: .unresolved) }
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
        entries.append(Entry(pin: pin, state: .resolved(item)))
        persist()
        return true
    }

    func unpin(_ item: BaseItemDto) {
        guard let id = item.id else { return }
        unpin(id: id)
    }

    /// Removes a pin by itself — the path for a pin whose item the server can
    /// no longer produce to pass to the item-taking overload.
    func unpin(_ pin: PinnedItem) {
        unpin(id: pin.itemId)
    }

    private func unpin(id: String) {
        pins.removeAll { $0.itemId == id }
        entries.removeAll { $0.pin.itemId == id }
        persist()
    }

    /// Resolves every pin against the server in one request, upgrading the
    /// entries with fresh items and marking pins the answer no longer carries
    /// as missing — not removing them. A failed request changes nothing and
    /// reports its error.
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

    /// Tries a pin the user tapped, whatever its current state: resolves it
    /// against the server now and reports what happened, so the caller can
    /// open the item or offer to remove the pin. The pin is marked missing
    /// when the answer no longer carries it but kept either way — asking
    /// again on the next tap means a deleted item that reappears finds its
    /// pin alive, and nothing but the user's confirmation ever deletes one.
    func use(_ entry: Entry, using library: LibraryRepository) async -> UseOutcome {
        let pin = entry.pin
        resolvingPinId = pin.itemId
        defer { resolvingPinId = nil }
        do {
            let items = try await library.items(withIds: [pin.itemId])
            guard let item = items.first(where: { $0.id == pin.itemId }),
                  item.itemType == pin.kind.itemType else {
                set(state: .missing, for: pin)
                return .missing
            }
            set(state: .resolved(item), for: pin)
            return .resolved(item)
        } catch {
            // Cancellation is a view going away, not a failure to report.
            if error.isCancellation { return .cancelled }
            return .unavailable(error.userFacingMessage)
        }
    }

    /// Rebuilds entries from what the server returned. A pin the answer no
    /// longer carries — or answers with a different kind of item for, which
    /// is just as gone — is marked missing, not removed.
    private func apply(_ resolved: [BaseItemDto]) {
        let byId = Dictionary(
            resolved.compactMap { item -> (String, BaseItemDto)? in
                guard let id = item.id else { return nil }
                return (id, item)
            },
            uniquingKeysWith: { first, _ in first }
        )
        entries = pins.map { pin in
            if let item = byId[pin.itemId], item.itemType == pin.kind.itemType {
                Entry(pin: pin, state: .resolved(item))
            } else {
                Entry(pin: pin, state: .missing)
            }
        }
    }

    /// Replaces one entry in place, keeping its place in the pin order.
    private func set(state: Entry.State, for pin: PinnedItem) {
        guard let index = entries.firstIndex(where: { $0.pin.itemId == pin.itemId }) else { return }
        entries[index] = Entry(pin: pin, state: state)
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
