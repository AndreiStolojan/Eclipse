import AppKit

/// Wraps the SwiftUI notch so the panel can receive file drops once the detector stops it ignoring the mouse.
/// The pointer's horizontal position picks the shelf or AirDrop target.
final class NotchDropView: NSView {
    private let hosting: NSView
    private let onTarget: (NotchDropZone) -> Void
    private let onDrop: ([URL], NotchDropZone) -> Void
    private let onSessionEnded: () -> Void
    /// A drag from the notch itself entered (true) or left (false) the panel; other apps' drags come from the detector.
    private let onLocalDrag: (Bool) -> Void

    init(hosting: NSView, onTarget: @escaping (NotchDropZone) -> Void,
         onDrop: @escaping ([URL], NotchDropZone) -> Void, onSessionEnded: @escaping () -> Void,
         onLocalDrag: @escaping (Bool) -> Void) {
        self.hosting = hosting
        self.onTarget = onTarget
        self.onDrop = onDrop
        self.onSessionEnded = onSessionEnded
        self.onLocalDrag = onLocalDrag
        super.init(frame: .zero)
        addSubview(hosting)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        if sender.draggingSource != nil { onLocalDrag(true) }
        onTarget(zone(of: sender))
        return .copy
    }

    /// Sent as the pointer moves over the panel, so the highlighted target follows it.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        onTarget(zone(of: sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, sender.draggingSource != nil, accepts(sender) { onLocalDrag(false) }
    }

    /// No periodic updates while the drag hovers; entry and exit come from the detector, or from the callbacks
    /// above for the notch's own drags.
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender) else { return false }
        onDrop(fileURLs(in: sender), zone(of: sender))
        return true
    }

    /// Sent for drops and for cancelled drags alike; the controller treats it as a no-op after a completed drop.
    override func draggingEnded(_ sender: NSDraggingInfo) { onSessionEnded() }

    /// Files from other apps, and the screenshot thumbnail. Files dragged out of the shelf are never dropped back onto it.
    private func accepts(_ info: NSDraggingInfo) -> Bool {
        let notchDrop = info.draggingSource == nil || (info.draggingSource as? NotchFileDragSource.SourceView)?.dropsOnNotch == true
        return notchDrop && !fileURLs(in: info).isEmpty
    }

    private func zone(of info: NSDraggingInfo) -> NotchDropZone {
        NotchDropZone(x: convert(info.draggingLocation, from: nil).x, width: bounds.width)
    }

    private func fileURLs(in info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
