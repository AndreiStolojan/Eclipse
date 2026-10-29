import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The screenshot peek: below the camera row, the new screenshot on the left,
/// its pixel size and the Shelf and Open buttons on the right. Clicking the thumbnail opens it like Open; dragging it
/// hands the file over, to the notch's own drop targets or to any other app.
struct NotchScreenshotPeek: View {
    let url: URL
    let experience: NotchExperience
    let topHeight: CGFloat
    @State private var preview: NotchImagePreview?
    @State private var loaded: Bool
    @State private var hovering = false

    init(url: URL, experience: NotchExperience, topHeight: CGFloat) {
        self.url = url
        self.experience = experience
        self.topHeight = topHeight
        let cached = NotchImagePreview.cached(url)
        _preview = State(initialValue: cached)
        _loaded = State(initialValue: cached != nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail.frame(maxWidth: 110, maxHeight: 71)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: preview.map { "\(Int($0.pixelSize.width)) × \(Int($0.pixelSize.height))" } ?? "")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.top, 4)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    button("tray", "Shelf", help: "Keep on the shelf", action: experience.shelveScreenshot)
                    button("arrow.up.forward.square", "Open", help: "Open \(url.lastPathComponent)",
                           action: experience.openScreenshot)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 71)
            // The labels never truncate; on narrow wings the thumbnail gives way instead.
            .layoutPriority(1)
        }
        .padding(.leading, 14).padding(.top, topHeight + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: url) {
            preview = NotchImagePreview.cached(url)
            loaded = preview != nil
            guard !loaded else { return }
            let made = await NotchImagePreview.load(url)
            // The decode runs detached and ignores cancellation, so a newer screenshot's preview may already be shown.
            guard !Task.isCancelled else { return }
            preview = made
            loaded = true
        }
    }

    /// The screenshot fitted into its slot with its own aspect ratio, the file icon for a capture ImageIO cannot read
    /// (a PDF), and nothing for the few milliseconds the preview takes. The drag source covers exactly the image.
    @ViewBuilder private var thumbnail: some View {
        if loaded {
            Group {
                if let preview {
                    Image(decorative: preview.image, scale: 1).resizable().interpolation(.high).scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 1.5).padding(-3).opacity(hovering ? 1 : 0))
            .overlay(NotchFileDragSource(url: url, image: preview?.image, dropsOnNotch: true,
                                         click: experience.openScreenshot, onDrag: experience.screenshotDrag))
            .onHover { hovering = $0 }
            .help(url.lastPathComponent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(url.lastPathComponent)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, experience.openScreenshot)
        } else {
            Color.clear
        }
    }

    private func button(_ symbol: String, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .fixedSize()
            .padding(.horizontal, 10).frame(height: 24)
            .background(.white.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle()).help(help)
    }
}

/// A downsampled copy of an image file and its full pixel size, for the screenshot peek and image tiles on the
/// shelf. ImageIO decodes only what the thumbnail needs, off the main thread, once per file version; a small cache
/// keeps it.
final class NotchImagePreview: Sendable {
    let image: CGImage
    let pixelSize: CGSize

    private init(image: CGImage, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
    }

    /// Long side in pixels: the peek's 110 pt slot at 2x, with a little room.
    private static let maxPixels = 256
    /// Keyed by path and modification date, so a shelved image saved again gets a new preview.
    private static let cache: NSCache<NSString, NotchImagePreview> = {
        let cache = NSCache<NSString, NotchImagePreview>()
        cache.countLimit = 64
        return cache
    }()

    private static func key(_ url: URL) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
    }

    /// Image files get a preview; everything else, PDFs included, keeps its icon.
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func cached(_ url: URL) -> NotchImagePreview? { cache.object(forKey: key(url)) }

    /// The cached preview, or one made in the background; nil for other files and unreadable images.
    static func load(_ url: URL) async -> NotchImagePreview? {
        if let preview = cached(url) { return preview }
        return await Task.detached(priority: .utility) { make(url) }.value
    }

    /// Makes and caches a preview on the calling thread. Views use `load`; fixtures call this directly.
    @discardableResult
    static func make(_ url: URL) -> NotchImagePreview? {
        // Decode and cache under the version observed before opening the file, even if it is saved again meanwhile.
        let version = key(url)
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard isImage(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let preview = NotchImagePreview(image: image, pixelSize: CGSize(width: width, height: height))
        cache.setObject(preview, forKey: version)
        return preview
    }
}
