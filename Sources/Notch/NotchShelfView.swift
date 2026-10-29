import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Shelf page: a scrolling grid of shelf files with send-all and clear beneath. With the clipboard
/// history on, a switch at the bottom left turns the page to the Clipboard list.
struct NotchShelfView: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var shelf: NotchShelf
    @ObservedObject var clipboard: NotchClipboard
    let topHeight: CGFloat

    init(experience: NotchExperience, topHeight: CGFloat) {
        self.experience = experience
        shelf = experience.shelf
        clipboard = experience.clipboard
        self.topHeight = topHeight
    }

    private var switchable: Bool { experience.settings.clipboardHistory }
    private var showsClipboard: Bool { switchable && experience.shelfShowsClipboard }

    var body: some View {
        VStack(spacing: 0) {
            if showsClipboard {
                NotchClipboardList(experience: experience, clipboard: clipboard)
            } else if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 20))
                    Text("Drag files here").font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 4), count: NotchShelf.columns), spacing: 8) {
                        ForEach(shelf.items) { item in
                            NotchShelfTile(item: item, remove: { shelf.remove(item.id) }, onDrag: experience.shelfDrag)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            if switchable || !shelf.items.isEmpty { footer }
        }
        .padding(.top, topHeight + 8).padding(.bottom, 4)
    }

    /// The switch or the file count on the left; AirDrop for the files and clear for whichever list shows.
    private var footer: some View {
        HStack(spacing: 4) {
            if switchable {
                NotchShelfSwitch(clipboard: $experience.shelfShowsClipboard)
            } else {
                Text("\(shelf.items.count) file\(shelf.items.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if !showsClipboard {
                Button { experience.send(shelf.urls) } label: {
                    Image(systemName: "dot.radiowaves.up.forward").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28).background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("AirDrop all files").help("AirDrop all files")
                .revealed(!shelf.items.isEmpty)
            }
            Button(action: showsClipboard ? clipboard.clear : shelf.removeAll) {
                Image(systemName: "trash").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7)).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .accessibilityLabel(showsClipboard ? "Clear clipboard history" : "Clear shelf")
            .help(showsClipboard ? "Clear clipboard history" : "Clear shelf, originals stay where they are")
            .revealed(showsClipboard ? !clipboard.history.items.isEmpty : !shelf.items.isEmpty)
        }
        .buttonStyle(NotchPressStyle())
        .padding(.leading, 16).padding(.trailing, 12).frame(height: 36)
    }
}

/// Files or Clipboard, as two small segments.
private struct NotchShelfSwitch: View {
    @Binding var clipboard: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment("Files", selected: !clipboard) { clipboard = false }
            segment("Clipboard", selected: clipboard) { clipboard = true }
        }
        .padding(2)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
                .padding(.horizontal, 7).frame(height: 18)
                .background(selected ? .white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Copied text and images, newest first, one row each. A click copies the item back, a drag hands it to any app.
private struct NotchClipboardList: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var clipboard: NotchClipboard

    var body: some View {
        if clipboard.history.items.isEmpty {
            Text(clipboard.access.reads ? "Nothing copied yet" : "Allow paste access in Eclipse's Shelf settings")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(clipboard.history.items) { clip in
                        NotchClipRow(clip: clip, copy: { clipboard.copy(clip.id) }, onDrag: experience.shelfDrag)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }
}

/// One copied item: a symbol or thumbnail, one line of text, and the app it came from, which hover turns into Copy
/// and a click into Copied for a second. A secret shows masked with the time it has left.
private struct NotchClipRow: View {
    let clip: NotchClip
    let copy: () -> Void
    let onDrag: (NotchFileDrag) -> Void
    @State private var hovering = false
    @State private var copied = false

    static let height = CGFloat(NotchClipboard.rowHeight)

    var body: some View {
        HStack(spacing: 9) {
            lead.frame(width: 28, height: 20)
            line.font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            trailing.font(.system(size: 10, weight: hovering || copied ? .semibold : .regular))
        }
        .padding(.horizontal, 4).frame(height: Self.height)
        .background(hovering ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(NotchFileDragSource(url: nil, object: object, imageFrame: CGRect(x: 4, y: 5, width: 28, height: 20),
                                     click: click, onDrag: onDrag))
        .onHover { hovering = $0 }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1))
            copied = false
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, click)
    }

    private var secret: Bool { clip.expires != nil }

    @ViewBuilder private var lead: some View {
        switch clip.content {
        case .image(let image):
            Image(nsImage: image).resizable().interpolation(.medium).scaledToFill()
                .frame(width: 28, height: 20).clipShape(RoundedRectangle(cornerRadius: 3))
        case .text(let text):
            Image(systemName: secret ? "key.fill" : URL(string: text)?.scheme?.hasPrefix("http") == true ? "link" : "doc.on.clipboard")
                .font(.system(size: 13)).foregroundStyle(secret ? Color(nsColor: .systemOrange) : .white.opacity(0.7))
        }
    }

    @ViewBuilder private var line: some View {
        switch clip.content {
        case .image(let image):
            // Pixels, as the screenshot peek shows them, and without a thousands separator.
            let pixels = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
            Text(verbatim: "Image · \(Int(pixels.width)) × \(Int(pixels.height))")
        case .text(let text) where secret:
            Text(NotchClipFilter.masked(text)).foregroundStyle(Color(nsColor: .systemOrange))
        case .text(let text):
            Text(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text)
        }
    }

    @ViewBuilder private var trailing: some View {
        if copied {
            Label("Copied", systemImage: "checkmark").foregroundStyle(Color(nsColor: .systemGreen))
        } else if hovering {
            Label("Copy", systemImage: "doc.on.doc").foregroundStyle(.white)
        } else if let expires = clip.expires {
            // Ticks once a second, and only for a secret on screen.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Duration.seconds(max(0, expires.timeIntervalSince(context.date))).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit().foregroundStyle(Color(nsColor: .systemOrange))
            }
        } else if let source = clip.source {
            Text(source).foregroundStyle(.white.opacity(0.6))
        }
    }

    /// What a drag carries, decided as it starts: nothing for a secret whose time is up but which has not left the
    /// list yet.
    private func object() -> NSPasteboardWriting? {
        if let expires = clip.expires, expires <= .now { return nil }
        switch clip.content {
        case .text(let text): return text as NSString
        case .image(let image): return image
        }
    }

    private var accessibilityText: String {
        switch clip.content {
        case .image: "Copied image"
        case .text(let text): secret ? "Copied secret" : text
        }
    }

    private func click() {
        copy()
        copied = true
    }
}

/// One shelf file. Dragging copies it into Finder or any app and a click opens it.
/// Images, screenshots above all, show a preview of themselves instead of the file icon.
private struct NotchShelfTile: View {
    let item: NotchShelf.Item
    let remove: () -> Void
    let onDrag: (NotchFileDrag) -> Void
    @State private var hovering = false
    @State private var preview: NotchImagePreview?

    init(item: NotchShelf.Item, remove: @escaping () -> Void, onDrag: @escaping (NotchFileDrag) -> Void) {
        self.item = item
        self.remove = remove
        self.onDrag = onDrag
        _preview = State(initialValue: NotchImagePreview.cached(item.url))
    }

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let preview {
                    Image(decorative: preview.image, scale: 1).resizable().interpolation(.high).scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable()
                }
            }
            .frame(width: 36, height: 36)
            Text(item.name).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 56)
        .overlay(NotchFileDragSource(url: item.url, image: preview?.image, imageFrame: imageFrame, click: click, onDrag: onDrag))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        .frame(width: 14, height: 14).background(Color(white: 0.33), in: Circle())
                }
                .buttonStyle(.plain).offset(x: -4, y: -4)
                .accessibilityHidden(true)
            }
        }
        .onHover { hovering = $0 }
        .help(item.url.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, click)
        .accessibilityAction(named: "Remove from shelf", remove)
        .task(id: item.url) {
            guard NotchImagePreview.isImage(item.url) else { preview = nil; return }
            let made = await NotchImagePreview.load(item.url)
            guard !Task.isCancelled else { return }
            preview = made
        }
    }

    /// Where the image sits in the tile, so a drag lifts it from there: centred in the 36 pt box at the top.
    private var imageFrame: CGRect {
        let size = preview.map { CGSize(width: $0.image.width, height: $0.image.height) } ?? CGSize(width: 1, height: 1)
        let scale = 36 / max(size.width, size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (56 - fitted.width) / 2, y: (36 - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    private func click() { NSWorkspace.shared.open(item.url) }
}

/// AppKit drag source so the drag offers only copy: Finder never moves the original out of its folder. Without a
/// file it drags what `object` returns as the drag starts, a copied text or image from the Clipboard list,
/// and nothing when it returns nil.
struct NotchFileDragSource: NSViewRepresentable {
    let url: URL?
    var object: (() -> NSPasteboardWriting?)?
    /// Lifted as the drag image from `imageFrame`, in top-left coordinates of this view (all of it when nil); the
    /// file icon when there is no image.
    var image: CGImage?
    var imageFrame: CGRect?
    /// Lets the drag land on the notch's own Shelf and AirDrop targets: true for the screenshot thumbnail, false for
    /// shelf tiles, which never drop back onto the shelf.
    var dropsOnNotch = false
    let click: () -> Void
    let onDrag: (NotchFileDrag) -> Void

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.url = url
        view.object = object
        view.image = image
        view.imageFrame = imageFrame
        view.dropsOnNotch = dropsOnNotch
        view.click = click
        view.onDrag = onDrag
    }

    final class SourceView: NSView, NSDraggingSource {
        var url: URL?
        var object: (() -> NSPasteboardWriting?)?
        var image: CGImage?
        var imageFrame: CGRect?
        var dropsOnNotch = false
        var click: () -> Void = {}
        var onDrag: (NotchFileDrag) -> Void = { _ in }
        private var mouseDownEvent: NSEvent?

        override var isFlipped: Bool { true }

        /// The panel never becomes key, so the first click must act.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent,
                  hypot(event.locationInWindow.x - down.locationInWindow.x,
                        event.locationInWindow.y - down.locationInWindow.y) > 3 else { return }
            mouseDownEvent = nil
            guard let writer = url.map({ $0 as NSURL }) ?? object?() else { return }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let frame = imageFrame ?? bounds
            item.setDraggingFrame(frame, contents: image.map { NSImage(cgImage: $0, size: frame.size) }
                                  ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? writer as? NSImage
                                  ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil))
            onDrag(.began)
            beginDraggingSession(with: [item], event: down, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if mouseDownEvent != nil { click() }
            mouseDownEvent = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        /// An operation other than none means a destination took the file: the notch's targets, Finder or an app.
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onDrag(.ended(delivered: !operation.isEmpty))
        }
    }
}

/// Shown while a file drag is over the notch; the target under the pointer fills.
struct NotchDropTargets: View {
    let zone: NotchDropZone
    let topHeight: CGFloat

    var body: some View {
        HStack(spacing: NotchDropZone.gap) {
            target("tray.and.arrow.down", "Shelf", hot: zone == .shelf)
            target("dot.radiowaves.up.forward", "AirDrop", hot: zone == .airDrop)
                .frame(width: NotchDropZone.airDropWidth)
        }
        .padding(.horizontal, NotchDropZone.inset).padding(.top, topHeight + 8).padding(.bottom, 12)
    }

    private func target(_ symbol: String, _ title: String, hot: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 20))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hot ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            hot ? .white : .white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: hot ? [] : [4, 3])))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(hot ? .isSelected : [])
    }
}

/// Identifies the app or website playing, where the playback glyph used to be; the transport already shows play state.
/// A click brings that app or browser tab forward.
struct NotchSourceBadge: View {
    let name: String
    let icon: NSImage?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(name).font(.system(size: 8, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .help("Open \(name)")
        .accessibilityLabel("Open \(name)")
    }
}
