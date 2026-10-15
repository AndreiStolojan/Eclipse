import AppKit
import Combine
import os

/// Phases of a two-finger trackpad scroll, as forwarded by the window controller.
enum NotchSwipePhase {
    case began, changed, ended
}

/// The direction a swipe locks to once the fingers have clearly moved.
private enum NotchSwipeAxis {
    case horizontal, vertical
}

/// Owns notch interaction and media/volume service lifetimes, and presents Sotto's dictation arriving over the socket.
@MainActor
final class NotchExperience: ObservableObject {
    @Published var state = NotchState() {
        didSet {
            guard state != oldValue else { return }
            syncTimerDisplay()
            if state.expanded, !oldValue.expanded {
                shelf.refresh(); calendar.refreshAccess(); calendar.notchOpened()
                // The open notch shows the track itself; one still settling would peek once it closes.
                if !state.peeking { trackSettleTask?.cancel(); trackSettleTask = nil }
            }
            if !state.expanded, oldValue.expanded { endSwipe(); calendar.notchClosed() }
            // Opening on the Music page asks Safari again for a website a failed read left unknown.
            if state.expanded, state.activity == .music, !oldValue.expanded || oldValue.activity != .music {
                media.lookUpWebSite()
            }
            // Anything that takes the wings from an alert before its time is up puts the rest back in line.
            if let shown = shownAlert, state.hud != shown.alert.hud {
                shownAlert = nil
                hudTask?.cancel()
                alerts.resume(shown.alert, remaining: (shown.until - .now) / .seconds(1))
            }
            if state.level == nil, oldValue.level != nil { resetLevelTime() }
            if state.eventPeek != oldValue.eventPeek { resetEventPeekTime() }
            // The Done row's time runs while it is in the closed notch and on screen, from each time it shows.
            if state.shape != oldValue.shape {
                if state.shape == .timerDone { scheduleTimerDoneEnd() } else if oldValue.shape == .timerDone { timerDoneTask?.cancel() }
            }
            if state.agentPeek != oldValue.agentPeek { resetAgentPeekTime() }
            let watched = state.shape == .thread ? state.agentThread : nil
            if t3.watched != watched { t3.watched = watched }
            // Time to leave asks until its alert has really been on screen.
            if case .leave(let event) = state.hud, state.hud != oldValue.hud { travel.shown(event) }
            if state.hud == nil {
                showWaitingAlert()
                // Showing one assigned `state` and so ran this observer again, layout included.
                if state.hud != nil { return }
            }
            // So did dropping a stale Quick Peek or T3 alert.
            if startAgentPeekTime() || startEventPeekTime() { return }
            onLayoutChange?()
        }
    }
    /// The user's own hide, from the menu or the window.
    @Published var hidden = false { didSet { updateConcealment() } }
    /// Fullscreen, Mission Control and games, as the window controller's monitor reports them; the settings decide
    /// which of them hide the notch.
    @Published var surroundings = NotchSurroundings() { didSet { updateConcealment() } }
    /// The Mac is locked or still unlocking, as the lock screen controller reports it. The notch conceals itself
    /// meanwhile, so the shelf, calendar, T3 Code, screenshots, drops and indicators are all unreachable; the lock
    /// screen's own windows show only the lock and the media. Unlike a hide, locking also drops the Quick Peek and the
    /// T3 Code alert waiting underneath, so nothing private shows the moment the Mac unlocks, and pauses Safari's
    /// website lookups until it does.
    @Published var locked = false {
        didSet {
            updateConcealment()
            if locked, !oldValue { state.eventPeek = nil; state.agentPeek = nil }
            media.webLookupsPaused = locked
        }
    }
    /// Set while the notch is off screen for any of these reasons. It returns closed: nothing pending carries over.
    @Published private(set) var concealed = false
    /// The panel is on screen but cannot be seen: the displays sleep or a window such as the screen saver covers it,
    /// as the window controller reports it. The playing wave stops meanwhile, and no Netflix tab is read for a peek.
    @Published var obscured = false { didSet { updateMediaWants() } }
    /// The app window is open and not minimised or fully covered, as its delegate reports it. The settings previews
    /// play only meanwhile.
    @Published var windowVisible = false
    /// Connected displays, for the display picker; the window controller refreshes them on every layout.
    @Published var displays: [NotchDisplay] = []
    /// The drop target under a file drag, so the view can fill it.
    @Published var dropZone = NotchDropZone.shelf
    /// Horizontal offset of the views while fingers are on the trackpad; zero otherwise.
    @Published private(set) var swipeOffset: CGFloat = 0 {
        didSet { if (swipeOffset == 0) != (oldValue == 0) { syncTimerDisplay() } }
    }
    /// Edits apply to the live notch at once and are written back to the user's defaults.
    @Published var settings: NotchSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            if settings.replaceSystemHUD != oldValue.replaceSystemHUD || settings.capsLockHUD != oldValue.capsLockHUD { updateKeyTap() }
            if settings.screenshotThumbnail != oldValue.screenshotThumbnail { updateScreenshots(); dismissScreenshot() }
            if settings.shelveScreenshots != oldValue.shelveScreenshots { updateScreenshots() }
            if settings.clipboardHistory != oldValue.clipboardHistory || settings.clipboardLimit != oldValue.clipboardLimit {
                updateClipboard()
            }
            if settings.downloadAlerts != oldValue.downloadAlerts { updateDownloads(); dismissDownload() }
            if settings.calendar != oldValue.calendar || settings.calendarCountdown != oldValue.calendarCountdown
                || settings.calendarLead != oldValue.calendarLead || settings.hiddenCalendars != oldValue.hiddenCalendars
                || settings.timeToLeave != oldValue.timeToLeave || settings.leaveBuffer != oldValue.leaveBuffer
                || settings.travelMode != oldValue.travelMode {
                updateCalendar()
            }
            if let peek = state.eventPeek, !wants(peek) { dismissEventPeek() }
            // Either kind of peek ends with its switch or as the other kind replaces it; the pointer and the pin keep theirs.
            if !settings.peekOnTrackChange || settings.trackPeekOpensNotch != oldValue.trackPeekOpensNotch {
                endTrackPeek()
                endPeek()
            }
            if settings.sottoLinked != oldValue.sottoLinked { updateSocket() }
            if settings.dictationInNotch != oldValue.dictationInNotch || settings.sottoLinked != oldValue.sottoLinked {
                syncDictation()
            }
            if settings.t3Linked != oldValue.t3Linked || settings.agentAlerts != oldValue.agentAlerts { updateAgents() }
            if settings.timer != oldValue.timer { updateTimer() }
            updateMediaWants()
            updateConcealment()
            onLayoutChange?()
        }
    }
    let media: NotchMedia
    let volume = NotchVolume()
    let brightness = NotchBrightness()
    let keys = NotchMediaKeyTap()
    let focus: NotchFocus
    let battery: NotchBattery
    let audioDevices = NotchAudioDevices()
    let screenshots: NotchScreenshots
    /// Finished downloads, watched while download alerts are on.
    let downloads: NotchDownloads
    let calendar: NotchCalendar
    let travel: NotchTravel
    /// Outlives `stop()`, so Sotto stays connected through sleep; the window controller closes it at quit.
    let socket: NotchSocket
    let shelf: NotchShelf
    /// Copies kept for the Shelf page's Clipboard list, watched while that setting is on.
    let clipboard: NotchClipboard
    /// The Shelf page shows the Clipboard list instead of the files; kept across closing like the page itself.
    @Published var shelfShowsClipboard = false
    /// T3 Code's threads, connected while its link is on.
    let t3: NotchT3
    /// The one timer, counting while its page is on.
    let timer: NotchTimer
    /// Set by the Timer page while the pointer is on its dial, where a vertical two-finger scroll sets the length
    /// instead of closing the notch.
    var timerDialHovered = false
    @Published var geometry: NotchGeometry?
    var onLayoutChange: (() -> Void)?
    private var hoverTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    /// Battery, Focus and audio device alerts waiting for the wings, and the one shown with when its time runs out.
    private var alerts = NotchAlertQueue()
    private var shownAlert: (alert: NotchAlert, until: ContinuousClock.Instant)?
    private var peekTask: Task<Void, Never>?
    /// Waits for a new track's metadata to settle before the peek shows it; restarted by every change meanwhile.
    private var trackSettleTask: Task<Void, Never>?
    /// Ends the mini peek at `trackPeekEnd` unless the pointer holds it.
    private var trackPeekTask: Task<Void, Never>?
    private var trackPeekEnd: ContinuousClock.Instant?
    /// The artwork of the track the mini peek shows, kept with it so a newer track's art never shows beside its title.
    /// Set with each peek; fixture renders set it directly.
    @Published var trackPeekArtwork: NSImage?
    /// Retracts the level row after the indicator duration, unless something holds it.
    private var levelTask: Task<Void, Never>?
    private var levelHolds: Set<NotchLevelHold> = []
    private var screenshotTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var eventPeekTask: Task<Void, Never>?
    /// Set once the Quick Peek in `state` has been on screen: its time runs from then, covered or not.
    private var eventPeekStarted = false
    private var agentPeekTask: Task<Void, Never>?
    /// When the T3 alert in `state` arrived and whether it has been on screen, as for a Quick Peek.
    private var agentPeekArrived = ContinuousClock.now
    private var agentPeekStarted = false
    private var timerDoneTask: Task<Void, Never>?
    /// Mirrors the last hover report, so a screenshot or a Quick Peek waits while the pointer is over it.
    private var pointerOver = false
    /// Set while the screenshot thumbnail is being dragged; the panel stays a drop destination meanwhile.
    private(set) var draggingScreenshot = false
    private var running = false
    private let defaults: UserDefaults
    private let hapticFeedback: () -> Void
    private let playSound: (String) -> Void
    private let dropLog = Logger(subsystem: "ro.andrei.NotchLab", category: "drop")
    private var swipeTravel = CGSize.zero
    private var swipeAxis: NotchSwipeAxis?
    /// Set once a gesture has opened, closed or skipped, so one swipe does one thing however far it goes.
    /// Both flags live until the gesture's own end, whichever window that lands in.
    private var swipeActed = false
    /// Whether the current gesture is ours, so its end is swallowed too.
    private var swipeHandled = false
    /// Set when a gesture starts on the idle Timer page's dial; its vertical travel turns the dial, `dialSteps`
    /// detents so far.
    private var swipeDial = false
    private var dialSteps = 0
    private var airDrop: NotchAirDrop?

    /// Finger travel needed to change view on release.
    static let swipeThreshold: CGFloat = 50
    /// Finger travel that opens, closes or skips; shorter than paging, which can be judged on release.
    static let flickThreshold: CGFloat = 40
    /// Finger travel per detent of the timer's dial.
    static let dialDetent: CGFloat = 12

    init(media: NotchMedia? = nil, focus: NotchFocus? = nil, battery: NotchBattery? = nil, socket: NotchSocket? = nil,
         calendar: NotchCalendar? = nil, travel: NotchTravel? = nil, t3: NotchT3? = nil, timer: NotchTimer? = nil,
         screenshots: NotchScreenshots? = nil, downloads: NotchDownloads? = nil, clipboard: NotchClipboard? = nil,
         defaults: UserDefaults = .standard,
         hapticFeedback: @escaping () -> Void = {
             NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
         },
         playSound: @escaping (String) -> Void = { NSSound(named: $0)?.play() }) {
        self.media = media ?? NotchMedia()
        self.focus = focus ?? NotchFocus()
        self.battery = battery ?? NotchBattery()
        self.socket = socket ?? NotchSocket()
        self.calendar = calendar ?? NotchCalendar()
        self.travel = travel ?? NotchTravel()
        self.t3 = t3 ?? NotchT3()
        self.timer = timer ?? NotchTimer(defaults: defaults)
        self.screenshots = screenshots ?? NotchScreenshots()
        self.clipboard = clipboard ?? NotchClipboard()
        self.downloads = downloads ?? NotchDownloads()
        self.defaults = defaults
        self.hapticFeedback = hapticFeedback
        self.playSound = playSound
        shelf = NotchShelf(defaults: defaults)
        settings = NotchSettings.load(from: defaults)
        volume.onChange = { [weak self] in self?.volumeChanged() }
        brightness.onChange = { [weak self] in self?.show(.brightness) }
        self.focus.onChange = { [weak self] _ in self?.show(.focus) }
        self.battery.onChange = { [weak self] in self?.show(.battery) }
        audioDevices.onChange = { [weak self] change in self?.show(.audioDevice(change)) }
        self.media.onTrackChange = { [weak self] newTrack in self?.trackChanged(newTrack: newTrack) }
        self.socket.dictation.onChange = { [weak self] _ in self?.syncDictation() }
        self.screenshots.onCapture = { [weak self] url in self?.receive(screenshot: url) }
        self.downloads.onDownload = { [weak self] download in self?.show(download: download) }
        keys.onPress = { [weak self] press in self?.apply(press) ?? false }
        keys.onCapsLock = { [weak self] on in self?.show(.capsLock(on: on)) }
        self.calendar.onCountdownChange = { [weak self] in self?.syncCountdown() }
        self.calendar.onPeek = { [weak self] peek in self?.show(eventPeek: peek) }
        self.calendar.onAgendaChange = { [weak self] in
            guard let self else { return }
            self.travel.agenda = self.calendar.agenda
        }
        self.travel.onLeave = { [weak self] event in self?.show(.leave(event)) }
        self.travel.agenda = self.calendar.agenda
        self.t3.onAlert = { [weak self] alert in self?.show(agentAlert: alert) }
        self.t3.onRejected = { [weak self] in self?.settings.t3Linked = false }
        self.timer.onChange = { [weak self] in self?.syncTimer() }
        self.timer.onPhase = { [weak self] minutes in self?.timerPhase(minutes) }
        self.timer.onDone = { [weak self] done in self?.timerFinished(done) }
        updateCalendar()
        updateAgents()
        updateTimer()
        updateMediaWants()
    }

    /// The media computes the artwork's colour only while the wave shows in it, and reads a Netflix tab for the mini
    /// peek only while that peek could show: on, and the notch neither concealed nor obscured.
    private func updateMediaWants() {
        media.tintsWave = settings.playingWave && settings.waveArtworkColor
        media.peeksPages = settings.peekOnTrackChange && !settings.trackPeekOpensNotch && !concealed && !obscured
    }

    func start() {
        guard !running else { return }
        running = true
        media.start()
        volume.start()
        brightness.start()
        focus.start()
        battery.start()
        audioDevices.start()
        updateSocket()
        updateKeyTap()
        updateScreenshots()
        updateClipboard()
        updateDownloads()
        updateCalendar()
        updateAgents()
        updateTimer()
        syncDictation()
    }

    func stop() {
        running = false
        cancelPendingHover()
        dismissHUD()
        state.dismissLevel()
        endPeek()
        endTrackPeek()
        dismissScreenshot()
        dismissDownload()
        dismissEventPeek()
        state.agentPeek = nil
        media.stop()
        volume.stop()
        brightness.stop()
        focus.stop()
        battery.stop()
        audioDevices.stop()
        keys.stop()
        screenshots.stop()
        updateClipboard()
        downloads.stop()
        calendar.stop()
        travel.stop()
        updateAgents()
        updateTimer()
        syncDictation()
    }

    /// Hiding drops everything under way, including an open or pinned player, so the notch comes back closed. A
    /// Quick Peek waits underneath, like under an indicator, and shows on return if its moment has not passed.
    private func updateConcealment() {
        let next = hidden || locked || surroundings.hide(settings)
        guard next != concealed else { return }
        concealed = next
        updateMediaWants()
        if concealed {
            cancelPendingHover()
            dismissHUD()
            endPeek()
            endTrackPeek()
            dismissScreenshot()
            dismissDownload()
            state.dismiss()
        }
        // The Done row's time stops while it cannot be seen and starts over once it can.
        if state.shape == .timerDone { scheduleTimerDoneEnd() }
        syncTimerDisplay()
        syncDictation()
        startAgentPeekTime()
        startEventPeekTime()
        onLayoutChange?()
    }

    /// The socket listens only while the Sotto link is on, since only Sotto uses it. Stopping the notch, as for sleep,
    /// leaves it open; quitting closes it.
    private func updateSocket() {
        if !settings.sottoLinked { socket.stop() } else if running { socket.start() }
    }

    /// The notch presents dictation whenever it is on screen, the Sotto link is on and the pill is set to show there,
    /// and tells Sotto so: Sotto shows its own recorder exactly while the notch does not. Called on every dictation state change and
    /// whenever visibility or those settings change.
    private func syncDictation() {
        let presenting = running && !concealed && settings.sottoLinked && settings.dictationInNotch
        socket.dictation.presenting = presenting
        let active = presenting && socket.dictation.state != .idle
        guard active != state.dictating else { return }
        if active {
            cancelPendingHover()
            peekTask?.cancel()
            peekTask = nil
            state.beginDictation()
            // A pointer already resting on the notch gets the controls at once; no hover change will report it.
            if geometry?.contains(NSEvent.mouseLocation, .dictation) == true { state.hover(true) }
        } else {
            state.endDictation()
        }
    }

    /// Remembers that the macOS Accessibility dialog was shown; kept outside the settings so a reset does not ask again.
    static let accessibilityAskedKey = "accessibilityAsked"

    /// The key tap runs while the key takeover or the Caps Lock indicator wants it, and watches the Accessibility
    /// permission itself. The macOS permission dialog is shown once ever; afterwards the Sound and Display pages
    /// offer it again on request.
    func updateKeyTap() {
        guard running, settings.replaceSystemHUD || settings.capsLockHUD else { keys.stop(); return }
        keys.start()
        if !keys.available, !defaults.bool(forKey: Self.accessibilityAskedKey) {
            defaults.set(true, forKey: Self.accessibilityAskedKey)
            _ = NotchMediaKeyTap.requestPermission()
        }
    }

    /// Screenshot detection runs only while showing or shelving them is on, so a Desktop location is not read otherwise.
    private func updateScreenshots() {
        guard running, settings.screenshotThumbnail || settings.shelveScreenshots else { screenshots.stop(); return }
        screenshots.start()
    }

    /// The clipboard is watched while its history is on and the notch runs, so not through sleep. Turning the history
    /// off forgets the list and the Shelf page shows files again.
    private func updateClipboard() {
        clipboard.limit = Int(settings.clipboardLimit)
        if running, settings.clipboardHistory { clipboard.start() } else { clipboard.stop() }
        if !settings.clipboardHistory {
            clipboard.clear()
            shelfShowsClipboard = false
        }
    }

    /// The Downloads folder is watched only while download alerts are on, so it is not read otherwise.
    private func updateDownloads() {
        if running, settings.downloadAlerts { downloads.start() } else { downloads.stop() }
    }

    /// The calendar runs while its page is on, time to leave while it is on too; the lead, hidden calendars, buffer
    /// and travel mode follow the settings.
    private func updateCalendar() {
        state.calendarEnabled = settings.calendar
        calendar.lead = settings.calendarLead * 60
        calendar.hiddenCalendars = settings.hiddenCalendars
        travel.buffer = settings.leaveBuffer * 60
        travel.mode = settings.travelMode
        if running, settings.calendar { calendar.start() } else { calendar.stop(); dismissEventPeek() }
        if running, settings.calendar, settings.timeToLeave { travel.start() } else { travel.stop() }
        syncCountdown()
    }

    /// The T3 Code page shows while its link is on; the connection runs while the notch does too.
    private func updateAgents() {
        state.agentsEnabled = settings.t3Linked
        if !settings.agentAlerts { state.agentPeek = nil }
        t3.setEnabled(running && settings.t3Linked)
    }

    /// The timer counts while its page is on and the notch runs; it keeps its end through sleep and quit. Switching
    /// the page off cancels it.
    private func updateTimer() {
        state.timerEnabled = settings.timer
        if !settings.timer { timer.cancel(); timer.dismissDone() }
        if running, settings.timer { timer.start() } else { timer.stop() }
        syncTimer()
        syncTimerDisplay()
    }

    /// The wings show a running or paused timer, and the closed notch drops the Done row once it has finished. A
    /// phase alert shown or waiting for a timer that finished or was cancelled says nothing true any more.
    private func syncTimer() {
        if timer.run == nil {
            alerts.removeAll(where: \.drops)
            if state.hud?.drops == true {
                shownAlert = nil
                hudTask?.cancel()
                state.dismissHUD()
            }
        }
        let countdownShown = state.countdownInWings
        state.timer = settings.timer && timer.run != nil
        state.timerDone = settings.timer && timer.done != nil
        followCountdown(from: countdownShown)
    }

    /// Whether anything on screen shows the timer's seconds: the wings, a phase alert or the open Timer page,
    /// including while a swipe drags the strip and may bring the page into view. Otherwise it ticks no more.
    private func syncTimerDisplay() {
        let wings = state.timer && (state.shape == .indicator && state.hud == nil || state.shape == .timerAlert)
        let page = state.expanded && (state.activity == .timer || swipeOffset != 0)
        timer.displayed = running && !concealed && (wings || page)
    }

    /// A phase alert waits for the wings like any alert; the open Timer page already shows the time.
    private func timerPhase(_ minutes: Int) {
        if state.expanded, state.activity == .timer { return }
        show(.timer(minutes: minutes))
    }

    /// The finish plays its sound and the haptic at once, whatever covers the notch, even hidden or locked; the Done
    /// row waits its turn and until it can be seen. A finish missed while the Mac slept or the app was quit only
    /// shows, briefly.
    private func timerFinished(_ done: NotchTimerDone) {
        guard !done.late else { return }
        playTimerSound()
        if settings.haptics { hapticFeedback() }
    }

    /// The finish sound, also played when one is picked in the settings.
    func playTimerSound() {
        if !settings.timerSound.isEmpty { playSound(settings.timerSound) }
    }

    /// Ends the Done row after its duration, the brief one for a missed finish, unless the pointer holds it or the
    /// notch is concealed; leaving or revealing restarts it. Ending only that finish keeps a late timer from removing
    /// a newer one.
    private func scheduleTimerDoneEnd() {
        timerDoneTask?.cancel()
        guard !pointerOver, !concealed, let done = timer.done else { return }
        let duration = done.late ? NotchTimer.missedDuration : settings.timerDoneDuration
        timerDoneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.timer.done == done else { return }
            self.timer.dismissDone()
        }
    }

    /// The wings count down while an event is coming and the countdown is on.
    private func syncCountdown() {
        let active = running && settings.calendar && settings.calendarCountdown && calendar.countdown != nil
        guard active != state.countdown else { return }
        let shown = state.countdownInWings
        state.countdown = active
        followCountdown(from: shown)
    }

    /// When the countdown takes the wings, as it begins or as a timer leaves them, a closed notch moves to the
    /// Calendar page, so the next open shows the event the wings showed; a swipe away from it sticks. A countdown
    /// beginning under a running timer leaves the page alone.
    private func followCountdown(from shown: Bool) {
        if !shown, state.countdownInWings, !state.expanded { state.activity = .calendar }
    }

    /// Moves the level for a swallowed key and shows the indicator itself: the services read their own writes
    /// back silently. Returns false when the takeover is off, the notch is hidden or the target is unavailable, so
    /// the tap passes the key on to macOS and its own indicator shows instead.
    private func apply(_ press: NotchMediaKeyPress) -> Bool {
        guard settings.replaceSystemHUD, !concealed else { return false }
        let step = press.key == .volumeDown || press.key == .brightnessDown ? -press.stepSize : press.stepSize
        switch press.key {
        case .volumeUp, .volumeDown, .mute:
            guard volume.available else { return false }
            guard press.down else { return true }
            if press.key == .mute { volume.setMuted(!volume.muted) } else { volume.setVolume(volume.level + step) }
            present(.volume)
        case .brightnessUp, .brightnessDown:
            guard brightness.available else { return false }
            guard press.down else { return true }
            brightness.setLevel(brightness.level + step)
            present(.brightness)
        }
        return true
    }

    /// Feedback for a key press: the level row under the open Music page, the wings indicator everywhere else. A
    /// burst of presses keeps the row as it is and only restarts its time, so nothing animates again.
    private func present(_ level: NotchLevel) {
        guard settings.shows(level.hud), state.show(level: level) else { show(level.hud); return }
        scheduleLevelEnd()
    }

    /// The player's Volume button: grows the volume row, switches a brightness row to volume, or retracts it. An
    /// output without volume control still shows its row, dimmed.
    func toggleVolumeLevel() {
        guard running, !concealed else { return }
        if state.level == .volume {
            state.dismissLevel()
        } else if state.show(level: .volume) {
            scheduleLevelEnd()
        }
    }

    /// The pointer resting on the level row or a drag on its slider holds it; once neither does, its time starts over.
    func holdLevel(_ hold: NotchLevelHold, _ on: Bool) {
        if on {
            guard state.level != nil else { return }
            levelHolds.insert(hold)
            levelTask?.cancel()
        } else if levelHolds.remove(hold) != nil {
            scheduleLevelEnd()
        }
    }

    private func scheduleLevelEnd() {
        levelTask?.cancel()
        guard state.level != nil, levelHolds.isEmpty else { return }
        let duration = settings.hudDuration
        levelTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.state.dismissLevel()
        }
    }

    /// The row is gone, by its timer or by the notch closing, the page turning or a drag: nothing holds it any more.
    private func resetLevelTime() {
        levelTask?.cancel()
        levelTask = nil
        levelHolds = []
    }

    /// A level change from outside the app, such as Control Center or a device reporting its own level as it becomes
    /// the output, does not cover a device indicator or push one waiting further back; the volume keys still do,
    /// through `apply`.
    private func volumeChanged() {
        func isDevice(_ hud: NotchHUD) -> Bool { if case .audioDevice = hud { true } else { false } }
        if state.hud.map(isDevice) == true || alerts.contains(where: isDevice) { return }
        show(.volume)
    }

    /// Shows an indicator in the closed notch. Feedback for a key press shows at once or not at all, covering an
    /// alert, which comes back afterwards for the rest of its time. An alert waits until the wings are free and shows
    /// after the alerts before it; a newer one of the same kind replaces it, even while shown.
    func show(_ hud: NotchHUD) {
        guard running, !concealed, settings.shows(hud) else { return }
        let duration = settings.duration(for: hud)
        guard hud.isAlert else { display(hud, for: duration); return }
        let alert = NotchAlert(hud: hud, remaining: duration, arrived: .now)
        if let shown = shownAlert, shown.alert.hud.sameKind(as: hud) {
            shownAlert = nil
            display(alert)
        } else {
            alerts.add(alert)
            showWaitingAlert()
        }
    }

    /// Puts an indicator in the wings and restarts its timer; a burst of key presses reads as one indicator.
    @discardableResult
    private func display(_ hud: NotchHUD, for duration: Double) -> Bool {
        guard state.show(hud) else { return false }
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            // An alert that ran its full time is done; clearing it first keeps it out of the queue.
            self.shownAlert = nil
            self.state.dismissHUD()
        }
        return true
    }

    private func display(_ alert: NotchAlert) {
        guard display(alert.hud, for: alert.remaining) else { return }
        shownAlert = (alert, .now + .seconds(alert.remaining))
    }

    /// Shows the oldest waiting alert once the wings are empty and free.
    private func showWaitingAlert() {
        guard running, !concealed, state.hud == nil, state.wingsFree else { return }
        while let alert = alerts.next(at: .now) {
            // An indicator switched off while it waited is dropped.
            guard settings.shows(alert.hud) else { continue }
            display(alert)
            return
        }
    }

    /// Ends the indicator and forgets waiting alerts: a hidden or stopped notch comes back with nothing pending.
    private func dismissHUD() {
        alerts.removeAll()
        shownAlert = nil
        hudTask?.cancel()
        hudTask = nil
        state.dismissHUD()
    }

    /// A track to announce (see `NotchTrackWatch`), or more of the playing one becoming known. A new track waits until its metadata has been still
    /// for `NotchTrackPeek.settle`, every report meanwhile starting the wait over, so a peek never shows a half-reported
    /// or stale title and rapid skips make one peek. A peek already shown is held meanwhile, so it neither closes nor
    /// flickers before it takes the new track. Outside a wait, what arrives late, such as the artwork or the website,
    /// fills the shown peek in place. Opening the notch forgets a track still settling.
    private func trackChanged(newTrack: Bool) {
        // An open notch shows the track already; only a full peek under way waits for the next one, to stay for it.
        guard running, !concealed, settings.peekOnTrackChange, !state.expanded || state.peeking else { return }
        if newTrack || trackSettleTask != nil {
            trackSettleTask?.cancel()
            trackPeekTask?.cancel()
            // The full peek's time stops too and starts over for the settled track, so it never closes and reopens.
            peekTask?.cancel()
            trackSettleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(NotchTrackPeek.settle))
                guard !Task.isCancelled, let self else { return }
                self.trackSettleTask = nil
                self.peek()
            }
        } else if state.trackPeek != nil, let track = media.nowPlaying {
            state.trackPeek = track
            trackPeekArtwork = media.peekArtwork
            // Its timer ends only the row it was set for: follow the updated one to the same end.
            resumeTrackPeekTime()
        }
    }

    /// The new track has settled. The mini peek shows it in the closed notch, or crossfades the shown one to it and
    /// starts its time over; the full peek opens the closed notch like a hover that ends by itself. No haptic: nothing
    /// is under the fingers. An alert shown or waiting wins over a new peek, which is skipped: the new track is
    /// audible anyway. A peek left showing then runs out its own time, the full one starting over since settling
    /// stopped it.
    private func peek() {
        let alertPending = shownAlert != nil || !alerts.isEmpty
        guard running, !concealed, settings.peekOnTrackChange, let track = media.nowPlaying else {
            resumeTrackPeekTime()
            schedulePeekEnd()
            return
        }
        if settings.trackPeekOpensNotch {
            guard state.peeking || !alertPending, state.peek() else { return }
            schedulePeekEnd()
        } else {
            guard !alertPending, state.show(trackPeek: track) else { resumeTrackPeekTime(); return }
            trackPeekArtwork = media.peekArtwork
            scheduleTrackPeekEnd(after: settings.peekDuration)
        }
    }

    /// A long title's marquee needs `seconds` from now to glide to its end and rest there: the mini peek stays at
    /// least that long, up to `NotchTrackPeek.longestRead`.
    func readTrackPeek(for seconds: Double) {
        guard state.trackPeek != nil, let end = trackPeekEnd else { return }
        let read = ContinuousClock.now + .seconds(min(seconds, NotchTrackPeek.longestRead))
        guard read > end else { return }
        trackPeekEnd = read
        resumeTrackPeekTime()
    }

    private func scheduleTrackPeekEnd(after seconds: Double) {
        trackPeekEnd = .now + .seconds(seconds)
        resumeTrackPeekTime()
    }

    /// Runs the mini peek's time towards its end unless the pointer holds it. Ending only that peek keeps a late
    /// timer from removing a newer one.
    private func resumeTrackPeekTime() {
        trackPeekTask?.cancel()
        trackPeekTask = nil
        guard !pointerOver, let peek = state.trackPeek, let end = trackPeekEnd else { return }
        trackPeekTask = Task { [weak self] in
            try? await Task.sleep(until: end, clock: .continuous)
            guard !Task.isCancelled, let self, self.state.trackPeek == peek else { return }
            self.state.trackPeek = nil
        }
    }

    /// Ends the mini peek and forgets a track still settling: hidden, stopped or switched off.
    private func endTrackPeek() {
        trackSettleTask?.cancel()
        trackSettleTask = nil
        trackPeekTask?.cancel()
        trackPeekTask = nil
        trackPeekEnd = nil
        state.trackPeek = nil
    }

    /// Closes the full peek under way after the peek duration.
    private func schedulePeekEnd() {
        peekTask?.cancel()
        peekTask = nil
        guard state.peeking else { return }
        let duration = settings.peekDuration
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.endPeek()
        }
    }

    /// Ends the full peek; the notch stays open only if the pointer is over it, as after a hold.
    private func endPeek() {
        peekTask?.cancel()
        peekTask = nil
        guard state.peeking else { return }
        let inside = geometry?.contains(NSEvent.mouseLocation, state.expanded ? state.shape : .open) ?? false
        state.endPeek(pointerInside: inside)
    }

    /// Brief hover intent avoids opening on a passing pointer; exit allows small overshoots. Over a screenshot or a
    /// Quick Peek the pointer holds it instead, and leaving restarts its timer; over a track peek it holds it too,
    /// which closes `NotchTrackPeek.linger` after the pointer leaves.
    func hover(_ inside: Bool) {
        cancelPendingHover()
        pointerOver = inside
        guard running, !concealed, !state.dropTargeted else { return }
        // A track peek under an indicator or an alert follows the pointer too, so one held before it was covered
        // still closes once the pointer leaves.
        if state.trackPeek != nil {
            if inside { trackPeekTask?.cancel() } else { scheduleTrackPeekEnd(after: NotchTrackPeek.linger) }
        }
        // So does a download under a screenshot, so one held before it was covered still leaves once the pointer has.
        if state.download != nil {
            if inside { downloadTask?.cancel() } else { scheduleDownloadEnd() }
        }
        switch state.shape {
        case .screenshot:
            if inside { screenshotTask?.cancel() } else { scheduleScreenshotEnd() }
            return
        case .downloadPeek:
            return
        case .eventPeek:
            if inside { eventPeekTask?.cancel() } else { scheduleEventPeekEnd() }
            return
        case .trackPeek:
            return
        case .timerDone:
            if inside { timerDoneTask?.cancel() } else { scheduleTimerDoneEnd() }
            return
        // Hover opens a T3 alert into its thread's page like any closed notch; resting there holds it meanwhile.
        case .agentPeek:
            if inside { agentPeekTask?.cancel() } else { scheduleAgentPeekEnd(); return }
        default: break
        }
        // The dictation controls show on hover even when hover does not open the player.
        if inside, !settings.expandOnHover, !state.dictating { return }
        let delay = inside ? settings.hoverOpenDelay : settings.hoverCloseDelay
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.running else { return }
            self.applyHover(inside)
        }
    }

    /// A deliberate click opens immediately and supersedes pending hover intent. Opened from a track peek, by a click
    /// or a swipe, the notch shows the player for the track it announced.
    func open() {
        cancelPendingHover()
        guard running, !concealed else { return }
        if state.trackPeek != nil { state.activity = .music }
        applyHover(true)
    }

    /// Explicit dismissal must not be undone by an earlier delayed entry.
    func dismiss() { cancelPendingHover(); state.dismiss() }

    func toggleExpanded() { cancelPendingHover(); guard !concealed else { return }; state.toggleExpanded() }

    /// Drag targeting is immediate, independent of pointer hover delay.
    func beginDrag() {
        cancelPendingHover()
        guard running, !concealed else { return }
        dropZone = .shelf
        state.dragEnter()
    }

    func show(_ activity: NotchActivity) { state.activity = activity }

    /// Opens the notch on one T3 thread's page, from an alert or a row of the list.
    func openAgent(_ id: String) {
        if !state.expanded { open() }
        guard state.expanded else { return }
        state.activity = .agents
        state.agentThread = id
    }

    /// Back from a thread's page to the list.
    func closeAgent() { state.agentThread = nil }

    private func cancelPendingHover() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    private func applyHover(_ inside: Bool) {
        let wasExpanded = state.expanded
        state.hover(inside)
        // Haptics mark what the fingers do: opening here, turning a page in `swipe`. Peeks and drops stay silent.
        if inside, !wasExpanded, state.expanded, settings.haptics { hapticFeedback() }
    }

    /// Files dropped on the shelf target join the shelf, which then shows them; the AirDrop target sends them instead.
    func receiveDrop(_ urls: [URL], zone: NotchDropZone) {
        guard !concealed else { return }
        dropLog.notice("Dropped \(urls.count) file URL(s) on \(String(describing: zone), privacy: .public)")
        state.drop()
        switch zone {
        case .shelf:
            shelf.add(urls)
            state.activity = .shelf
            shelfShowsClipboard = false
        case .airDrop:
            send(urls)
        }
    }

    /// Opens the system AirDrop picker and keeps the notch open until it closes.
    func send(_ urls: [URL]) {
        guard !urls.isEmpty, !concealed else { return }
        let sender = NotchAirDrop { [weak self] in
            self?.airDrop = nil
            self?.release()
        }
        guard sender.send(urls) else { return }
        airDrop = sender
        state.hold()
    }

    /// Keeps the notch open while `body` runs, such as the Output menu tracking the pointer outside it.
    func holdOpen(during body: () -> Void) {
        state.hold()
        body()
        release()
    }

    /// Outgoing shelf drags hold the notch open so the drag source survives the pointer leaving.
    func shelfDrag(_ drag: NotchFileDrag) {
        if drag == .began { state.hold() } else { release() }
    }

    /// A new screenshot goes onto the shelf when that setting is on, then peeks out of the notch.
    func receive(screenshot url: URL) {
        if running, settings.shelveScreenshots { shelf.add([url]) }
        show(screenshot: url)
    }

    /// A new screenshot drops the closed notch to show it for `NotchScreenshotThumbnail.duration`; a newer one
    /// replaces it and restarts the countdown. An open notch ignores it, like a track change.
    func show(screenshot url: URL) {
        guard running, !concealed, settings.screenshotThumbnail, !draggingScreenshot, state.show(screenshot: url) else { return }
        scheduleScreenshotEnd()
    }

    /// Opens the shown screenshot in its default app; the peek closes.
    func openScreenshot() {
        guard let url = takeScreenshot() else { return }
        NSWorkspace.shared.open(url)
    }

    /// Keeps the shown screenshot on the shelf, which the next open then shows; the peek closes.
    func shelveScreenshot() {
        guard let url = takeScreenshot() else { return }
        shelf.add([url])
        state.activity = .shelf
        shelfShowsClipboard = false
    }

    /// Dragging the thumbnail shows the drop targets at once, since it starts over the notch; the window controller
    /// closes and reopens them as the drag leaves and returns. The peek stays, without a countdown, until the drag
    /// ends: a file delivered to Shelf, AirDrop or another app ends it, a cancelled drag restarts the countdown.
    func screenshotDrag(_ drag: NotchFileDrag) {
        switch drag {
        case .began:
            draggingScreenshot = true
            screenshotTask?.cancel()
            beginDrag()
        case .ended(let delivered):
            draggingScreenshot = false
            if state.dropTargeted { state.dragExit() }
            if delivered {
                dismissScreenshot()
            } else {
                pointerOver = geometry?.contains(NSEvent.mouseLocation, state.shape) ?? false
                scheduleScreenshotEnd()
            }
        }
    }

    private func takeScreenshot() -> URL? {
        screenshotTask?.cancel()
        return state.screenshot.take()
    }

    private func dismissScreenshot() {
        screenshotTask?.cancel()
        screenshotTask = nil
        state.screenshot.dismiss()
    }

    /// Starts the countdown of the shown screenshot unless the pointer holds it or it is being dragged. Ending only
    /// that screenshot keeps a late timer from removing a newer one.
    private func scheduleScreenshotEnd() {
        screenshotTask?.cancel()
        guard !pointerOver, !draggingScreenshot, let url = state.screenshot.url else { return }
        screenshotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NotchScreenshotThumbnail.duration))
            guard !Task.isCancelled, let self else { return }
            self.state.screenshot.expire(url)
        }
    }

    /// A finished download drops a row from the closed notch for `downloadDuration`; a newer one replaces it and
    /// restarts the countdown. An open notch, dictation and a hidden or locked notch ignore it.
    func show(download: NotchDownload) {
        guard running, !concealed, settings.downloadAlerts, state.show(download: download) else { return }
        scheduleDownloadEnd()
    }

    /// Shows the download in Finder; the row closes.
    func revealDownload() {
        guard let download = state.download else { return }
        dismissDownload()
        NSWorkspace.shared.activateFileViewerSelecting([download.url])
    }

    /// Keeps the download on the shelf, which the next open then shows; the row closes.
    func shelveDownload() {
        guard let download = state.download else { return }
        dismissDownload()
        shelf.add([download.url])
        state.activity = .shelf
        shelfShowsClipboard = false
    }

    func dismissDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state.download = nil
    }

    /// Ends the shown download after its duration unless the pointer holds it; leaving restarts it. Ending only that
    /// download keeps a late timer from removing a newer one.
    private func scheduleDownloadEnd() {
        downloadTask?.cancel()
        guard !pointerOver, let download = state.download else { return }
        let duration = settings.downloadDuration
        downloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.state.download == download else { return }
            self.state.download = nil
        }
    }

    /// A Quick Peek drops a row from the closed notch for the peek duration, if its moment is switched on; a later
    /// one replaces it. Whatever covers the closed notch, or an open notch, holds it back until it is gone; a locked
    /// Mac skips it.
    private func show(eventPeek peek: NotchEventPeek) {
        guard running, !locked, settings.calendar, wants(peek) else { return }
        state.eventPeek = peek
    }

    private func wants(_ peek: NotchEventPeek) -> Bool {
        peek.starting ? settings.calendarPeekAtStart : settings.calendarPeekBefore
    }

    /// Ends the Quick Peek, after a click on it, a switch turning its moment off or the calendar stopping.
    func dismissEventPeek() {
        state.eventPeek = nil
    }

    private func resetEventPeekTime() {
        eventPeekTask?.cancel()
        eventPeekTask = nil
        eventPeekStarted = false
    }

    /// Starts the Quick Peek's time the first time it is on screen. One held back too long, past its moment or after
    /// its event left the agenda, is dropped instead. Returns whether it dropped one.
    @discardableResult
    private func startEventPeekTime() -> Bool {
        guard let peek = state.eventPeek, !eventPeekStarted, !concealed, state.shape == .eventPeek else { return false }
        guard peek.due(at: calendar.previewNow ?? .now), calendar.agenda.events.contains(where: { $0.id == peek.event.id }) else {
            state.eventPeek = nil
            return true
        }
        eventPeekStarted = true
        scheduleEventPeekEnd()
        return false
    }

    /// Ends the Quick Peek after its duration unless the pointer holds it; leaving restarts it. Ending only that peek
    /// keeps a late timer from removing a newer one.
    private func scheduleEventPeekEnd() {
        eventPeekTask?.cancel()
        guard !pointerOver, let peek = state.eventPeek else { return }
        let duration = settings.calendarPeekDuration
        eventPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.state.eventPeek == peek else { return }
            self.state.eventPeek = nil
        }
    }

    /// A thread entering a phase that alerts drops a row from the closed notch for the alert duration, after anything
    /// covering it, like a Quick Peek. Several of one phase merge into a count. Nothing shows while the T3 Code page
    /// is open: the list already says it.
    private func show(agentAlert alert: NotchAgentAlert) {
        guard running, !concealed, settings.t3Linked, settings.agentAlerts else { return }
        if state.expanded, state.activity == .agents { return }
        if var shown = state.agentPeek {
            shown.merge(alert)
            // A merged alert starts over, patience included.
            agentPeekArrived = .now
            state.agentPeek = shown
        } else {
            agentPeekArrived = .now
            state.agentPeek = alert
        }
    }

    private func resetAgentPeekTime() {
        agentPeekTask?.cancel()
        agentPeekTask = nil
        agentPeekStarted = false
    }

    /// Starts the alert's time the first time it is on screen; one that waited longer than an alert may is dropped.
    /// Returns whether it dropped one.
    @discardableResult
    private func startAgentPeekTime() -> Bool {
        guard state.agentPeek != nil, !agentPeekStarted, !concealed, state.shape == .agentPeek else { return false }
        guard ContinuousClock.now - agentPeekArrived < .seconds(NotchAlertQueue.patience) else {
            state.agentPeek = nil
            return true
        }
        agentPeekStarted = true
        scheduleAgentPeekEnd()
        return false
    }

    private func scheduleAgentPeekEnd() {
        agentPeekTask?.cancel()
        guard !pointerOver, let alert = state.agentPeek else { return }
        let duration = settings.agentAlertDuration
        agentPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.state.agentPeek == alert else { return }
            self.state.agentPeek = nil
        }
    }

    private func release() {
        let inside = geometry?.contains(NSEvent.mouseLocation, state.shape) ?? false
        state.release(pointerInside: inside)
    }

    /// Follows a two-finger swipe once it has locked to an axis. Over the open notch, horizontal travel drags the
    /// pages and changes page on release, with a haptic; over the closed one it skips a track. Vertical travel opens the closed
    /// notch (fingers down) or closes the open one (fingers up) as soon as it passes the threshold, once per
    /// gesture; on the idle Timer page's dial it sets the length instead. Returns whether the scroll was used; the
    /// rest reaches the view, so the shelf's grid still scrolls.
    func swipe(_ phase: NotchSwipePhase, dx: CGFloat, dy: CGFloat) -> Bool {
        switch phase {
        case .began:
            swipeTravel = CGSize(width: dx, height: dy)
            swipeAxis = nil
            swipeActed = false
            swipeHandled = false
            swipeDial = timerDialHovered && state.expanded && state.activity == .timer && timer.run == nil && timer.done == nil
            dialSteps = 0
            return false
        case .changed:
            // A concealed notch, hidden or locked, neither opens nor skips tracks.
            guard !concealed else { return false }
            swipeTravel.width += dx
            swipeTravel.height += dy
            if swipeAxis == nil, hypot(swipeTravel.width, swipeTravel.height) > 6 {
                swipeAxis = abs(swipeTravel.width) > abs(swipeTravel.height) ? .horizontal : .vertical
            }
            let travel = swipeTravel
            switch swipeAxis {
            // A thread's page does not slide; the swipe takes it back to the list on release.
            case .horizontal where state.expanded && settings.swipeToPage:
                if state.shape != .thread { swipeOffset = rubberBanded(travel.width) }
            case .horizontal where !state.expanded && settings.swipeToSkip:
                // Fingers moving left ask for the next track, like turning to the next page.
                if abs(travel.width) > Self.flickThreshold { flick { travel.width < 0 ? media.next() : media.previous() } }
            // Fingers up lengthen the timer, like a picker wheel, one detent per `dialDetent` of travel.
            case .vertical where swipeDial:
                let steps = Int(-travel.height / Self.dialDetent)
                guard steps != dialSteps else { break }
                let before = timer.dial
                timer.dial = NotchTimerDial.step(timer.dial, by: steps - dialSteps)
                dialSteps = steps
                if timer.dial != before, settings.haptics { hapticFeedback() }
            case .vertical where verticalSwipe != nil:
                // The wrong direction leaves the gesture unused, so reversing within it still acts.
                switch verticalSwipe {
                case .open where travel.height > Self.flickThreshold: flick { open() }
                case .close where travel.height < -Self.flickThreshold: flick { dismiss() }
                default: break
                }
            default: return false
            }
            swipeHandled = true
            return true
        case .ended:
            // Ends arrive from every window, so the flags are cleared here and not left for the next gesture.
            let handled = swipeHandled
            swipeHandled = false
            swipeActed = false
            defer { endSwipe() }
            if swipeAxis == .horizontal, state.expanded, settings.swipeToPage, abs(swipeTravel.width) > Self.swipeThreshold {
                // Fingers moving left reveal the next view, like turning a page; past the last comes the first.
                let before = state
                state.swipe(by: swipeTravel.width < 0 ? 1 : -1)
                if state != before, settings.haptics { hapticFeedback() }
            }
            return handled
        }
    }

    /// What a vertical swipe would do now: open the closed notch, close the open one, or nothing while the AirDrop
    /// picker holds it open, on a shelf whose grid overflows its row, or on the T3 Code page, which take the scroll.
    private var verticalSwipe: NotchVerticalSwipe? {
        guard settings.swipeToToggle else { return nil }
        if !state.expanded { return .open }
        // The T3 Code list and a thread's page scroll vertically.
        if state.held || state.activity == .shelf && shelfScrolls || state.activity == .agents { return nil }
        return .close
    }

    /// The Shelf page's grid or Clipboard list is longer than it can show, so it takes vertical scrolls.
    private var shelfScrolls: Bool {
        shelfShowsClipboard ? clipboard.history.items.count > NotchClipboard.visibleRows(bodyHeight: settings.expandedHeight)
            : shelf.items.count > NotchShelf.columns
    }

    /// Runs the action once per gesture.
    private func flick(_ action: () -> Void) {
        guard !swipeActed else { return }
        swipeActed = true
        action()
    }

    /// Also called when the notch closes, since the end of a swipe may land in another app. The gesture stays
    /// acted on until its own end, so a swipe that closed the notch does not reopen it on the way.
    private func endSwipe() {
        swipeAxis = nil
        swipeTravel = .zero
        if swipeOffset != 0 { swipeOffset = 0 }
    }

    /// The pages wrap, so the strip follows the fingers for half a page, then resists and never passes a whole one,
    /// beyond which no neighbour waits. A single page resists from the start, showing there is nothing else.
    private func rubberBanded(_ travel: CGFloat) -> CGFloat {
        let width = (geometry ?? .fallback).frame(.open).width
        let paging = state.activities.count > 1
        let free = paging ? width / 2 : 0
        let limit = paging ? width / 2 : width * 0.15
        // Past the free stretch each point of travel moves the strip less, approaching `limit` (UIKit's curve).
        let excess = max(0, abs(travel) - free)
        let distance = min(abs(travel), free) + limit * (1 - 1 / (excess * 0.55 / limit + 1))
        return travel < 0 ? -distance : distance
    }
}

/// What a vertical two-finger swipe does, depending on whether the notch is open.
private enum NotchVerticalSwipe {
    case open, close
}

/// Wraps the system AirDrop service; the completion fires once the picker sends, fails or is cancelled.
@MainActor
private final class NotchAirDrop: NSObject, NSSharingServiceDelegate {
    private let completion: () -> Void

    init(completion: @escaping () -> Void) { self.completion = completion }

    func send(_ urls: [URL]) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return false }
        service.delegate = self
        // The picker belongs to this background app, so bring it forward or it opens behind the frontmost window.
        NSApp.activate()
        service.perform(withItems: urls)
        return true
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { completion() }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) { completion() }
}
