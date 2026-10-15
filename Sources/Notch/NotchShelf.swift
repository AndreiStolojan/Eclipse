import AppKit

/// Files dropped on the notch, stored as bookmarks so originals are never copied or moved.
/// A bookmark follows its file through renames and moves; a deleted or trashed file leaves the shelf, as does one on
/// an unmounted volume, since its bookmark no longer resolves.
@MainActor
final class NotchShelf: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let bookmark: Data
        let url: URL

        var name: String { url.lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    private let defaults: UserDefaults
    private static let key = "shelfItems"

    /// `name` is no longer read; it stays so older builds can decode the list.
    private struct Stored: Codable {
        let id: UUID
        let name: String
        let bookmark: Data
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([Stored].self, from: $0) } ?? []
        items = stored.compactMap { Self.resolve(id: $0.id, bookmark: $0.bookmark) }
        if items.count != stored.count { save() }
    }

    /// Tiles per row on the Shelf page; more files than one row scroll, which a vertical swipe then leaves alone.
    static let columns = 5

    var urls: [URL] { items.map(\.url) }

    /// Appends files not already on the shelf, keeping drop order.
    func add(_ urls: [URL]) {
        refresh()
        var present = Set(self.urls.map(\.standardizedFileURL))
        for url in urls where present.insert(url.standardizedFileURL).inserted {
            guard let bookmark = try? url.bookmarkData() else { continue }
            items.append(Item(id: UUID(), bookmark: bookmark, url: url))
        }
        save()
    }

    func remove(_ id: Item.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        items = []
        save()
    }

    /// Re-resolves every bookmark: moved files follow, deleted and trashed ones leave the shelf. Runs on every open.
    func refresh() {
        let updated = items.compactMap { Self.resolve(id: $0.id, bookmark: $0.bookmark) }
        guard updated != items else { return }
        items = updated
        save()
    }

    /// The item at its file's current location, or nil once the file is deleted or in the Trash.
    private static func resolve(id: UUID, bookmark: Data) -> Item? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path), !url.pathComponents.contains(".Trash") else { return nil }
        return Item(id: id, bookmark: stale ? (try? url.bookmarkData()) ?? bookmark : bookmark, url: url)
    }

    private func save() {
        let stored = items.map { Stored(id: $0.id, name: $0.name, bookmark: $0.bookmark) }
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.key)
    }
}
