import AppKit
import ImageIO
import Quartz

/// Shows a thread's images in Quick Look, starting at the one clicked; the arrows go
/// through the rest. Quick Look needs a key window, so Eclipse comes forward while it shows and hands focus back to
/// the app that had it when it closes. The app delegate answers Quick Look's controller lookup through this object.
@MainActor
final class NotchQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = NotchQuickLook()

    private var urls: [URL] = []
    private var index = 0
    private var previous: NSRunningApplication?

    func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        self.index = min(max(index, 0), urls.count - 1)
        if !NSApp.isActive { previous = NSWorkspace.shared.frontmostApplication }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        panel.currentPreviewItemIndex = self.index
    }

    /// Called by the app delegate when Quick Look takes or gives up control.
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = index
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        urls = []
        // Back to where the user was typing, unless they already moved on to another app.
        if NSApp.isActive { previous?.activate() }
        previous = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}

/// Small thumbnails for the strip, read off the main thread and kept for the session. ImageIO decodes at the size
/// asked, so a 12 MP photo costs a thumbnail's memory.
enum NotchThumbnails {
    /// Keyed by path and modification date, so a file the agent overwrites gets a new thumbnail.
    private static let cache = NSCache<NSString, NSImage>()

    private static func key(_ url: URL) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
    }

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: key(url)) }

    static func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        return await Task.detached { loadNow(url) }.value
    }

    /// Decodes and caches at once; fixture rendering calls it so the thumbnails are there before the snapshot.
    @discardableResult
    static func loadNow(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: key(url))
        return image
    }
}
