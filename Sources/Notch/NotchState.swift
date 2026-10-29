import Foundation

/// The views an open notch pages between, in swipe order. Paging wraps: after the last comes the first. The timer
/// follows Calendar: both are about time, while Shelf, T3 Code and Notifications are about files and work.
enum NotchActivity: CaseIterable {
    case music, calendar, timer, shelf, agents, notifications
}

/// The open notch's pages as an endless cycle. `turn` counts page turns without wrapping, forward adding one and
/// back taking one, so the view can lay the pages on an unbounded strip keyed by turn and slide every change the
/// way it went, across the wrap included. A page leaving keeps its place on the strip until `settle`, so an outgoing
/// or interrupted slide never changes what it shows, even when the page order changes during it.
struct NotchPages: Equatable {
    /// A page at its place on the strip.
    struct Slot: Hashable {
        let turn: Int
        let page: NotchActivity
    }

    private(set) var current = NotchActivity.music
    private(set) var turn = 0
    /// Pages left since the strip last settled, by turn; they may still be sliding through view.
    private var left: [Int: NotchActivity] = [:]

    /// The page `step` turns from the current one in `order`, wrapping at both ends. A current page missing from
    /// the order counts as the first.
    func page(_ step: Int, in order: [NotchActivity]) -> NotchActivity? {
        guard !order.isEmpty else { return nil }
        let index = order.firstIndex(of: current) ?? 0
        return order[(index + step).modulo(order.count)]
    }

    /// The current page between its neighbours, plus the pages still leaving, for the view's strip. A neighbour
    /// that has not been left follows the order; with two pages the other one sits on both sides, and one page
    /// alone has no neighbours.
    func strip(in order: [NotchActivity]) -> [Slot] {
        let near = order.count > 1 ? turn - 1...turn + 1 : turn...turn
        return Set(near).union(left.keys).sorted().compactMap { place in
            let page = place == turn ? current : left[place] ?? self.page(place - turn, in: order)
            return page.map { Slot(turn: place, page: $0) }
        }
    }

    /// Turns one page forward or back, wrapping; a single page stays put. A page still on its way out comes back as
    /// it shows, unless it has left the order meanwhile.
    mutating func turn(by step: Int, in order: [NotchActivity]) {
        guard order.count > 1 else { return }
        let place = turn + step.signum()
        guard let next = left[place].flatMap({ order.contains($0) ? $0 : nil }) ?? page(step.signum(), in: order)
        else { return }
        slide(to: place, showing: next)
    }

    /// Goes straight to `page`, sliding the shorter way round: forward on a tie or when either page is not in the
    /// order. A page still leaving on that side is never replaced; the current page crossfades into `page` instead.
    mutating func show(_ page: NotchActivity, in order: [NotchActivity]) {
        guard page != current else { return }
        var step = 1
        if let from = order.firstIndex(of: current), let to = order.firstIndex(of: page) {
            let forward = (to - from).modulo(order.count)
            step = forward <= order.count - forward ? 1 : -1
        }
        if let leaving = left[turn + step], leaving != page {
            current = page
        } else {
            slide(to: turn + step, showing: page)
        }
    }

    /// Forgets the pages that have left, once the strip has come to rest and they are off screen.
    mutating func settle() { left = [:] }

    private mutating func slide(to place: Int, showing page: NotchActivity) {
        left[turn] = current
        left[place] = nil
        turn = place
        current = page
    }
}

private extension Int {
    /// The remainder that is never negative, for wrapping an index backwards.
    func modulo(_ count: Int) -> Int { (self % count + count) % count }
}

/// The two drop targets shown while a file drag is over the notch.
enum NotchDropZone {
    case shelf, airDrop

    /// Width of the AirDrop target; the shelf target fills the rest. Shared with the view layout.
    static let airDropWidth: CGFloat = 92
    static let inset: CGFloat = 12
    static let gap: CGFloat = 8

    /// The boundary sits in the middle of the gap between the two targets.
    init(x: CGFloat, width: CGFloat) {
        self = x >= width - Self.inset - Self.airDropWidth - Self.gap / 2 ? .airDrop : .shelf
    }
}

/// A file dragged out of the notch: the drag began, or it ended with the file delivered somewhere or cancelled.
enum NotchFileDrag: Equatable {
    case began, ended(delivered: Bool)
}

/// A system change the closed notch shows briefly before settling back.
enum NotchHUD: Equatable {
    case volume, brightness, focus, battery
    /// Caps Lock turned on or off; the indicator carries the new state.
    case capsLock(on: Bool)
    /// An output device became the output or went away.
    case audioDevice(NotchAudioChange)
    /// Time to leave for this event.
    case leave(NotchEvent)
    /// A running timer reached this many minutes left.
    case timer(minutes: Int)

    /// Alerts report something the system did and wait for the wings if they are busy. The rest answer a key
    /// press and only matter at once.
    var isAlert: Bool {
        switch self {
        case .battery, .focus, .audioDevice, .leave, .timer: true
        case .volume, .brightness, .capsLock: false
        }
    }

    /// The timer's phase alert drops a small row under the wings, so it grows in with the spring; the others widen
    /// the wings at once.
    var drops: Bool { if case .timer = self { true } else { false } }

    /// How long an alert may wait for the wings. "5 min left" is wrong a few seconds on, so it waits only briefly.
    var patience: TimeInterval { drops ? 10 : NotchAlertQueue.patience }

    /// The same indicator whatever it carries, so a newer device change replaces an older one.
    func sameKind(as other: NotchHUD) -> Bool {
        switch (self, other) {
        case (.audioDevice, .audioDevice), (.timer, .timer): true
        default: self == other
        }
    }
}

/// The row a volume or brightness change grows under the open Music page, instead of the wings indicator.
enum NotchLevel: Equatable {
    case volume, brightness

    /// The wings indicator the same change shows everywhere else.
    var hud: NotchHUD { self == .volume ? .volume : .brightness }
}

/// What keeps the level row from retracting: the pointer resting on it or a finger dragging its slider.
enum NotchLevelHold: Hashable {
    case pointer, drag
}

/// An alert waiting for the wings, with the seconds it still has there and when it first arrived. The continuous
/// clock ignores changes to the wall clock.
struct NotchAlert: Equatable {
    let hud: NotchHUD
    var remaining: Double
    let arrived: ContinuousClock.Instant
}

/// Alerts waiting for the closed notch to be free: open, dictating, showing a screenshot or another indicator.
/// They show in order of arrival; a newer alert of the same kind replaces a waiting one, and one that waited longer
/// than its kind's patience, `patience` for most, is dropped as stale.
struct NotchAlertQueue {
    static let patience: TimeInterval = 60
    /// With less than this left, an interrupted alert counts as seen.
    static let minimumRest: Double = 0.5
    private(set) var waiting: [NotchAlert] = []

    var isEmpty: Bool { waiting.isEmpty }

    func contains(where match: (NotchHUD) -> Bool) -> Bool { waiting.contains { match($0.hud) } }

    mutating func add(_ alert: NotchAlert) {
        waiting.removeAll { $0.hud.sameKind(as: alert.hud) }
        waiting.append(alert)
    }

    /// An alert cut short goes first again with the time it had left.
    mutating func resume(_ alert: NotchAlert, remaining: Double) {
        guard remaining >= Self.minimumRest else { return }
        var rest = alert
        rest.remaining = min(remaining, alert.remaining)
        waiting.insert(rest, at: 0)
    }

    /// The oldest alert still worth showing, taken out of the queue.
    mutating func next(at now: ContinuousClock.Instant) -> NotchAlert? {
        waiting.removeAll { now - $0.arrived > .seconds($0.hud.patience) }
        return waiting.isEmpty ? nil : waiting.removeFirst()
    }

    mutating func removeAll() { waiting.removeAll() }

    mutating func removeAll(where match: (NotchHUD) -> Bool) { waiting.removeAll { match($0.hud) } }
}

/// Hover and ordinary clicks open the player; the menu can pin it until dismissed. A file drag over the notch opens it too.
/// While Sotto dictates, the closed notch becomes the dictation pill and hovering it shows Stop and Cancel instead.
struct NotchState: Equatable {
    /// Opening always ends an indicator: the full notch shows more than the wings can. It ends a screenshot too,
    /// except for the drop targets of the screenshot's own drag, a track peek, and a Quick Peek that was there before
    /// it opened. Opening over a T3 alert shows that thread's page, over the timer's Done row the Timer page.
    /// Closing ends a peek, leaves a thread's page for the list and
    /// drops pages still sliding out, so a reopened strip follows the order as it is then.
    var expanded = false {
        didSet {
            if expanded {
                hud = nil
                trackPeek = nil
                if !oldValue { eventPeek = nil }
                if !dropTargeted { screenshot.dismiss() }
                download = nil
                // Only an opening shows the alert's thread; hover reasserting an open notch must not jump pages.
                // Opening over the Done row shows the Timer page, which says Done too.
                if !oldValue {
                    if timerDone, !dropTargeted {
                        activity = .timer
                    } else if let alert = agentPeek, !dropTargeted {
                        activity = .agents
                        agentThread = alert.thread.id
                    } else if noticePeek != nil, !dropTargeted {
                        activity = .notifications
                    }
                    agentPeek = nil
                }
            } else {
                peeking = false
                agentThread = nil
                level = nil
                pages.settle()
            }
        }
    }
    var pinned = false
    /// Set while a track change holds the whole notch open for a moment, the older full peek; the pointer leaving
    /// does not close it.
    var peeking = false
    /// The new track the closed notch drops a slim row for, the lowest passing layer: anything else covers it
    /// while its time runs on. Its timer lives in the experience.
    var trackPeek: NotchTrackPeek?
    /// Indicator in the wings of the closed notch, if any. Timing lives in the experience.
    var hud: NotchHUD?
    /// The new screenshot the closed notch drops down to show. Its countdown lives in the experience.
    var screenshot = NotchScreenshotThumbnail()
    /// The finished download the closed notch drops a row for, shown like a screenshot: at once, under it.
    /// Its countdown lives in the experience.
    var download: NotchDownload?
    /// The calendar event the closed notch drops a row for: the lowest of the passing layers, it waits under
    /// dictation, a screenshot or an indicator and shows once they are gone. Its timer lives in the experience.
    var eventPeek: NotchEventPeek?
    /// A T3 Code thread entering a phase that alerts: the closed notch drops a row for it, above a Quick Peek
    /// and under everything else. Its timer lives in the experience.
    var agentPeek: NotchAgentAlert?
    /// A script notice waiting behind dictation, timers and the existing system and app alerts.
    var noticePeek: NotchNotices.Entry?
    /// The thread whose page replaces the T3 Code list, by ID.
    var agentThread: String?
    /// Drop targets cover the page, and the level row with it.
    var dropTargeted = false {
        didSet { if dropTargeted { level = nil } }
    }
    /// The volume or brightness row under the open Music page. It belongs to that page: closing the notch, turning
    /// the page or a file drag ends it. Its timer lives in the experience.
    private(set) var level: NotchLevel?
    /// Set while the AirDrop picker or an outgoing file drag needs the notch to stay open after the pointer leaves.
    var held = false
    /// Kept across closing, so the notch reopens on the last view.
    private(set) var pages = NotchPages() {
        didSet { if pages.current != .music { level = nil } }
    }
    /// The current view; setting it slides there the shorter way round. A closed notch shows no strip, so nothing
    /// is left sliding.
    var activity: NotchActivity {
        get { pages.current }
        set {
            pages.show(newValue, in: activities)
            if !expanded { pages.settle() }
        }
    }
    /// Off, the Calendar page leaves the swipe order; a notch left on it moves to music.
    var calendarEnabled = true {
        didSet { if !activities.contains(activity) { activity = .music } }
    }
    /// Off, the Timer page leaves the swipe order; the experience cancels the timer.
    var timerEnabled = true {
        didSet { if !activities.contains(activity) { activity = .music } }
    }
    /// Off, the T3 Code page leaves the swipe order and no thread alerts.
    var agentsEnabled = false {
        didSet {
            if !agentsEnabled { agentPeek = nil; agentThread = nil }
            if !activities.contains(activity) { activity = .music }
        }
    }
    /// Off, script notices leave the page order and no temporary notice is drawn.
    var noticesEnabled = false {
        didSet {
            if !noticesEnabled { noticePeek = nil }
            if !activities.contains(activity) { activity = .music }
        }
    }
    /// The closed wings count down to the next event. They widen like an indicator, which covers the countdown
    /// while it shows.
    var countdown = false
    /// A timer runs or is paused: the wings widen to show it, over the event countdown, and an indicator
    /// covers it while it shows.
    var timer = false
    /// The countdown is the one in the wings: a running timer takes them first.
    var countdownInWings: Bool { countdown && !timer }
    /// The timer finished: the closed notch drops the Done row, above a T3 alert and a Quick Peek and under an
    /// indicator. Its time lives in the experience.
    var timerDone = false
    /// Set while the notch presents Sotto's dictation.
    private(set) var dictating = false
    /// The pointer is over the dictation pill, which then shows its controls.
    private(set) var dictationHover = false

    /// The outline to draw: the player wins while open, a thread's page being its larger form, then dictation, then a
    /// screenshot, then a download, then an indicator, a timer phase alert among them, then the timer's Done row, then a T3 alert,
    /// then a Quick Peek, then a script notice, then a track peek, then a running timer or the calendar countdown. Indicators wait their
    /// turn in the experience.
    var shape: NotchShape {
        if expanded {
            if showsThread { return .thread }
            if activity == .notifications, !dropTargeted { return .notifications }
            return level != nil ? .openLevel : .open
        }
        if dictating { return .dictation }
        if screenshot.url != nil { return .screenshot }
        if download != nil { return .downloadPeek }
        if let hud { return hud.drops ? .timerAlert : .indicator }
        if timerDone { return .timerDone }
        if agentPeek != nil { return .agentPeek }
        if eventPeek != nil { return .eventPeek }
        if noticePeek != nil { return .noticePeek }
        if trackPeek != nil { return .trackPeek }
        return countdown || timer ? .indicator : .closed
    }

    /// Two-finger swipes act on the closed wings, an indicator, a track peek and the open player; a screenshot, a
    /// download, a Quick Peek, the timer's Done row, the dictation pill and the drop targets ignore them.
    var acceptsSwipes: Bool {
        switch shape {
        case .closed, .indicator, .timerAlert, .trackPeek, .open, .openLevel, .thread, .notifications: !dropTargeted
        case .screenshot, .downloadPeek, .eventPeek, .agentPeek, .timerDone, .dictation, .noticePeek: false
        }
    }

    /// The open player is on screen: the Music page of the open notch, under no drop targets or thread. The like is
    /// read and the progress ticks only meanwhile, so a closed, concealed or locked notch runs no scripts for them.
    var playerOnScreen: Bool { (shape == .open || shape == .openLevel) && activity == .music && !dropTargeted }

    /// A thread's page shows over the T3 Code list; drop targets cover it like any page.
    private var showsThread: Bool { activity == .agents && agentThread != nil && !dropTargeted }

    /// The views in swipe order, without Calendar, Timer or T3 Code while they are turned off.
    var activities: [NotchActivity] {
        NotchActivity.allCases.filter {
            ($0 != .calendar || calendarEnabled) && ($0 != .timer || timerEnabled) && ($0 != .agents || agentsEnabled)
                && ($0 != .notifications || noticesEnabled)
        }
    }

    /// During dictation the pointer reveals the pill's controls; it closes a notch left open by a drop, never opens one.
    /// Over a screenshot, a download, a Quick Peek or the timer's Done row it holds them rather than opening the player.
    mutating func hover(_ inside: Bool) {
        guard !pinned, !dropTargeted, !held, !peeking,
              ![.screenshot, .downloadPeek, .eventPeek, .timerDone, .noticePeek].contains(shape) else { return }
        if dictating {
            dictationHover = inside
            if !inside { expanded = false }
        } else {
            expanded = inside
        }
    }

    /// Pinning is off during dictation: an open player would hide the only recording indicator.
    mutating func togglePin() {
        guard !dictating else { return }
        pinned.toggle()
        peeking = false
        expanded = pinned
    }

    /// The full peek: a track change opens a closed notch for a moment, or extends a peek under way. Returns false
    /// while the notch is already open for another reason or shows a screenshot, a download, a Quick Peek, a T3 alert
    /// or the timer's Done row, where it would only get in the way.
    mutating func peek() -> Bool {
        if peeking { return true }
        guard !expanded, !dropTargeted, !held, !dictating, screenshot.url == nil, download == nil, eventPeek == nil, agentPeek == nil, noticePeek == nil,
              !timerDone else { return false }
        peeking = true
        expanded = true
        return true
    }

    /// Ends the peek; the notch stays open only under the pointer or when pinned.
    mutating func endPeek(pointerInside: Bool) {
        guard peeking else { return }
        peeking = false
        if !pinned, !dropTargeted, !held { expanded = pointerInside }
    }

    /// The mini peek: shows a new track in the closed notch, or replaces the one shown. Returns false where the full
    /// peek would: an open notch already shows the track or something else, and dictation, a screenshot, a download, a
    /// Quick Peek, a T3 alert or the timer's Done row matter more. An indicator only covers it.
    mutating func show(trackPeek track: NotchTrackPeek) -> Bool {
        guard !expanded, !dropTargeted, !held, !dictating, screenshot.url == nil, download == nil, eventPeek == nil, agentPeek == nil, noticePeek == nil,
              !timerDone else { return false }
        trackPeek = track
        return true
    }

    /// The menu collapses any open player, including one opened only by hover.
    mutating func toggleExpanded() {
        if expanded { dismiss() } else { togglePin() }
    }

    mutating func dismiss() { pinned = false; dropTargeted = false; held = false; expanded = false }

    mutating func dragEnter() { peeking = false; dropTargeted = true; expanded = true }

    mutating func dragExit() { dropTargeted = false; expanded = pinned }

    /// The notch stays open to show the drop result; the next hover exit closes it.
    mutating func drop() { dropTargeted = false }

    /// Moves to the neighbouring view, past the last to the first and back; a single view stays put. From a
    /// thread's page any swipe goes back to the list.
    mutating func swipe(by step: Int) {
        if agentThread != nil { agentThread = nil; return }
        pages.turn(by: step, in: activities)
    }

    /// The page strip has come to rest: pages that left are dropped.
    mutating func settlePages() { pages.settle() }

    mutating func hold() { held = true; expanded = true }

    /// The wings can take an indicator: the notch is closed and shows neither dictation, a screenshot nor a download.
    /// A Quick Peek does not count; indicators cover it.
    var wingsFree: Bool { !expanded && !dictating && screenshot.url == nil && download == nil }

    /// Shows an indicator in the closed notch. Returns false while the notch is open, dictating or shows a
    /// screenshot, where it would be noise.
    mutating func show(_ indicator: NotchHUD) -> Bool {
        guard wingsFree else { return false }
        hud = indicator
        return true
    }

    mutating func dismissHUD() { hud = nil }

    /// Grows the level row under the open Music page, or switches its kind. Returns false anywhere else: closed, on
    /// another page, on a thread or under drop targets, where the wings indicator applies as before.
    mutating func show(level: NotchLevel) -> Bool {
        guard expanded, activity == .music, !dropTargeted else { return false }
        self.level = level
        return true
    }

    mutating func dismissLevel() { level = nil }

    /// Dictation started: the notch closes to the pill, unless a file drag or the AirDrop picker holds it open for now.
    mutating func beginDictation() {
        dictating = true
        dictationHover = false
        pinned = false
        peeking = false
        hud = nil
        level = nil
        // A screenshot being dragged keeps its view, and so its drag, alive.
        if !dropTargeted { screenshot.dismiss() }
        download = nil
        if !dropTargeted, !held { expanded = false }
    }

    mutating func endDictation() {
        dictating = false
        dictationHover = false
    }

    /// A new screenshot replaces the one shown and ends an indicator. Returns false while the notch is open or
    /// dictating, like the track-change peek: the file stays in its folder and nothing covers what the user opened.
    mutating func show(screenshot url: URL) -> Bool {
        guard !expanded, !dictating else { return false }
        hud = nil
        screenshot.show(url)
        return true
    }

    /// A new download replaces the one shown and ends an indicator. Returns false while the notch is open or dictating,
    /// like a screenshot: the file is in Downloads either way.
    mutating func show(download: NotchDownload) -> Bool {
        guard !expanded, !dictating else { return false }
        hud = nil
        self.download = download
        return true
    }

    /// Ends a hold; an unpinned notch then follows the pointer again.
    mutating func release(pointerInside: Bool) {
        guard held else { return }
        held = false
        if !pinned, !dropTargeted { expanded = pointerInside }
    }
}
