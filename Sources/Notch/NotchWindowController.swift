import AppKit
import SwiftUI

/// A stable hosting window lets one SwiftUI spring animate the notch. Invisible space passes mouse events through.
@MainActor
final class NotchWindowController {
    let experience: NotchExperience
    private var panel: NotchMusicPanel?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false
    private var suspended = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var scrollMonitor: Any?
    private var pointerInside = false
    /// Whether the panel was on screen after the last layout, so a return can be told from a refresh.
    private var shown = false
    /// The displays are asleep while the Mac stays awake, between the workspace's screen sleep and wake notifications.
    private var screensAsleep = false
    private let dragDetector = NotchDragDetector()
    private let visibility = NotchVisibilityMonitor()
    /// The lock and media above the lock screen; it conceals this panel while the Mac is locked.
    private let lockScreen: NotchLockScreenController

    init(experience: NotchExperience? = nil) {
        self.experience = experience ?? NotchExperience()
        lockScreen = NotchLockScreenController(experience: self.experience)
        self.experience.onLayoutChange = { [weak self] in self?.layout() }
        visibility.onChange = { [weak self] surroundings in self?.experience.surroundings = surroundings }
    }

    func start() {
        guard !running else { return }
        running = true
        experience.start()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.swipe(event) == true ? nil : event }
        }
        dragDetector.regionContains = { [weak self] point in
            guard let self, let geometry = self.experience.geometry else { return false }
            return geometry.contains(point, self.experience.state.shape)
        }
        dragDetector.onEnter = { [weak self] in self?.dragEntered() }
        dragDetector.onExit = { [weak self] in self?.dragEnded() }
        dragDetector.start()
        visibility.start()
        lockScreen.start()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.layout() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.suspend() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.resume() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) {
            $0.screensAsleep = true
            $0.updateObscured()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) {
            $0.screensAsleep = false
            $0.updateObscured()
        }
        observe(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification) { $0.updateObscured() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { $0.suspend() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification) { $0.resume() }
        observe(NotificationCenter.default, NSApplication.willTerminateNotification) { $0.stop() }
        layout()
    }

    /// Runs at quit: unlike sleep, this also closes the socket and removes its file.
    func stop() {
        running = false
        experience.stop()
        experience.socket.stop()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        scrollMonitor = nil
        dragDetector.stop()
        visibility.stop()
        lockScreen.stop()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func suspend() {
        suspended = true
        experience.stop()
        visibility.stop()
        panel?.orderOut(nil)
        shown = false
    }

    func resume() {
        guard running else { return }
        suspended = false
        experience.start()
        visibility.start()
        layout()
    }

    func layout() {
        guard running, !suspended else { hide(); return }
        let screens = NSScreen.screens
        let displays = screens.enumerated().map { NotchDisplay(screen: $1, isMain: $0 == 0) }
        if experience.displays != displays { experience.displays = displays }
        guard let target = NotchDisplay.resolve(experience.settings.display, in: displays),
              let screen = screens.first(where: { NotchDisplay.id(of: $0) == target.id }) else { hide(); return }
        visibility.display = target.id
        visibility.watchesMissionControl = experience.settings.hideInMissionControl
        guard !experience.concealed else { hide(); return }
        let geometry = NotchGeometry(screen: screen, settings: experience.settings)
        if experience.geometry != geometry { experience.geometry = geometry }
        // The panel holds every shape the view can draw; a thread's page, the open player with its level row and the
        // widened wings bound the rest.
        let frame = geometry.frame(.openLevel).union(geometry.frame(.indicator)).union(geometry.frame(.screenshot))
            .union(geometry.frame(.eventPeek)).union(geometry.frame(.agentPeek)).union(geometry.frame(.trackPeek))
            .union(geometry.frame(.dictation))
            .union(geometry.frame(.noticePeek)).union(geometry.frame(.notifications))
            .union(geometry.frame(.thread)).union(geometry.frame(.timerAlert)).union(geometry.frame(.timerDone))
        if panel == nil {
            let newPanel = NotchMusicPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = false
            newPanel.hidesOnDeactivate = false
            newPanel.isFloatingPanel = true
            newPanel.isMovable = false
            newPanel.isReleasedWhenClosed = false
            newPanel.level = .statusBar + 1
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            newPanel.appearance = NSAppearance(named: .darkAqua)
            newPanel.title = "Notch music"
            newPanel.contentView = NotchDropView(
                hosting: NSHostingView(rootView: NotchView(experience: experience)),
                onTarget: { [weak self] zone in
                    if self?.experience.dropZone != zone { self?.experience.dropZone = zone }
                },
                onDrop: { [weak self] urls, zone in self?.experience.receiveDrop(urls, zone: zone) },
                onSessionEnded: { [weak self] in self?.dragEnded() },
                onLocalDrag: { [weak self] inside in self?.localDrag(inside) })
            panel = newPanel
        }
        guard let panel else { return }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        let sharing: NSWindow.SharingType = experience.settings.hideFromScreenCapture ? .none : .readOnly
        if panel.sharingType != sharing { panel.sharingType = sharing }
        // A pointer already resting on the notch as it returns, say after leaving Mission Control or a fullscreen
        // app, is where the notch starts rather than a hover: it has to leave and come back to open the player.
        if !shown { pointerInside = geometry.contains(NSEvent.mouseLocation, experience.state.shape) }
        shown = true
        updateMousePassthrough()
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        shown = false
    }

    /// The panel counts as obscured while the displays sleep or, once ordered in, while macOS reports it fully
    /// covered. An ordered-out panel is hidden for its own reasons, so its occlusion is not consulted.
    private func updateObscured() {
        let covered = panel.map { $0.isVisible && !$0.occlusionState.contains(.visible) } ?? false
        let obscured = screensAsleep || covered
        if experience.obscured != obscured { experience.obscured = obscured }
    }

    private func updateMousePassthrough() {
        guard running, !suspended, !experience.concealed, let panel, let geometry = experience.geometry else {
            panel?.ignoresMouseEvents = true
            pointerInside = false
            return
        }
        // The screenshot thumbnail's drag keeps the panel a drop destination wherever the pointer goes, so the drop
        // targets can reopen when it returns; hover resumes once it ends.
        if experience.draggingScreenshot { panel.ignoresMouseEvents = false; return }
        // A drag that ended without a report from the panel is reconciled on the next pointer move.
        if experience.state.dropTargeted, !dragDetector.dragging { experience.state.dragExit() }
        let point = NSEvent.mouseLocation
        let containsPointer = geometry.contains(point, experience.state.shape)
        // This event-driven check does not sample the cursor on a timer or capture keyboard events.
        if panel.ignoresMouseEvents == containsPointer { panel.ignoresMouseEvents = !containsPointer }
        if pointerInside != containsPointer {
            pointerInside = containsPointer
            experience.hover(containsPointer)
        }
    }

    /// Two-finger trackpad swipes over the notch open, close, page and skip. A gesture's start and travel count
    /// only from the panel, which receives them only while the pointer is over the visible shape; its end is
    /// forwarded from any window, the app window included, so a swipe that drifted off the panel still settles.
    /// Mouse wheels and momentum scrolling after the fingers lift are ignored. Returns whether the event was consumed.
    private func swipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return false }
        let phase: NotchSwipePhase
        switch event.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended, .cancelled: phase = .ended
        default: return false
        }
        guard phase == .ended || (event.window === panel && experience.state.acceptsSwipes) else { return false }
        // Natural scrolling reports finger motion directly; otherwise the deltas are reversed.
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        return experience.swipe(phase, dx: event.scrollingDeltaX * direction, dy: event.scrollingDeltaY * direction)
    }

    /// A file drag reached the notch: open it and stop ignoring the mouse so the panel becomes the drop destination.
    private func dragEntered() {
        guard running, !suspended, !experience.concealed, let panel else { return }
        experience.beginDrag()
        panel.ignoresMouseEvents = false
    }

    /// A drag that started in this app, the screenshot thumbnail, entered or left the panel. The detector watches
    /// only other apps' mouse events, so it never sees this drag.
    private func localDrag(_ inside: Bool) {
        if !inside { dragEnded() } else if !experience.state.dropTargeted { experience.beginDrag() }
    }

    /// The drag left the notch or the session ended without a drop. A completed drop has already cleared the target.
    private func dragEnded() {
        guard experience.state.dropTargeted else { return }
        experience.state.dragExit()
        updateMousePassthrough()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping (NotchWindowController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }
}

/// Media controls accept mouse actions while keyboard focus stays in the user's editor.
final class NotchMusicPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
