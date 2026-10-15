// Adapted from boring.notch, `boringNotch/observers/DragDetector.swift`, created by Alexander on 2025-11-20.
// https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/observers/DragDetector.swift
// boring.notch is licensed under the GNU General Public License v3.0; this file stays under that license.
// Changes: the notch region is a hit-test closure instead of a fixed rect, only file URLs count as content,
// callbacks run on the main actor and the drop/cancel end is reported by the panel rather than here.

import AppKit

/// Notices file drags from other apps approaching the notch. Passthrough normally follows `.mouseMoved`, but a
/// drag sends `.leftMouseDragged`, so these global mouse monitors fill the gap. They need no Accessibility permission.
@MainActor
final class NotchDragDetector {
    /// Hit test in screen coordinates; the controller supplies the current notch shape.
    var regionContains: (CGPoint) -> Bool = { _ in false }
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// True while a file drag started in another app is still held.
    private(set) var dragging = false

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var monitors: [Any] = []
    private var changeCountAtMouseDown: Int?
    private var insideRegion = false

    func start() {
        stop()
        let handlers: [(NSEvent.EventTypeMask, (NotchDragDetector) -> Void)] = [
            (.leftMouseDown, { $0.mouseDown() }),
            (.leftMouseDragged, { $0.mouseDragged() }),
            (.leftMouseUp, { $0.reset() })
        ]
        monitors = handlers.compactMap { mask, action in
            NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    /// The drag pasteboard changes only once a real drag begins, so a plain click never counts as content.
    private func mouseDown() {
        changeCountAtMouseDown = dragPasteboard.changeCount
        dragging = false
        insideRegion = false
    }

    private func mouseDragged() {
        guard let baseline = changeCountAtMouseDown else { return }
        if !dragging, dragPasteboard.changeCount != baseline, dragPasteboard.types?.contains(.fileURL) == true {
            dragging = true
        }
        guard dragging else { return }
        let inside = regionContains(NSEvent.mouseLocation)
        guard inside != insideRegion else { return }
        insideRegion = inside
        if inside { onEnter?() } else { onExit?() }
    }

    /// Release ends tracking. Whether the drop reached the notch is reported by the panel's drop view.
    private func reset() {
        changeCountAtMouseDown = nil
        dragging = false
        insideRegion = false
    }
}
