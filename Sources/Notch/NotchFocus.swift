import AppKit
import Combine
import os

/// A Focus mode as macOS describes it: the name, SF Symbol and tint the user sees in Control Center.
struct NotchFocusMode: Equatable {
    let identifier: String
    let name: String
    let symbol: String
    let tintName: String?

    var tint: NSColor? { tintName.flatMap(NotchFocusMode.color) }

    /// Apple's own modes, used when the configuration file does not describe one or names a symbol macOS
    /// cannot draw. Work's own `person.lanyardcard.fill` is private on macOS, so its public twin stands in.
    static let builtIn: [String: (name: String, symbol: String)] = [
        "com.apple.donotdisturb.mode.default": ("Do Not Disturb", "moon.fill"),
        "com.apple.sleep.sleep-mode": ("Sleep", "bed.double.fill"),
        "com.apple.focus.work": ("Work", "lanyardcard.fill"),
        "com.apple.focus.personal-time": ("Personal", "person.fill"),
        "com.apple.focus.reading": ("Reading", "book.fill"),
        "com.apple.focus.gaming": ("Gaming", "gamecontroller.fill"),
        "com.apple.focus.mindfulness": ("Mindfulness", "leaf.fill"),
        "com.apple.focus.reduce-interruptions": ("Reduce Interruptions", "hourglass"),
        "com.apple.donotdisturb.mode.driving": ("Driving", "car.fill"),
        "com.apple.donotdisturb.mode.workout": ("Fitness", "figure.run"),
    ]

    /// Maps the stored tint name, such as `systemIndigo` or `systemIndigoColor`, to the system colour.
    static func color(named name: String) -> NSColor? {
        var key = name.hasPrefix("system") ? String(name.dropFirst(6)) : name
        if key.hasSuffix("Color") { key.removeLast(5) }
        switch key.lowercased() {
        case "indigo": return .systemIndigo
        case "purple": return .systemPurple
        case "blue": return .systemBlue
        case "teal": return .systemTeal
        case "cyan": return .systemCyan
        case "mint": return .systemMint
        case "green": return .systemGreen
        case "yellow": return .systemYellow
        case "orange": return .systemOrange
        case "red": return .systemRed
        case "pink": return .systemPink
        case "brown": return .systemBrown
        case "gray", "grey": return .systemGray
        default: return nil
        }
    }
}

/// One Focus change: the mode that turned on or off. The wings show this; it says nothing about what else
/// stays asserted, so the settings page and the probe read `active` instead.
struct NotchFocusChange: Equatable {
    let mode: NotchFocusMode
    let on: Bool
}

/// Reads the active Focus from `~/Library/DoNotDisturb/DB`, where macOS keeps it, and watches that directory.
/// Those files are protected: without Full Disk Access the open fails silently and `accessible` stays false.
/// Several assertions can be live at once (a scheduled Sleep under a manual Do Not Disturb), so changes are
/// judged per mode: one appearing is On, one disappearing is Off, whatever else stays asserted.
@MainActor
final class NotchFocus: ObservableObject {
    /// Every asserted mode, in the system's file order: the active Focus.
    @Published private(set) var active: [NotchFocusMode] = []
    /// The last mode that turned on or off while running, nil until one does.
    @Published private(set) var change: NotchFocusChange?
    @Published private(set) var accessible = false
    /// Called after a change while running.
    var onChange: ((NotchFocusChange) -> Void)?
    private let directory: URL
    private var running = false
    private var sources: [DispatchSourceFileSystemObject] = []
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "focus")

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/DoNotDisturb/DB"),
         previewMode: NotchFocusMode? = nil) {
        self.directory = directory
        if let previewMode {
            active = [previewMode]
            change = NotchFocusChange(mode: previewMode, on: true)
        }
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    func start() {
        guard !running else { return }
        running = true
        // The baseline is read before the sources resume, so an event in between cannot diff against nothing.
        read(notify: false)
        watch()
        log.notice("Started: accessible \(self.accessible), watching \(self.sources.count) sources, modes \(self.active.map(\.identifier).joined(separator: " "), privacy: .public)")
    }

    func stop() {
        running = false
        unwatch()
    }

    /// Re-checks access, for after the user grants Full Disk Access while the app is running.
    func retry() {
        stop()
        start()
    }

    /// The directory reports replaced files; the assertion file itself reports in-place rewrites. Every event
    /// reopens both, so a file that appears or is replaced after start is watched too.
    private func watch() {
        let paths = [directory.path, directory.appending(path: "Assertions.json").path]
        for path in paths {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .rename, .delete, .extend, .attrib],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.unwatch()
                    self.watch()
                    self.read(notify: true)
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private func unwatch() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    /// Access is judged on the directory, so a missing assertion file reads as "no Focus" rather than "no access".
    private func read(notify: Bool) {
        guard running else { return }
        accessible = access(directory.path, R_OK) == 0
        guard accessible else { return }
        let assertions = try? Data(contentsOf: directory.appending(path: "Assertions.json"))
        let configurations = try? Data(contentsOf: directory.appending(path: "ModeConfigurations.json"))
        // A missing file means no assertion; an unreadable one (mid-rewrite) means keep what was known.
        let current: [NotchFocusMode]
        if let assertions {
            guard let parsed = Self.parse(assertions: assertions, configurations: configurations) else {
                log.notice("Read: assertions \(assertions.count) bytes unreadable, keeping \(self.active.count) modes")
                return
            }
            current = parsed
        } else {
            current = []
        }
        log.notice("Read: assertions \(assertions?.count ?? -1) bytes, configurations \(configurations?.count ?? -1) bytes, modes \(current.map(\.identifier).joined(separator: " "), privacy: .public), keys \(Self.topKeys(assertions), privacy: .public)")
        let previous = active
        active = current
        let added = current.filter { mode in !previous.contains { $0.identifier == mode.identifier } }
        let removed = previous.filter { mode in !current.contains { $0.identifier == mode.identifier } }
        guard notify else { return }
        // A mode coming on outranks one going off in the same update; otherwise the first one gone, in file
        // order, names the Off. Neither means only descriptions may have changed, so the shown one is refreshed.
        if let on = added.last {
            change = NotchFocusChange(mode: on, on: true)
        } else if let off = removed.first {
            change = NotchFocusChange(mode: off, on: false)
        } else {
            if let shown = change, let refreshed = current.first(where: { $0.identifier == shown.mode.identifier }) {
                change = NotchFocusChange(mode: refreshed, on: shown.on)
            }
            return
        }
        if let change { onChange?(change) }
    }

    /// Every asserted mode, in file order, each with its description, or nil when the data is not JSON. A symbol
    /// is kept only if this macOS can draw it, so the wing never shows an empty image. Only
    /// `storeAssertionRecords` holds live assertions; the invalidation records beside it keep every Focus that
    /// ended, mode identifier included, so they must not be read. Within those records both files are searched
    /// by key rather than by exact shape, so small changes in how macOS nests them do not break the read.
    static func parse(assertions: Data, configurations: Data?) -> [NotchFocusMode]? {
        guard let assertionTree = try? JSONSerialization.jsonObject(with: assertions) else { return nil }
        let configurationTree = configurations.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let live = allValues(forKey: "storeAssertionRecords", in: assertionTree)
        var seen = Set<String>()
        return live.flatMap { allStrings(forKey: "assertionDetailsModeIdentifier", in: $0) }.filter { seen.insert($0).inserted }.map { identifier in
            let description = configurationTree.flatMap { firstDictionary(where: { $0["modeIdentifier"] as? String == identifier }, in: $0) }
            let fallback = NotchFocusMode.builtIn[identifier]
            let symbol = [description?["symbolImageName"] as? String, fallback?.symbol].compactMap { $0 }
                .first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            return NotchFocusMode(identifier: identifier,
                                  name: description?["name"] as? String ?? fallback?.name ?? "Focus",
                                  symbol: symbol ?? "moon.fill",
                                  tintName: description?["tintColorName"] as? String)
        }
    }

    /// Top-level keys and the first record's keys, for the log when the file shape differs from what the parser expects.
    private static func topKeys(_ data: Data?) -> String {
        guard let data, let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "unreadable" }
        var keys = Array(tree.keys).sorted()
        if let records = (tree["data"] as? [[String: Any]])?.first { keys += records.keys.sorted().map { "data." + $0 } }
        return keys.joined(separator: " ")
    }

    private static func allStrings(forKey key: String, in tree: Any) -> [String] {
        allValues(forKey: key, in: tree).compactMap { $0 as? String }
    }

    /// Every value stored under `key` at any depth, outermost first; a match is not searched further.
    private static func allValues(forKey key: String, in tree: Any) -> [Any] {
        if let dictionary = tree as? [String: Any] {
            if let value = dictionary[key] { return [value] }
            return dictionary.values.flatMap { allValues(forKey: key, in: $0) }
        } else if let array = tree as? [Any] {
            return array.flatMap { allValues(forKey: key, in: $0) }
        }
        return []
    }

    private static func firstDictionary(where matches: ([String: Any]) -> Bool, in tree: Any) -> [String: Any]? {
        if let dictionary = tree as? [String: Any] {
            if matches(dictionary) { return dictionary }
            for value in dictionary.values { if let found = firstDictionary(where: matches, in: value) { return found } }
        } else if let array = tree as? [Any] {
            for value in array { if let found = firstDictionary(where: matches, in: value) { return found } }
        }
        return nil
    }
}
