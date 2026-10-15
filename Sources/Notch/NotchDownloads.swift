import Foundation
import os

/// A finished download the closed notch drops a row for: the file, the site it came from and whether macOS
/// quarantined it, so Gatekeeper checks it on first open.
struct NotchDownload: Equatable {
    let url: URL
    let host: String?
    let quarantined: Bool

    var name: String { url.lastPathComponent }

    /// "github.com · quarantined", the row's second line.
    var detail: String {
        [host, quarantined ? "quarantined" : "not quarantined"].compactMap { $0 }.joined(separator: " · ")
    }

    /// The site a download came from, from its `kMDItemWhereFroms` list: the page that linked it (second) when there
    /// is one, else the file's own address, without `www.`.
    static func host(whereFroms: [String]) -> String? {
        let hosts = whereFroms.compactMap { URL(string: $0) }.filter { ["http", "https"].contains($0.scheme) }.compactMap(\.host)
        guard let host = hosts.count > 1 ? hosts[1] : hosts.first else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Picks finished downloads out of successive listings of the Downloads folder, each name with its file's inode. The
/// folder's contents at start are a baseline. Browsers write to a partial file and
/// rename it when done: Chrome `paper.pdf.crdownload`, Safari a `paper.pdf.download` bundle, Firefox and Zen
/// `paper.ABCDEFGH.pdf.part` (a random eight-character salt) beside an empty placeholder `paper.pdf`. A name counts
/// once no partial file of it is left and its file is not the one last seen under that name: a new name, or a new
/// file renamed over an old one, even between two listings. A cancelled download leaves the old file, which does not
/// count again. A name that leaves the folder is forgotten.
struct NotchDownloadScan {
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
    /// The inode of each finished name as last seen.
    private var seen: [String: UInt64]

    /// Files still downloading at the start count when they finish, since the finished file is a new one.
    init(baseline: [String: UInt64]) { seen = baseline }

    /// Names in `listing` that are new finished downloads, sorted.
    mutating func update(_ listing: [String: UInt64]) -> [String] {
        let downloading = Self.downloading(in: Array(listing.keys))
        var finished: [String] = []
        for (name, inode) in listing where !name.hasPrefix(".") && !Self.isPartial(name) && !downloading.contains(name) {
            if seen[name] != inode {
                seen[name] = inode
                finished.append(name)
            }
        }
        seen = seen.filter { listing[$0.key] != nil }
        return finished.sorted()
    }

    static func isPartial(_ name: String) -> Bool {
        partialExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The final names partial files in `listing` will become: the name without its partial extension. A Firefox
    /// `.part` whose name is not there itself may carry a salt, an eight-character part of letters and digits with
    /// at least one letter, so a date such as `20261010` is never taken for one; the name without it counts too.
    static func downloading(in listing: [String]) -> Set<String> {
        let present = Set(listing)
        var names: Set<String> = []
        for partial in listing where isPartial(partial) {
            let base = (partial as NSString).deletingPathExtension
            names.insert(base)
            guard (partial as NSString).pathExtension.lowercased() == "part", !present.contains(base) else { continue }
            let parts = base.split(separator: ".", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() where index > 0 && isSalt(part) {
                var unsalted = parts
                unsalted.remove(at: index)
                names.insert(unsalted.joined(separator: "."))
            }
        }
        return names
    }

    private static func isSalt(_ part: Substring) -> Bool {
        part.count == 8 && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && part.contains(where: \.isLetter)
    }
}

/// Reports finished downloads in `~/Downloads` while download alerts are on, with no polling: a vnode source on the
/// folder, as `NotchScreenshots` watches its own. Only files that came from somewhere count, those carrying a
/// quarantine or a `kMDItemWhereFroms` mark; a file without them, put there by hand, does not, nor does a copy of
/// an older download, whose quarantine is more than `freshness` old. A browser may set
/// the marks just after the rename, so a new file waits up to `markWait` for them. Reading the folder needs the
/// Downloads folder permission, which macOS asks for the first time; without it the listing fails and nothing is
/// reported.
@MainActor
final class NotchDownloads: ObservableObject {
    var onDownload: ((NotchDownload) -> Void)?
    /// Whether the last listing worked; false once macOS refused the folder.
    @Published private(set) var readable = true
    private let folder: URL
    private var scan = NotchDownloadScan(baseline: [:])
    private var folderSource: DispatchSourceFileSystemObject?
    /// New files waiting for their marks, each with a token, so a late event or timeout of an earlier file of the
    /// same name leaves a newer one alone.
    private var pending: [URL: (token: UUID, source: DispatchSourceFileSystemObject?)] = [:]
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "downloads")

    private static let markWait: Double = 3
    /// A quarantine older than this marks a copy of an old download, not a new one.
    static let freshness: TimeInterval = 6 * 3600
    /// System Settings' Privacy & Security > Files and Folders.
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    /// Checks pass a scratch folder.
    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    var running: Bool { folderSource != nil }

    func start() {
        guard folderSource == nil else { return }
        let listing = list()
        readable = listing != nil
        scan = NotchDownloadScan(baseline: listing ?? [:])
        folderSource = watch(folder.path) { [weak self] _ in self?.rescan() }
        log.notice("Watching \(self.folder.path, privacy: .public): readable \(listing != nil)")
    }

    func stop() {
        folderSource?.cancel()
        folderSource = nil
        pending.values.forEach { $0.source?.cancel() }
        pending.removeAll()
    }

    /// Starts over, as after the folder permission was granted: the watch may not have opened before.
    func restart() {
        stop()
        start()
    }

    /// Lists the folder again; also called by checks.
    func rescan() {
        let listing = list()
        readable = listing != nil
        guard let listing else { return }
        for name in scan.update(listing) { confirm(folder.appending(path: name)) }
    }

    /// The folder's names with their inodes; nil when macOS refuses the folder.
    private func list() -> [String: UInt64]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        var listing: [String: UInt64] = [:]
        for name in names { listing[name] = Self.inode(folder.appending(path: name)) }
        return listing
    }

    /// Reports the file once it carries a mark; marks arrive as attribute changes. The file is watched before the
    /// marks are read, so one set between the two still arrives as an event.
    /// The watch follows the file it opened: once that file is deleted or renamed, whatever later takes its name is
    /// another file, which the folder's own scan handles.
    private func confirm(_ url: URL) {
        forget(url)
        let token = UUID()
        let inode = Self.inode(url)
        let source = watch(url.path) { [weak self] events in
            guard let self, self.pending[url]?.token == token else { return }
            if !events.isDisjoint(with: [.delete, .rename]) || Self.inode(url) != inode {
                self.forget(url)
            } else if let download = Self.download(at: url) {
                self.forget(url)
                self.report(download)
            }
        }
        pending[url] = (token, source)
        if let download = Self.download(at: url) {
            forget(url)
            return report(download)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.markWait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending[url]?.token == token else { return }
                self.forget(url)
            }
        }
    }

    private static func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// Reports a download unless a new download of the same name started meanwhile; its end reports it then.
    private func report(_ download: NotchDownload) {
        if let listing = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
           NotchDownloadScan.downloading(in: listing).contains(download.name) { return }
        log.notice("Download \(download.name, privacy: .public) from \(download.host ?? "unknown", privacy: .public)")
        onDownload?(download)
    }

    private func forget(_ url: URL) {
        pending.removeValue(forKey: url)?.source?.cancel()
    }

    /// The download at `url`, or nil while it carries neither mark or is a copy of an old download.
    static func download(at url: URL, now: Date = .now) -> NotchDownload? {
        let quarantine = attribute("com.apple.quarantine", at: url).map { String(decoding: $0, as: UTF8.self) }
        if let quarantine, !fresh(quarantine: quarantine, now: now) { return nil }
        let whereFroms = attribute("com.apple.metadata:kMDItemWhereFroms", at: url)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String] }
        guard quarantine != nil || whereFroms != nil else { return nil }
        return NotchDownload(url: url, host: whereFroms.flatMap(NotchDownload.host), quarantined: quarantine != nil)
    }

    /// Whether a quarantine (`flags;hex seconds since 1970;agent;id`) was set within `freshness`; one without a
    /// readable time counts as fresh.
    static func fresh(quarantine: String, now: Date) -> Bool {
        let fields = quarantine.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count > 1, let seconds = UInt64(fields[1], radix: 16) else { return true }
        return now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(seconds))) < freshness
    }

    private static func attribute(_ name: String, at url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
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
