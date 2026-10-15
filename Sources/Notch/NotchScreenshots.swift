import Foundation
import os

/// The screenshot peeking out of the closed notch, if any, and how it leaves: replaced by a newer one, expired,
/// taken by Open, Shelf or a drag that delivers it, or dismissed. Timing and drawing belong to the experience and view.
struct NotchScreenshotThumbnail: Equatable {
    /// Seconds the peek stays after it appears or the pointer leaves it.
    static let duration: Double = 1.5
    private(set) var url: URL?

    /// A newer screenshot replaces the one shown.
    mutating func show(_ url: URL) { self.url = url }

    /// The timeout of `url` ends only that screenshot, so a late timer cannot remove a newer one.
    mutating func expire(_ url: URL) {
        if self.url == url { self.url = nil }
    }

    /// Open, Shelf or a delivered drag takes the screenshot out of the notch; nil when none is shown.
    mutating func take() -> URL? {
        defer { url = nil }
        return url
    }

    mutating func dismiss() { url = nil }
}

/// Picks the new images out of successive listings of the screenshot folder. Every name seen is remembered, so a
/// capture is reported once and the folder's contents at start are a baseline, not news. macOS writes a capture
/// as `..name-XXXXXX`, renames it to `.name` and then to `name`, so hidden names are never finished files.
struct NotchScreenshotScan {
    /// Image types `screencapture` writes; screen recordings (`.mov`) are left out.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "pdf", "tiff", "tif", "gif", "bmp"]
    private var seen: Set<String>

    init(baseline: [String]) { seen = Set(baseline) }

    /// Names in `listing` that are new finished images, sorted.
    mutating func update(_ listing: [String]) -> [String] {
        defer { seen.formUnion(listing) }
        return listing.filter { !seen.contains($0) && Self.isImage($0) }.sorted()
    }

    static func isImage(_ name: String) -> Bool {
        !name.hasPrefix(".") && imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// Reports new screenshots in the folder macOS saves them to, with no polling. A vnode source on the folder fires
/// within milliseconds of a change and each event diffs one listing; the same mechanism as `NotchFocus`. An
/// FSEvents stream would add a C callback for nothing (only the top level matters), and an `NSMetadataQuery` on
/// `kMDItemIsScreenCapture` depends on Spotlight indexing the folder and lags by seconds. A new image counts once it
/// carries the screen capture mark (`com.apple.metadata:kMDItemIsScreenCapture`), which macOS sets about 2 ms after
/// the final rename, so images other apps save there are ignored; a copied screenshot keeps the mark and counts.
/// With the floating thumbnail on, macOS saves the file only when the thumbnail goes away, about 6 s later, and
/// nothing appears if the user drags the thumbnail elsewhere first; `systemThumbnail` turns it off. The location comes from the screencapture
/// preferences; their file is watched too, so a new location applies without a restart. A location in `~/Desktop`,
/// `~/Documents` or `~/Downloads` needs that folder's permission or Full Disk Access; without it the listing fails,
/// nothing is reported and the log says `readable false`.
@MainActor
final class NotchScreenshots {
    /// Called once per new screenshot, with its final URL.
    var onCapture: ((URL) -> Void)?
    /// The watched folder while running.
    private(set) var folder: URL?
    private var scan = NotchScreenshotScan(baseline: [])
    private var folderSource: DispatchSourceFileSystemObject?
    private var preferencesSource: DispatchSourceFileSystemObject?
    /// New images waiting for the screen capture mark.
    private var pending: [URL: DispatchSourceFileSystemObject] = [:]
    /// Set for checks: watches this folder and ignores the preferences.
    private let fixedFolder: URL?
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "screenshots")

    static let domain = "com.apple.screencapture"
    /// macOS 27 reads only `location-screenshot`: with it absent, captures land on the Desktop whatever `location`
    /// says (checked 3 October 2026). Older systems read `location`, not verified here.
    static let locationKeys = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        ? ["location-screenshot"] : ["location-screenshot", "location"]
    private static let thumbnailKey = "show-thumbnail" as CFString

    /// macOS's floating thumbnail in the bottom right corner after a capture; on while the key is absent. Off, the
    /// file is saved at once (0.2 s against 6 s with the shortcut, 3 October 2026), so the notch shows it instead.
    /// The next capture applies a change with no restart. The Options menu of ⌘⇧5 writes the same key. On removes
    /// the key, which restores the macOS default.
    static var systemThumbnail: Bool {
        get {
            CFPreferencesAppSynchronize(domain as CFString)
            return CFPreferencesCopyAppValue(thumbnailKey, domain as CFString) as? Bool ?? true
        }
        set {
            CFPreferencesSetAppValue(thumbnailKey, newValue ? nil : kCFBooleanFalse, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
        }
    }
    /// Seconds a new image may wait for the screen capture mark before it is taken for an ordinary file.
    private static let markWait: Double = 2
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let preferences = home.appending(path: "Library/Preferences")

    init(folder: URL? = nil) { fixedFolder = folder }

    func start() {
        guard folder == nil else { return }
        if fixedFolder == nil { watchPreferences() }
        relocate()
    }

    func stop() {
        preferencesSource?.cancel()
        preferencesSource = nil
        unwatchFolder()
        folder = nil
    }

    /// The folder new screenshots are saved to now.
    static func currentFolder() -> URL {
        CFPreferencesAppSynchronize(domain as CFString)
        let location = locationKeys.lazy.compactMap { CFPreferencesCopyAppValue($0 as CFString, domain as CFString) as? String }.first
        return folder(location: location, home: home) { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
    }

    /// Expands `~` and falls back to the Desktop, as macOS does, when the location is absent, relative or not a folder.
    static func folder(location: String?, home: URL, isDirectory: (URL) -> Bool) -> URL {
        let desktop = home.appending(path: "Desktop")
        guard let location else { return desktop }
        let url: URL
        if location == "~" || location.hasPrefix("~/") {
            url = home.appending(path: String(location.dropFirst(2)))
        } else if location.hasPrefix("/") {
            url = URL(fileURLWithPath: location)
        } else {
            return desktop
        }
        return isDirectory(url) ? url.standardizedFileURL : desktop
    }

    /// cfprefsd replaces the preferences file on every write, so each event reopens it. Until the file exists,
    /// which it does not before the first screenshot setting changes, the Preferences folder is watched instead.
    private func watchPreferences() {
        let file = Self.preferences.appending(path: Self.domain + ".plist")
        let path = FileManager.default.fileExists(atPath: file.path) ? file.path : Self.preferences.path
        preferencesSource = watch(path) { [weak self] _ in
            guard let self, self.folder != nil else { return }
            self.preferencesSource?.cancel()
            self.watchPreferences()
            self.relocate()
        }
    }

    /// Follows the location; a new folder starts from its current contents. `force` rewatches the same path after
    /// the folder itself was moved or deleted.
    private func relocate(force: Bool = false) {
        let current = fixedFolder ?? Self.currentFolder()
        guard force || current != folder else { return }
        unwatchFolder()
        folder = current
        let listing = try? FileManager.default.contentsOfDirectory(atPath: current.path)
        scan = NotchScreenshotScan(baseline: listing ?? [])
        folderSource = watch(current.path) { [weak self] events in
            guard let self else { return }
            if !events.isDisjoint(with: [.delete, .rename]) { self.relocate(force: true) } else { self.rescan() }
        }
        log.notice("Watching \(current.path, privacy: .public): readable \(listing != nil), \(listing?.count ?? 0) entries")
    }

    private func rescan() {
        guard let folder, let listing = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in scan.update(listing) { confirm(folder.appending(path: name)) }
    }

    /// Reports the image once it carries the screen capture mark; the mark arrives as an attribute change. The file
    /// is watched before the mark is read, so a mark set between the two still arrives as an event.
    private func confirm(_ url: URL) {
        pending[url] = watch(url.path) { [weak self] events in
            guard let self else { return }
            if Self.isScreenCapture(url) {
                self.forget(url)
                self.report(url)
            } else if !events.isDisjoint(with: [.delete, .rename]) {
                self.forget(url)
            }
        }
        if Self.isScreenCapture(url) {
            forget(url)
            return report(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.markWait) { [weak self] in
            MainActor.assumeIsolated { self?.forget(url) }
        }
    }

    private func report(_ url: URL) {
        log.notice("Screenshot \(url.lastPathComponent, privacy: .public)")
        onCapture?(url)
    }

    private func forget(_ url: URL) {
        pending.removeValue(forKey: url)?.cancel()
    }

    private func unwatchFolder() {
        folderSource?.cancel()
        folderSource = nil
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }

    private static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }

    /// A vnode source on `path` that hands each batch of events to `handler` on the main queue.
    private func watch(_ path: String, handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete, .attrib],
                                                               queue: .main)
        source.setEventHandler { [weak source] in
            guard let events = source?.data else { return }
            MainActor.assumeIsolated { handler(events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
