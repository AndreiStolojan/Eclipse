import AppKit
import CoreAudio

/// Service stand-ins isolate the production hover scheduler from playback and volume devices.
@MainActor final class NotchMedia {
    var onTrackChange: ((Bool) -> Void)?
    /// Set by the checks as the real media reports the playing track.
    var nowPlaying: NotchTrackPeek?
    let artwork: NSImage? = nil
    let peekArtwork: NSImage? = nil
    var tintsWave = false
    var peeksPages = false
    var webLookupsPaused = false
    private(set) var skips = 0
    private(set) var webLookups = 0
    private var watch = NotchTrackWatch()
    func lookUpWebSite() { webLookups += 1 }
    /// Reports what the system plays as the real media does: through `NotchTrackWatch`, and only news.
    func report(_ title: String?, artist: String? = "Artist", source: String = "Spotify", playing: Bool,
                at now: ContinuousClock.Instant = .now) {
        let newTrack = watch.update(source: source, title: title, artist: artist, playing: playing, at: now)
        let shown = playing ? title.flatMap {
            NotchTrackPeek(title: $0, artist: artist, site: nil, player: source, browser: false)
        } : nil
        guard watch.learn(shown, artwork: nil) || newTrack else { return }
        nowPlaying = shown
        onTrackChange?(newTrack)
    }
    func start() { watch = NotchTrackWatch() }
    func stop() {}
    func next() { skips += 1 }
    func previous() { skips -= 1 }
}
/// Like the real services, the setters read their own writes back without calling `onChange`.
@MainActor final class NotchVolume {
    var onChange: (() -> Void)?
    private(set) var level: Float = 0.5
    private(set) var muted = false
    var available = true
    func start() {}
    func stop() {}
    func setVolume(_ value: Float) { level = max(0, min(1, value)) }
    func setMuted(_ value: Bool) { muted = value }
}
@MainActor final class NotchBrightness {
    var onChange: (() -> Void)?
    private(set) var level: Float = 0.5
    var available = true
    func start() {}
    func stop() {}
    func setLevel(_ value: Float) { level = max(0, min(1, value)) }
}
@MainActor final class NotchBattery {
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
}
/// The real dictation model on a socket that never opens: the checks feed it messages directly.
@MainActor final class NotchSocket {
    let dictation = NotchDictation()
    var acceptsDictation = false
    var onNotice: ((NotchNotice) -> Void)?
    private(set) var listening = false
    func start() { listening = true }
    func stop() { listening = false }
}
/// Countdowns and Quick Peeks are set directly; the agenda logic itself is covered by the core checks.
@MainActor final class NotchCalendar {
    var onCountdownChange: (() -> Void)?
    var onPeek: ((NotchEventPeek) -> Void)?
    let previewNow: Date? = nil
    var onAgendaChange: (() -> Void)?
    var agenda = NotchAgenda() { didSet { onAgendaChange?() } }
    var countdown: NotchCountdown? { didSet { onCountdownChange?() } }
    var lead: TimeInterval = 0
    var hiddenCalendars: Set<String> = []
    private(set) var running = false
    private(set) var accessRefreshes = 0
    func start() { running = true }
    func stop() { running = false; countdown = nil }
    func refreshAccess() { accessRefreshes += 1 }
    func notchOpened() {}
    func notchClosed() {}
}
/// Trips are announced directly; measuring needs Core Location and MapKit, which the checks leave out.
@MainActor final class NotchTravel {
    var onLeave: ((NotchEvent) -> Void)?
    private(set) var shownEvents: [NotchEvent] = []
    func shown(_ event: NotchEvent) { shownEvents.append(event) }
    var mode = NotchTravelMode.driving
    var buffer: TimeInterval = 0
    var agenda = NotchAgenda()
    private(set) var running = false
    func start() { running = true }
    func stop() { running = false }
}
@MainActor final class NotchMediaKeyTap {
    var onPress: ((NotchMediaKeyPress) -> Bool)?
    var onCapsLock: ((Bool) -> Void)?
    private(set) var available = false
    var started = 0
    /// Stands in for the Accessibility grant: without it, start leaves the tap unavailable.
    var granted = true
    static var prompts = 0
    static func requestPermission() -> Bool { prompts += 1; return false }
    func start() { started += 1; available = granted }
    func stop() { available = false }
}

/// Exercises delayed entry, cancellation and haptic dispatch in the actual NotchExperience.
@main
struct NotchHoverChecks {
    @MainActor
    static func main() async throws {
        let suite = "ro.andrei.NotchLab.HoverChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var feedbackCount = 0
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
            print("PASS \(name)")
        }
        // Every experience watches scratch folders for screenshots and Focus: a first listing of the user's Desktop can
        // wait on a macOS permission prompt for as long as nobody answers it, and a real Focus change would show an
        // indicator mid-check. Haptics and sounds are counted or dropped, never performed.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "NotchHoverChecks.\(UUID().uuidString)")
        let scratchShots = scratch.appending(path: "Screenshots"), scratchFocus = scratch.appending(path: "Focus")
        let scratchDownloads = scratch.appending(path: "Downloads")
        for folder in [scratchShots, scratchFocus, scratchDownloads] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The clipboard history reads a private pasteboard, never the user's.
        let scratchBoard = NSPasteboard(name: NSPasteboard.Name("NotchHoverChecks.\(UUID().uuidString)"))
        defer { scratchBoard.releaseGlobally() }
        func makeExperience(calendar: NotchCalendar? = nil, timer: NotchTimer? = nil, defaults: UserDefaults,
                            hapticFeedback: @escaping () -> Void = {},
                            playSound: @escaping (String) -> Void = { _ in }) -> NotchExperience {
            NotchExperience(focus: NotchFocus(directory: scratchFocus), calendar: calendar, timer: timer,
                            screenshots: NotchScreenshots(folder: scratchShots),
                            downloads: NotchDownloads(folder: scratchDownloads),
                            clipboard: NotchClipboard(pasteboard: scratchBoard, access: { .allowed }), defaults: defaults,
                            hapticFeedback: hapticFeedback, playSound: playSound)
        }
        let experience = makeExperience(defaults: defaults, hapticFeedback: { feedbackCount += 1 })
        experience.start()
        check(experience.settings.haptics, "Haptics default on without a stored preference")
        experience.hover(true)
        try await Task.sleep(for: .milliseconds(40))
        check(!experience.state.expanded && feedbackCount == 0, "Passing pointer does not open or vibrate immediately")
        try await Task.sleep(for: .milliseconds(100))
        check(experience.state.expanded && feedbackCount == 1, "Sustained hover opens after the intent delay with one haptic")
        experience.hover(true)
        try await Task.sleep(for: .milliseconds(290))
        check(feedbackCount == 1, "An already-open player does not repeat haptics")
        experience.hover(false)
        try await Task.sleep(for: .milliseconds(120))
        check(!experience.state.expanded, "Hover exit closes after its short grace period")

        experience.hover(true)
        try await Task.sleep(for: .milliseconds(40))
        experience.hover(false)
        try await Task.sleep(for: .milliseconds(290))
        check(!experience.state.expanded && feedbackCount == 1, "Brief fly-by cancels opening and feedback")

        experience.hover(true)
        try await Task.sleep(for: .milliseconds(40))
        experience.dismiss()
        try await Task.sleep(for: .milliseconds(290))
        check(!experience.state.expanded && feedbackCount == 1, "Explicit collapse cancels a pending open")

        experience.hover(true)
        experience.open()
        try await Task.sleep(for: .milliseconds(290))
        check(experience.state.expanded && !experience.state.pinned && feedbackCount == 2,
              "Click opens immediately once without leaving delayed feedback or pinning")
        experience.hover(false)
        try await Task.sleep(for: .milliseconds(30))
        experience.hover(true)
        try await Task.sleep(for: .milliseconds(120))
        check(experience.state.expanded && feedbackCount == 2, "Reentry cancels pending closure without another haptic")
        experience.dismiss()

        experience.hover(true)
        experience.beginDrag()
        experience.state.dragExit()
        try await Task.sleep(for: .milliseconds(290))
        check(!experience.state.expanded && feedbackCount == 2, "Completed drag is not reopened by stale hover intent")

        experience.hover(true)
        experience.hidden = true
        try await Task.sleep(for: .milliseconds(290))
        experience.open()
        check(!experience.state.expanded && feedbackCount == 2, "Hiding cancels hover and suppresses hidden opening or feedback")
        experience.hidden = false

        experience.settings.haptics = false
        experience.open()
        check(feedbackCount == 2, "Explicit haptics-off preference is respected")
        check(!makeExperience(defaults: defaults).settings.haptics, "Settings persist for the next launch")
        check(!experience.media.tintsWave, "The artwork's colour is not computed for a white wave")
        experience.settings.waveArtworkColor = true
        check(experience.media.tintsWave, "A tinted wave asks the media for the artwork's colour")
        experience.settings.playingWave = false
        check(!experience.media.tintsWave, "With the wave off, the colour is not computed")
        experience.settings.playingWave = true
        experience.settings.waveArtworkColor = false
        check(experience.media.peeksPages, "A Netflix tab may be read for the mini peek while one could show")
        experience.hidden = true
        let hiddenPeeks = experience.media.peeksPages
        experience.hidden = false
        experience.obscured = true
        let obscuredPeeks = experience.media.peeksPages
        experience.obscured = false
        experience.settings.trackPeekOpensNotch = true
        let fullPeeks = experience.media.peeksPages
        experience.settings.trackPeekOpensNotch = false
        check(!hiddenPeeks && !obscuredPeeks && !fullPeeks && experience.media.peeksPages,
              "Not while hidden, covered or set to open the whole notch")
        experience.dismiss()
        experience.settings.hoverOpenDelay = 0.3
        experience.hover(true)
        try await Task.sleep(for: .milliseconds(200))
        check(!experience.state.expanded, "A longer open delay keeps the notch closed past the default delay")
        try await Task.sleep(for: .milliseconds(200))
        check(experience.state.expanded, "The configured open delay then opens the notch")
        experience.dismiss()
        experience.settings.expandOnHover = false
        experience.hover(true)
        try await Task.sleep(for: .milliseconds(200))
        check(!experience.state.expanded, "Expand on hover off ignores a resting pointer")
        experience.open()
        check(experience.state.expanded, "A click still opens when expand on hover is off")
        experience.dismiss()
        experience.settings.expandOnHover = true
        experience.hover(true)
        experience.stop()
        try await Task.sleep(for: .milliseconds(290))
        check(!experience.state.expanded && feedbackCount == 2, "Stop cancels pending opening and feedback")

        // Swipes and drops run on a fresh experience so they do not depend on the hover sequence above.
        experience.settings.haptics = true
        let pager = makeExperience(defaults: defaults, hapticFeedback: { feedbackCount += 1 })
        // Paging is checked between Music, Calendar and Shelf; the Timer page has its own checks below.
        pager.settings.timer = false
        pager.start()
        // Closed: fingers moving down open it, once per gesture, with the opening haptic.
        let before = feedbackCount
        _ = pager.swipe(.began, dx: 0, dy: 0)
        check(pager.swipe(.changed, dx: 0, dy: 20) && !pager.state.expanded, "A short swipe down is taken but does not open the notch")
        check(pager.swipe(.changed, dx: 0, dy: 30) && pager.state.expanded && feedbackCount == before + 1,
              "Fingers moving down past 40 pt open the closed notch with the opening haptic")
        check(pager.swipe(.changed, dx: 0, dy: -200) && pager.state.expanded && pager.swipe(.ended, dx: 0, dy: 0),
              "The rest of the gesture is swallowed and does nothing more")
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: 0, dy: -20)
        check(pager.state.expanded, "A short swipe up leaves the open notch")
        _ = pager.swipe(.changed, dx: 0, dy: -30)
        check(!pager.state.expanded && pager.swipeOffset == 0, "Fingers moving up close the open notch")
        _ = pager.swipe(.changed, dx: 0, dy: 100)
        check(!pager.state.expanded && pager.swipe(.ended, dx: 0, dy: 0), "Reversing in the same gesture does not reopen it")
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: 0, dy: -60)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(!pager.state.expanded && feedbackCount == before + 1, "Fingers moving up on the closed notch do nothing")
        check(!pager.swipe(.ended, dx: 0, dy: 0), "An end from another window, after a handled gesture, is not swallowed")
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: 0, dy: -60)
        _ = pager.swipe(.changed, dx: 0, dy: 110)
        check(pager.state.expanded, "Fingers that went up first and then down still open the notch")
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: 0, dy: -60)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(!pager.state.expanded, "The next gesture closes it again")
        pager.toggleExpanded()
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: 0, dy: -60)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(!pager.state.expanded && !pager.state.pinned, "A swipe up closes and unpins a pinned notch")
        pager.open()
        pager.state.hold()
        _ = pager.swipe(.began, dx: 0, dy: 0)
        check(!pager.swipe(.changed, dx: 0, dy: -60) && pager.state.expanded && pager.state.held,
              "A notch held by the AirDrop picker ignores the swipe up")
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        pager.state.release(pointerInside: false)
        // Closed: fingers moving left and right skip tracks, once per gesture.
        let silent = feedbackCount
        _ = pager.swipe(.began, dx: 0, dy: 0)
        check(pager.swipe(.changed, dx: -30, dy: 0) && pager.media.skips == 0, "A short swipe on the closed notch skips nothing")
        _ = pager.swipe(.changed, dx: -30, dy: 0)
        _ = pager.swipe(.changed, dx: -100, dy: 0)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(pager.media.skips == 1 && !pager.state.expanded && pager.state.activity == .music && feedbackCount == silent,
              "Fingers moving left on the closed notch skip to the next track once, silently")
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: 60, dy: 0)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(pager.media.skips == 0, "Fingers moving right go back a track")
        pager.settings.swipeToSkip = false
        _ = pager.swipe(.began, dx: 0, dy: 0)
        check(!pager.swipe(.changed, dx: -60, dy: 0) && pager.media.skips == 0, "Swipe to skip off: the swipe is left alone")
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        pager.settings.swipeToToggle = false
        _ = pager.swipe(.began, dx: 0, dy: 0)
        check(!pager.swipe(.changed, dx: 0, dy: 60) && !pager.state.expanded, "Swipe to open and close off: the notch stays closed")
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        pager.settings.swipeToToggle = true
        // Open: fingers moving left and right page between the views.
        pager.open()
        let opened = feedbackCount
        _ = pager.swipe(.began, dx: 0, dy: 0)
        check(pager.swipe(.changed, dx: -30, dy: 2) && pager.swipeOffset == -30, "A horizontal swipe follows the fingers")
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(pager.state.activity == .music && pager.swipeOffset == 0 && feedbackCount == opened,
              "A short swipe springs back without feedback")
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: -80, dy: 0)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(pager.state.activity == .calendar && feedbackCount == opened + 1 && pager.media.skips == 0,
              "Fingers moving left open the calendar with one haptic, and skip nothing")
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: -80, dy: 0)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(pager.state.activity == .shelf, "A second swipe reaches the shelf")
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: -40, dy: 0)
        check(pager.swipeOffset == -40, "The last view follows the fingers on towards the first")
        _ = pager.swipe(.changed, dx: -40, dy: 0)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(pager.state.activity == .music && pager.swipeOffset == 0 && feedbackCount == opened + 3,
              "Past the last view the swipe wraps to music, with its haptic")
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: 80, dy: 0)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(pager.state.activity == .shelf, "Fingers moving right from music wrap back to the shelf")
        // A swipe ending while the last turn still settles counts from the new page.
        for _ in 0..<2 {
            _ = pager.swipe(.began, dx: 0, dy: 0)
            _ = pager.swipe(.changed, dx: 80, dy: 0)
            _ = pager.swipe(.ended, dx: 0, dy: 0)
        }
        check(pager.state.activity == .music && feedbackCount == opened + 6, "Rapid swipes each turn one page")
        pager.settings.haptics = false
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: -80, dy: 0)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(pager.state.activity == .calendar && feedbackCount == opened + 6, "Haptics off: the page turns silently")
        pager.settings.haptics = true
        // Turning the calendar off while it shows moves to music; with the shelf alone beside it, both sides lead there.
        pager.settings.calendar = false
        check(pager.state.activity == .music && pager.state.activities == [.music, .shelf], "A page switched off while shown leaves for music")
        pager.settings.calendar = true
        // A long drag shows the whole neighbour at most; nothing lies beyond it.
        let pageWidth = (pager.geometry ?? .fallback).frame(.open).width
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: -pageWidth * 3, dy: 0)
        check(pager.swipeOffset < -pageWidth / 2 && pager.swipeOffset > -pageWidth, "A drag past half a page resists and never passes a whole one")
        _ = pager.swipe(.changed, dx: pageWidth * 3, dy: 0)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        pager.settings.swipeToPage = false
        _ = pager.swipe(.began, dx: 0, dy: 0)
        check(!pager.swipe(.changed, dx: -80, dy: 0) && pager.swipeOffset == 0, "Swipe to switch page off: the pages stay put")
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(pager.state.activity == .music && pager.state.expanded, "And release changes nothing")
        pager.settings.swipeToPage = true
        // The shelf's grid takes vertical scrolls while it has files.
        pager.show(.shelf)
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: 0, dy: -60)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(!pager.state.expanded, "On an empty shelf a swipe up closes the notch")
        let swipeFolder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-swipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: swipeFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: swipeFolder) }
        let files = (1...6).map { swipeFolder.appendingPathComponent("\($0).txt") }
        for file in files { try Data().write(to: file) }
        pager.open()
        pager.shelf.add(Array(files.prefix(NotchShelf.columns)))
        pager.show(.shelf)
        _ = pager.swipe(.began, dx: 0, dy: 0)
        _ = pager.swipe(.changed, dx: 0, dy: -60)
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        check(!pager.state.expanded && pager.shelf.items.count == 5, "A shelf whose files fit one row still closes on a swipe up")
        pager.open()
        pager.shelf.add(files)
        _ = pager.swipe(.began, dx: 0, dy: 0)
        check(!pager.swipe(.changed, dx: 0, dy: -60) && pager.state.expanded && pager.shelf.items.count == 6,
              "A vertical scroll is left for the shelf's grid once it overflows its row")
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        pager.shelf.removeAll()
        // The Clipboard list takes vertical scrolls once it has more rows than it shows.
        pager.settings.clipboardHistory = true
        pager.shelfShowsClipboard = true
        let fitting = NotchClipboard.visibleRows(bodyHeight: pager.settings.expandedHeight)
        check(NotchClipboard.visibleRows(bodyHeight: 120) == 2 && fitting == 3 && NotchClipboard.visibleRows(bodyHeight: 260) == 7,
              "The list's visible rows follow the open notch's height")
        for text in (0...fitting).map(String.init) {
            scratchBoard.clearContents()
            scratchBoard.setString("copied \(text)", forType: .string)
            pager.clipboard.poll()
        }
        _ = pager.swipe(.began, dx: 0, dy: 0)
        check(!pager.swipe(.changed, dx: 0, dy: -60) && pager.state.expanded
              && pager.clipboard.history.items.count == fitting + 1,
              "A vertical scroll is left for the Clipboard list once it overflows")
        _ = pager.swipe(.ended, dx: 0, dy: 0)
        pager.receiveDrop([files[0]], zone: .shelf)
        check(!pager.shelfShowsClipboard && pager.state.activity == .shelf, "A file dropped on the shelf shows the files")
        pager.shelf.removeAll()
        pager.shelfShowsClipboard = true
        pager.settings.clipboardHistory = false
        check(pager.clipboard.history.items.isEmpty && !pager.shelfShowsClipboard && !pager.clipboard.running,
              "Turning the clipboard history off forgets it and shows the files")
        pager.show(.music)

        let calendar = NotchCalendar()
        let planner = makeExperience(calendar: calendar, defaults: defaults)
        check(calendar.lead == 15 * 60 && !calendar.running, "The calendar waits for start, with a 15 minute lead")
        planner.start()
        check(calendar.running, "Start runs the calendar")
        let event = NotchEvent(id: "standup", title: "Stand-up", start: .now.addingTimeInterval(600), end: .now.addingTimeInterval(1500))
        calendar.countdown = NotchCountdown(event: event, minutes: 10)
        check(planner.state.countdown && planner.state.shape == .indicator && planner.state.activity == .calendar,
              "A countdown widens the wings and turns the closed notch to the calendar")
        planner.open()
        check(calendar.accessRefreshes == 1, "Opening the notch checks for a calendar grant made in System Settings")
        planner.dismiss()
        planner.show(.music)
        calendar.countdown = NotchCountdown(event: event, minutes: 9)
        check(planner.state.activity == .music, "A swipe away from the calendar sticks while the countdown runs")
        planner.settings.calendarCountdown = false
        check(!planner.state.countdown && planner.state.shape == .closed, "Turning the countdown off closes the wings")
        planner.settings.calendarCountdown = true
        planner.settings.calendarLead = 30
        planner.settings.hiddenCalendars = ["work"]
        check(planner.state.countdown && calendar.lead == 30 * 60 && calendar.hiddenCalendars == ["work"],
              "The lead and hidden calendars follow the settings")
        // Quick Peek: the lowest passing layer. Its time starts when it is first on screen and runs on under whatever
        // covers it; the pointer holds it; each moment has its own switch.
        let soon = NotchEventPeek(event: event, starting: false), starting = NotchEventPeek(event: event, starting: true)
        calendar.agenda = NotchAgenda(events: [event])
        planner.settings.calendarPeekDuration = 0.3
        calendar.onPeek?(soon)
        check(planner.state.shape == .eventPeek, "A Quick Peek drops the closed notch")
        planner.hover(true)
        try await Task.sleep(for: .milliseconds(450))
        check(planner.state.eventPeek != nil && !planner.state.expanded, "The pointer holds a Quick Peek without opening the player")
        planner.hover(false)
        try await Task.sleep(for: .milliseconds(450))
        check(planner.state.eventPeek == nil && planner.state.shape == .indicator, "It leaves after its duration, back to the countdown")
        planner.open()
        calendar.onPeek?(soon)
        check(planner.state.shape == .open && planner.state.eventPeek == soon, "An open notch holds a Quick Peek back")
        planner.dismiss()
        check(planner.state.shape == .eventPeek, "Closing the notch shows it")
        planner.settings.hudDuration = 0.15
        planner.show(.volume)
        check(planner.state.shape == .indicator, "A key press covers it")
        try await Task.sleep(for: .milliseconds(200))
        check(planner.state.shape == .eventPeek, "It comes back after the indicator")
        try await Task.sleep(for: .milliseconds(200))
        check(planner.state.eventPeek == nil, "Its time ran on while it was covered")
        planner.open()
        calendar.onPeek?(soon)
        calendar.agenda = NotchAgenda()
        planner.dismiss()
        check(planner.state.eventPeek == nil && planner.state.shape == .indicator,
              "One whose event left the agenda while it waited is dropped")
        calendar.agenda = NotchAgenda(events: [event])
        calendar.onPeek?(starting)
        planner.settings.calendarPeekAtStart = false
        check(planner.state.eventPeek == nil, "Switching off its moment ends the one shown")
        calendar.onPeek?(starting)
        check(planner.state.eventPeek == nil, "Switching off the peek at start skips it")
        // Time to leave: runs with the calendar, follows the agenda and settings, and says Leave as an alert.
        let travel = planner.travel
        check(travel.running && travel.buffer == 10 * 60 && travel.mode == .driving && travel.agenda == calendar.agenda,
              "Time to leave runs with the calendar, a 10 minute buffer, driving and the current agenda")
        planner.settings.leaveBuffer = 15
        planner.settings.travelMode = .walking
        check(travel.buffer == 15 * 60 && travel.mode == .walking, "The buffer and travel mode follow the settings")
        planner.settings.leaveDuration = 0.2
        travel.onLeave?(event)
        check(planner.state.hud == .leave(event) && planner.state.shape == .indicator && travel.shownEvents == [event],
              "It says Leave in the wings and reports it shown")
        try await Task.sleep(for: .milliseconds(300))
        check(planner.state.hud == nil, "For the leave duration")
        planner.hidden = true
        travel.onLeave?(event)
        check(travel.shownEvents.count == 1, "A hidden notch does not count as shown, so Leave is asked for again")
        planner.hidden = false
        planner.settings.timeToLeave = false
        check(!travel.running && planner.calendar.running, "Switching it off stops only time to leave")
        travel.onLeave?(event)
        check(planner.state.hud == nil, "And keeps it quiet")
        planner.settings.timeToLeave = true
        calendar.onPeek?(NotchEventPeek(event: event, starting: false))
        planner.settings.calendar = false
        check(!calendar.running && !planner.travel.running && !planner.state.countdown && !planner.state.activities.contains(.calendar)
              && planner.state.eventPeek == nil, "Turning the calendar off stops it, ends a Quick Peek and removes its page")
        planner.settings = NotchSettings()
        planner.stop()

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchShelfChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.txt"), second = folder.appendingPathComponent("second.txt")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        pager.receiveDrop([first, second, first], zone: .shelf)
        check(pager.shelf.items.map(\.name) == ["first.txt", "second.txt"] && pager.state.activity == .shelf,
              "Shelf drop adds each file once and shows the shelf")
        pager.shelf.add([second])
        check(pager.shelf.items.count == 2, "A file already on the shelf is not added again")
        let renamed = folder.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: first, to: renamed)
        try FileManager.default.removeItem(at: second)
        pager.shelf.refresh()
        check(pager.shelf.items.map(\.name) == ["renamed.txt"], "A bookmark follows a renamed file and a deleted file leaves")
        check(FileManager.default.fileExists(atPath: renamed.path), "The shelf never moves or deletes originals")
        let trashed = folder.appendingPathComponent(".Trash/trashed.txt")
        try FileManager.default.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: trashed)
        pager.shelf.add([trashed])
        pager.shelf.refresh()
        check(pager.shelf.items.count == 1, "A file in the Trash leaves the shelf")
        let reloaded = NotchShelf(defaults: defaults)
        check(reloaded.items.map(\.name) == ["renamed.txt"], "Shelf items survive a relaunch")
        let shot = folder.appendingPathComponent("shot.png")
        try Data("d".utf8).write(to: shot)
        pager.receive(screenshot: shot)
        check(pager.shelf.items.map(\.name) == ["renamed.txt", "shot.png"], "A new screenshot lands on the shelf")
        pager.shelf.remove(pager.shelf.items[1].id)
        pager.settings.shelveScreenshots = false
        pager.receive(screenshot: shot)
        check(pager.shelf.items.count == 1, "With shelving off a screenshot stays off the shelf")
        pager.shelf.removeAll()
        check(pager.shelf.items.isEmpty && FileManager.default.fileExists(atPath: renamed.path),
              "Clearing the shelf leaves originals in place")
        pager.stop()
        // Indicators: one timer per burst, ended by opening, ignored while open, hidden or switched off.
        let hud = makeExperience(defaults: defaults)
        hud.settings.hudDuration = 0.1
        hud.start()
        hud.show(.volume)
        check(hud.state.hud == .volume && !hud.state.expanded, "A volume change shows the indicator in the closed notch")
        try await Task.sleep(for: .milliseconds(60))
        hud.show(.volume)
        try await Task.sleep(for: .milliseconds(60))
        check(hud.state.hud == .volume, "Another change within the duration keeps the indicator")
        try await Task.sleep(for: .milliseconds(80))
        check(hud.state.hud == nil, "The indicator ends after the duration since the last change")
        hud.show(.brightness)
        hud.open()
        check(hud.state.expanded && hud.state.hud == nil, "Opening during an indicator shows the player instead")
        hud.show(.focus)
        check(hud.state.hud == nil, "Changes while open show nothing extra")
        hud.dismiss()
        try await Task.sleep(for: .milliseconds(150))
        hud.show(.focus)
        check(hud.state.hud == .focus, "A Focus change shows after the notch closes")
        hud.hidden = true
        check(hud.state.hud == nil, "Hiding the notch ends the indicator")
        hud.show(.volume)
        check(hud.state.hud == nil, "A hidden notch shows no indicator")
        hud.hidden = false
        hud.settings.brightnessHUD = false
        hud.show(.brightness)
        check(hud.state.hud == nil, "A switched-off indicator stays off")
        hud.show(.volume)
        hud.stop()
        check(hud.state.hud == nil, "Stop ends the indicator")
        // Key takeover: pressed keys move the level by a step and raise the indicator through the service.
        let typed = makeExperience(defaults: defaults)
        typed.settings.brightnessHUD = true
        typed.start()
        check(typed.keys.available, "The key tap starts with the default setting")
        let volumeUp = NotchMediaKeyPress(subtype: 8, data1: (0 << 16) | (0xA << 8), modifiers: [])!
        check(typed.keys.onPress?(volumeUp) == true && typed.volume.level == 0.5 + 1 / 16 && typed.state.hud == .volume,
              "Volume up is swallowed, raises the level one step and shows the indicator")
        check(typed.keys.onPress?(NotchMediaKeyPress(subtype: 8, data1: (0 << 16) | (0xB << 8), modifiers: [])!) == true
              && typed.volume.level == 0.5 + 1 / 16, "A key release is swallowed and changes nothing")
        typed.state.dismissHUD()
        check(typed.keys.onPress?(NotchMediaKeyPress(subtype: 8, data1: (7 << 16) | (0xA << 8), modifiers: [])!) == true
              && typed.volume.muted && typed.state.hud == .volume, "Mute toggles and shows the indicator")
        check(typed.keys.onPress?(NotchMediaKeyPress(subtype: 8, data1: (3 << 16) | (0xA << 8), modifiers: [.option, .shift])!) == true
              && typed.brightness.level == 0.5 - 1 / 64 && typed.state.hud == .brightness, "Fine brightness down moves a quarter step")
        typed.state.dismissHUD()
        typed.brightness.available = false
        check(typed.keys.onPress?(NotchMediaKeyPress(subtype: 8, data1: (2 << 16) | (0xA << 8), modifiers: [])!) == false
              && typed.brightness.level == 0.5 - 1 / 64 && typed.state.hud == nil,
              "A brightness key passes through to macOS when the display cannot be adjusted")
        typed.volume.available = false
        check(typed.keys.onPress?(volumeUp) == false && typed.state.hud == nil, "A volume key passes through when the output cannot be adjusted")
        typed.volume.available = true
        // Caps Lock rides on the same tap, which stays up for it while the takeover is off; keys then pass through.
        typed.state.dismissHUD()
        typed.keys.onCapsLock?(true)
        check(typed.state.hud == .capsLock(on: true), "Caps Lock turning on shows On")
        typed.keys.onCapsLock?(false)
        check(typed.state.hud == .capsLock(on: false), "Caps Lock turning off shows Off")
        typed.state.dismissHUD()
        typed.settings.replaceSystemHUD = false
        check(typed.keys.available && typed.keys.onPress?(volumeUp) == false && typed.state.hud == nil,
              "With the takeover off the tap stays for Caps Lock and volume keys reach macOS")
        typed.settings.capsLockHUD = false
        check(!typed.keys.available, "With the takeover and Caps Lock off the tap goes")
        typed.keys.onCapsLock?(true)
        check(typed.state.hud == nil, "A switched-off Caps Lock indicator shows nothing")
        typed.settings.replaceSystemHUD = true
        check(typed.keys.available, "Switching the takeover on takes the keys again")
        typed.settings = NotchSettings()
        typed.stop()
        check(!typed.keys.available, "Stop releases the keys")
        // Without the grant the macOS dialog is asked for once ever, not at every start.
        let asked = makeExperience(defaults: defaults)
        asked.keys.granted = false
        asked.start()
        check(!asked.keys.available && NotchMediaKeyTap.prompts == 1, "A missing grant asks for the permission once")
        asked.settings.replaceSystemHUD = false
        asked.settings.replaceSystemHUD = true
        check(!asked.keys.available && NotchMediaKeyTap.prompts == 1, "Later starts do not ask again")
        asked.settings = NotchSettings()
        asked.stop()
        check(defaults.bool(forKey: NotchExperience.accessibilityAskedKey), "The answer is remembered, and a settings reset keeps it")
        // Focus changes are judged per mode: a Do Not Disturb toggled over a scheduled Sleep reads On, then Off.
        let focusDirectory = FileManager.default.temporaryDirectory.appending(path: "NotchFocusChecks.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: focusDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: focusDirectory) }
        func assertions(_ identifiers: [String]) -> Data {
            let records = identifiers.map { "{\"assertionDetails\":{\"assertionDetailsModeIdentifier\":\"\($0)\"}}" }.joined(separator: ",")
            return Data("{\"data\":[{\"storeAssertionRecords\":[\(records)]}]}".utf8)
        }
        let assertionFile = focusDirectory.appending(path: "Assertions.json")
        // Atomic writes replace the file in one step, as macOS does, so each write is one observed state.
        try assertions(["com.apple.sleep.sleep-mode"]).write(to: assertionFile, options: .atomic)
        let watched = NotchFocus(directory: focusDirectory)
        var focusChanges: [String] = []
        watched.onChange = { focusChanges.append("\($0.mode.name) \($0.on ? "on" : "off")") }
        watched.start()
        check(watched.accessible && watched.active.map(\.identifier) == ["com.apple.sleep.sleep-mode"] && watched.change == nil,
              "The asserted modes are read at start, and the baseline is not a change")
        func settle(_ condition: @autoclosure () -> Bool) async throws {
            for _ in 0..<40 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        }
        try assertions(["com.apple.sleep.sleep-mode", "com.apple.donotdisturb.mode.default"]).write(to: assertionFile, options: .atomic)
        try await settle(focusChanges.count == 1)
        check(focusChanges == ["Do Not Disturb on"] && watched.change?.mode.name == "Do Not Disturb" && watched.change?.on == true,
              "A mode added over a standing one reads as that mode turning on")
        try assertions(["com.apple.sleep.sleep-mode"]).write(to: assertionFile, options: .atomic)
        try await settle(focusChanges.count == 2)
        check(focusChanges.last == "Do Not Disturb off" && watched.change?.on == false
              && watched.active.map(\.name) == ["Sleep"], "Removing it reads as Off while Sleep stays the active Focus")
        // The reverse: Sleep ending under a manual Do Not Disturb is Sleep Off, and Do Not Disturb stays active.
        try assertions(["com.apple.sleep.sleep-mode", "com.apple.donotdisturb.mode.default"]).write(to: assertionFile, options: .atomic)
        try await settle(focusChanges.count == 3)
        try assertions(["com.apple.donotdisturb.mode.default"]).write(to: assertionFile, options: .atomic)
        try await settle(focusChanges.count == 4)
        check(focusChanges.last == "Sleep off" && watched.change?.mode.name == "Sleep" && watched.change?.on == false
              && watched.active.map(\.name) == ["Do Not Disturb"], "A background mode ending leaves the shown one active")
        try Data("{ partial".utf8).write(to: assertionFile, options: .atomic)
        try await Task.sleep(for: .milliseconds(200))
        try assertions(["com.apple.donotdisturb.mode.default"]).write(to: assertionFile, options: .atomic)
        try await Task.sleep(for: .milliseconds(200))
        check(focusChanges.count == 4 && watched.active.count == 1, "Unreadable data and a rewrite with the same modes are not changes")
        watched.stop()
        // Track changes. The stand-in media reports them directly; a peek waits until the metadata has been still
        // for `NotchTrackPeek.settle` (0.35 s). Durations leave 100 ms or more between deadlines and checks.
        func play(_ experience: NotchExperience, _ title: String, artist: String? = "Artist", new: Bool = true) {
            experience.media.nowPlaying = NotchTrackPeek(title: title, artist: artist, site: nil, player: "Music", browser: false)
            experience.media.onTrackChange?(new)
        }
        let peek = makeExperience(defaults: defaults, hapticFeedback: { feedbackCount += 1 })
        peek.settings = NotchSettings()
        peek.settings.peekDuration = 0.3
        peek.start()
        let beforePeek = feedbackCount
        play(peek, "One")
        check(peek.state.trackPeek == nil, "A track change waits for its metadata to settle")
        try await Task.sleep(for: .milliseconds(500))
        check(peek.state.shape == .trackPeek && peek.state.trackPeek?.title == "One" && !peek.state.expanded
              && feedbackCount == beforePeek, "then drops the mini peek, without opening the notch or a haptic")
        play(peek, "Two")
        try await Task.sleep(for: .milliseconds(150))
        play(peek, "Three")
        try await Task.sleep(for: .milliseconds(150))
        check(peek.state.trackPeek?.title == "One", "Rapid skips hold the shown peek past its time instead of closing it")
        try await Task.sleep(for: .milliseconds(350))
        check(peek.state.trackPeek?.title == "Three", "then replace it in place with the last track only")
        try await Task.sleep(for: .milliseconds(350))
        check(peek.state.trackPeek == nil, "which starts the time over")
        play(peek, "Four", artist: nil)
        try await Task.sleep(for: .milliseconds(200))
        play(peek, "Four", artist: "Band", new: false)
        try await Task.sleep(for: .milliseconds(250))
        check(peek.state.trackPeek == nil, "An artist arriving after the title starts the wait over")
        try await Task.sleep(for: .milliseconds(200))
        check(peek.state.trackPeek?.detail == "Band", "so the peek shows the title and artist together")
        play(peek, "Four", artist: "Band (Live)", new: false)
        check(peek.state.trackPeek?.detail == "Band (Live)", "Later details fill the shown peek in place")
        peek.hover(true)
        try await Task.sleep(for: .milliseconds(400))
        check(peek.state.trackPeek != nil && !peek.state.expanded, "The pointer holds it without opening the player")
        peek.readTrackPeek(for: 0.3)
        peek.hover(false)
        try await Task.sleep(for: .milliseconds(800))
        check(peek.state.trackPeek != nil, "Leaving gives it a moment")
        try await Task.sleep(for: .milliseconds(350))
        check(peek.state.trackPeek == nil, "then it closes")
        play(peek, "Five")
        try await Task.sleep(for: .milliseconds(450))
        peek.readTrackPeek(for: 0.6)
        try await Task.sleep(for: .milliseconds(400))
        check(peek.state.trackPeek != nil, "A long title's marquee keeps it open to read")
        try await Task.sleep(for: .milliseconds(300))
        check(peek.state.trackPeek == nil, "until its end has shown")
        peek.show(.calendar)
        play(peek, "Six")
        try await Task.sleep(for: .milliseconds(450))
        let beforeClick = feedbackCount
        peek.open()
        check(peek.state.expanded && peek.state.activity == .music && peek.state.trackPeek == nil && feedbackCount == beforeClick + 1,
              "A click opens the player on the Music page")
        play(peek, "Seven")
        try await Task.sleep(for: .milliseconds(450))
        check(peek.state.expanded && peek.state.trackPeek == nil && !peek.state.peeking, "An open notch shows no peek")
        peek.dismiss()
        play(peek, "Eight")
        try await Task.sleep(for: .milliseconds(450))
        peek.show(.volume)
        check(peek.state.shape == .indicator && peek.state.trackPeek?.title == "Eight", "A key press covers it")
        play(peek, "Nine")
        try await Task.sleep(for: .milliseconds(100))
        peek.media.nowPlaying = nil
        peek.media.onTrackChange?(false)
        try await Task.sleep(for: .milliseconds(500))
        check(peek.state.trackPeek == nil, "A player quitting while a track settles shows nothing")
        peek.settings.peekOnTrackChange = false
        play(peek, "Ten")
        try await Task.sleep(for: .milliseconds(450))
        check(peek.state.trackPeek == nil, "Peeks switched off change nothing")
        peek.settings.peekOnTrackChange = true
        play(peek, "Eleven")
        peek.hidden = true
        peek.hidden = false
        try await Task.sleep(for: .milliseconds(450))
        check(peek.state.trackPeek == nil, "Hiding the notch forgets a track still settling")
        play(peek, "Short", artist: nil)
        try await Task.sleep(for: .milliseconds(450))
        play(peek, "Short", artist: "youtube.com", new: false)
        try await Task.sleep(for: .milliseconds(350))
        check(peek.state.trackPeek == nil, "A website arriving after the peek shows does not keep it past its time")
        peek.settings.hudDuration = 0.3
        play(peek, "Held")
        try await Task.sleep(for: .milliseconds(450))
        peek.hover(true)
        peek.show(.volume)
        peek.hover(false)
        try await Task.sleep(for: .milliseconds(1150))
        check(peek.state.hud == nil && peek.state.trackPeek == nil, "Leaving a held peek while an indicator covers it still lets it close")
        play(peek, "Opened")
        peek.open()
        try await Task.sleep(for: .milliseconds(100))
        peek.dismiss()
        try await Task.sleep(for: .milliseconds(400))
        check(peek.state.trackPeek == nil, "Opening the notch forgets a track still settling")
        peek.open()
        play(peek, "While open")
        peek.dismiss()
        try await Task.sleep(for: .milliseconds(450))
        check(peek.state.trackPeek == nil, "A track that changed while the notch was open does not peek once it closes")
        play(peek, "Twelve")
        try await Task.sleep(for: .milliseconds(450))
        peek.stop()
        check(peek.state.trackPeek == nil, "Stop ends a peek")
        check(peek.media.peeksPages, "The mini peek asks for a Netflix tab's read when a track starts")
        // The full peek, kept as a setting: the whole notch opens like a hover for the peek duration.
        peek.settings.trackPeekOpensNotch = true
        check(!peek.media.peeksPages, "The full peek opens the player, which reads the page itself")
        peek.settings.peekDuration = 0.4
        peek.start()
        play(peek, "One")
        try await Task.sleep(for: .milliseconds(450))
        check(peek.state.expanded && peek.state.peeking && peek.state.trackPeek == nil, "The full peek opens the notch")
        peek.hover(false)
        try await Task.sleep(for: .milliseconds(150))
        check(peek.state.expanded, "The pointer leaving does not close it")
        try await Task.sleep(for: .milliseconds(300))
        check(!peek.state.expanded && !peek.state.peeking, "It closes after the peek duration")
        play(peek, "Three")
        try await Task.sleep(for: .milliseconds(450))
        play(peek, "Four")
        try await Task.sleep(for: .milliseconds(450))
        check(peek.state.expanded && peek.state.peeking, "A track change during the full peek extends it")
        try await Task.sleep(for: .milliseconds(450))
        check(!peek.state.expanded, "from when that track settled")
        play(peek, "Five")
        try await Task.sleep(for: .milliseconds(650))
        play(peek, "Six")
        try await Task.sleep(for: .milliseconds(200))
        check(peek.state.expanded && peek.state.peeking, "A skip just before the full peek ends holds it open while the track settles")
        try await Task.sleep(for: .milliseconds(350))
        check(peek.state.expanded && peek.state.peeking, "then gives the settled track the full time")
        try await Task.sleep(for: .milliseconds(300))
        check(!peek.state.expanded && !peek.state.peeking, "and closes after it")
        play(peek, "Seven")
        try await Task.sleep(for: .milliseconds(450))
        peek.settings.trackPeekOpensNotch = false
        check(!peek.state.expanded && !peek.state.peeking, "Switching to the mini peek ends a full one under way")
        peek.settings.trackPeekOpensNotch = true
        play(peek, "Eight")
        try await Task.sleep(for: .milliseconds(450))
        peek.settings.peekOnTrackChange = false
        check(!peek.state.expanded && !peek.state.peeking, "So does switching track peeks off")
        peek.settings.peekOnTrackChange = true
        peek.open()
        play(peek, "Two")
        try await Task.sleep(for: .milliseconds(450))
        check(peek.state.expanded && !peek.state.peeking, "A notch already open does not start a full peek")
        peek.dismiss()
        peek.stop()
        // Playback starting peeks too. The stand-in reports through the real `NotchTrackWatch`, as the real media does.
        let starts = makeExperience(defaults: defaults)
        starts.settings = NotchSettings()
        starts.settings.peekDuration = 0.3
        starts.start()
        starts.media.report("Launch", artist: nil, playing: true)
        try await Task.sleep(for: .milliseconds(450))
        starts.media.report("Launch", playing: true)
        try await Task.sleep(for: .milliseconds(450))
        check(starts.state.trackPeek == nil, "What already plays at launch does not peek, nor its artist arriving later")
        starts.media.report("Launch", playing: false)
        try await Task.sleep(for: .milliseconds(200))
        starts.media.report("Launch", playing: true)
        try await Task.sleep(for: .milliseconds(450))
        check(starts.state.trackPeek == nil, "Resuming the same track after a short pause does not peek")
        starts.media.report(nil, playing: false)
        starts.media.report("Started", playing: true)
        try await Task.sleep(for: .milliseconds(450))
        check(starts.state.shape == .trackPeek && starts.state.trackPeek?.title == "Started",
              "Pressing play on another track from stopped peeks with it")
        try await Task.sleep(for: .milliseconds(350))
        starts.media.report("Started", source: "Safari", playing: true)
        try await Task.sleep(for: .milliseconds(450))
        check(starts.state.trackPeek?.title == "Started", "A different player starting peeks, even with the same title")
        try await Task.sleep(for: .milliseconds(350))
        let pausedAt = ContinuousClock.now
        let longPause = pausedAt + NotchTrackWatch.reminder
        starts.media.report("Started", source: "Safari", playing: false, at: pausedAt)
        starts.media.report("Started", source: "Safari", playing: true, at: longPause)
        starts.media.report("Started", source: "Safari", playing: false, at: longPause + .milliseconds(100))
        try await Task.sleep(for: .milliseconds(450))
        check(starts.state.trackPeek == nil, "A flicker of playing after a long pause shows nothing")
        starts.media.report("Started", source: "Safari", playing: true, at: longPause + .seconds(5))
        try await Task.sleep(for: .milliseconds(450))
        check(starts.state.trackPeek?.title == "Started", "Resuming for real after it still peeks as a reminder")
        try await Task.sleep(for: .milliseconds(350))
        starts.media.report("Started", source: "Safari", playing: false)
        starts.locked = true
        starts.media.report("Locked", artist: nil, playing: true)
        try await Task.sleep(for: .milliseconds(450))
        check(starts.state.trackPeek == nil, "Pressing play while locked does not peek")
        starts.locked = false
        try await Task.sleep(for: .milliseconds(100))
        starts.media.report("Locked", playing: true)
        try await Task.sleep(for: .milliseconds(450))
        check(starts.state.trackPeek == nil, "nor once unlocked, when its artist arrives")
        starts.media.report("Locked", playing: false)
        starts.open()
        starts.media.report("Opened", playing: true)
        starts.dismiss()
        try await Task.sleep(for: .milliseconds(450))
        check(starts.state.trackPeek == nil, "Pressing play in the open notch adds nothing, nor once it closes")
        starts.stop()
        // Screenshots: a capture written the way macOS writes one is reported once it carries the capture mark.
        let shots = FileManager.default.temporaryDirectory.appending(path: "NotchScreenshotChecks.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shots) }
        func capture(_ name: String, marked: Bool = true) throws {
            let hidden = shots.appending(path: "." + name)
            try Data("image".utf8).write(to: hidden)
            try FileManager.default.moveItem(at: hidden, to: shots.appending(path: name))
            guard marked else { return }
            let flag = Data("true".utf8)
            _ = flag.withUnsafeBytes { setxattr(shots.appending(path: name).path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, flag.count, 0, 0) }
        }
        try capture("Before.png")
        let watcher = NotchScreenshots(folder: shots)
        var captured: [String] = []
        watcher.onCapture = { captured.append($0.lastPathComponent) }
        watcher.start()
        try capture("Screenshot 1.png")
        try await settle(captured.count == 1)
        check(captured == ["Screenshot 1.png"], "A new capture is reported after its final rename; earlier files are not")
        try capture("Saved.png", marked: false)
        try capture("Recording.mov")
        try capture("Screenshot 2.png")
        try await settle(captured.count == 2)
        try await Task.sleep(for: .milliseconds(200))
        check(captured == ["Screenshot 1.png", "Screenshot 2.png"],
              "Images without the capture mark and screen recordings are not screenshots, and none repeats")
        watcher.stop()
        try capture("Screenshot 3.png")
        try await Task.sleep(for: .milliseconds(200))
        check(captured.count == 2 && watcher.folder == nil, "A stopped watcher reports nothing")
        // Detection follows its setting.
        let shooter = makeExperience(defaults: defaults)
        shooter.start()
        check(shooter.screenshots.folder != nil, "Screenshot detection runs by default")
        shooter.settings.screenshotThumbnail = false
        check(shooter.screenshots.folder != nil, "Shelving alone keeps watching")
        shooter.settings.shelveScreenshots = false
        check(shooter.screenshots.folder == nil, "Switching both off stops watching")
        shooter.settings.screenshotThumbnail = true
        check(shooter.screenshots.folder != nil, "Switching it on watches again")
        shooter.stop()
        check(shooter.screenshots.folder == nil, "Stop ends detection")
        // Dictation: presented while the notch is on screen, with Sotto told each time that changes.
        check(!NotchSettings().sottoLinked, "The Sotto link is off by default")
        let sotto = makeExperience(defaults: defaults)
        sotto.settings.sottoLinked = false
        sotto.start()
        check(!sotto.socket.listening, "Unlinked, the socket stays closed")
        sotto.stop()
        sotto.settings.sottoLinked = true
        check(!sotto.socket.listening, "Linking a stopped notch waits for its start")
        var replies: [NotchReply] = []
        sotto.socket.dictation.attach { replies.append($0) }
        sotto.start()
        check(sotto.socket.listening, "Linked, the socket listens")
        sotto.socket.dictation.update(NotchDictationUpdate(state: .recording, level: 0.4))
        check(sotto.state.dictating && replies == [.presenting(available: false), .presenting(available: true)],
              "A recording shows the pill and Sotto hears that the notch presents it")
        sotto.settings.expandOnHover = false
        sotto.hover(true)
        try await Task.sleep(for: .milliseconds(200))
        check(sotto.state.dictationHover && !sotto.state.expanded, "Hover shows the controls even with hover opening off")
        sotto.socket.dictation.stop()
        check(replies.last == .stop, "Stop goes back to Sotto")
        sotto.hidden = true
        check(!sotto.state.dictating && replies.last == .presenting(available: false), "Hiding the notch hands dictation back to Sotto")
        sotto.hidden = false
        check(sotto.state.dictating && replies.last == .presenting(available: true), "Showing it again takes dictation back")
        sotto.settings.dictationInNotch = false
        check(!sotto.state.dictating && replies.last == .presenting(available: false), "Choosing the bottom hands dictation back to Sotto")
        sotto.settings.dictationInNotch = true
        check(sotto.state.dictating && replies.last == .presenting(available: true), "Choosing the notch takes it back")
        sotto.socket.dictation.update(NotchDictationUpdate(state: .idle, level: 0))
        check(!sotto.state.dictating, "Idle ends the pill")
        sotto.socket.dictation.update(NotchDictationUpdate(state: .processing, level: 0))
        sotto.socket.dictation.detach()
        check(!sotto.state.dictating, "Sotto quitting mid-dictation ends the pill")
        sotto.stop()
        check(!sotto.socket.dictation.presenting, "Stop tells the next client the notch does not present")
        sotto.settings.sottoLinked = false
        check(!sotto.socket.listening, "Unlinking closes the socket")
        // Script notices have their own opt-in, priority and privacy, independent of Sotto.
        let scripts = makeExperience(defaults: defaults)
        scripts.settings.sottoLinked = false
        scripts.settings.scriptNotices = false
        scripts.start()
        let failure = NotchNotice(title: "Pi backup failed", detail: nil, symbol: nil, tint: .red,
                                  id: "pi.backup", progress: nil)
        scripts.socket.onNotice?(failure)
        check(scripts.notices.history.isEmpty && !scripts.socket.listening,
              "Script notices are off by default and disabled receipts are ignored")
        scripts.settings.scriptNotices = true
        check(scripts.socket.listening && !scripts.socket.acceptsDictation && !scripts.settings.sottoLinked,
              "Notices alone open the socket without opting into dictation")
        scripts.socket.onNotice?(failure)
        scripts.socket.onNotice?(failure)
        check(scripts.state.shape == .noticePeek && scripts.notices.history.count == 1,
              "The socket callback displays one deduplicated script notice")
        scripts.hover(true)
        try await Task.sleep(for: .milliseconds(150))
        check(!scripts.state.expanded && scripts.state.shape == .noticePeek,
              "Hover holds an alert without opening the page")
        scripts.state.timerDone = true
        check(scripts.state.shape == .timerDone, "Timer completion covers script notices")
        scripts.state.timerDone = false
        scripts.settings.sottoLinked = true
        scripts.socket.dictation.update(NotchDictationUpdate(state: .recording, level: 0.4))
        check(scripts.state.shape == .dictation && scripts.notices.next != nil,
              "Dictation covers a script notice and keeps it queued")
        scripts.socket.dictation.update(NotchDictationUpdate(state: .idle, level: 0))
        scripts.openNotifications()
        check(scripts.state.shape == .notifications && scripts.notices.next == nil
              && scripts.notices.history.count == 1,
              "Opening Notifications marks pending alerts seen and preserves history")
        scripts.dismiss()
        scripts.socket.onNotice?(NotchNotice(title: "Build finished", detail: nil, symbol: nil, tint: .green,
                                            id: "build", progress: nil))
        scripts.locked = true
        check(scripts.state.noticePeek == nil && scripts.notices.next == nil,
              "Locking discards pending script text")
        scripts.socket.onNotice?(NotchNotice(title: "During lock", detail: nil, symbol: nil, tint: .white,
                                            id: "locked", progress: nil))
        scripts.locked = false
        check(scripts.state.noticePeek == nil && scripts.notices.history.count == 3,
              "Notices received while locked stay in history and do not flash on unlock")
        scripts.settings.sottoLinked = false
        scripts.settings.scriptNotices = false
        check(scripts.notices.history.isEmpty && !scripts.socket.listening
              && !scripts.state.activities.contains(.notifications),
              "Disabling notices clears history, removes its page and closes the unused socket")
        scripts.stop()
        // The screenshot peek: 1.5 s, held by the pointer and by its own drag, taken by Shelf or a delivered drag.
        let peeker = makeExperience(defaults: defaults)
        peeker.start()
        let shotA = shots.appending(path: "Screenshot 1.png"), shotB = shots.appending(path: "Screenshot 2.png")
        peeker.show(screenshot: shotA)
        peeker.hover(true)
        try await Task.sleep(for: .milliseconds(1700))
        check(peeker.state.screenshot.url == shotA && !peeker.state.expanded, "The pointer holds a screenshot without opening the player")
        peeker.hover(false)
        try await Task.sleep(for: .milliseconds(1000))
        check(peeker.state.screenshot.url == shotA, "Leaving restarts the countdown")
        try await Task.sleep(for: .milliseconds(700))
        check(peeker.state.screenshot.url == nil, "The screenshot leaves 1.5 s after the pointer")
        peeker.show(screenshot: shotA)
        peeker.show(screenshot: shotB)
        peeker.screenshotDrag(.began)
        check(peeker.state.screenshot.url == shotB && peeker.state.dropTargeted && peeker.state.expanded,
              "A newer screenshot replaces the shown one; dragging it opens the drop targets")
        try await Task.sleep(for: .milliseconds(1700))
        check(peeker.state.screenshot.url == shotB && peeker.state.dropTargeted, "A drag keeps the screenshot past its 1.5 s")
        peeker.screenshotDrag(.ended(delivered: false))
        check(peeker.state.screenshot.url == shotB && !peeker.state.expanded, "A cancelled drag brings the peek back")
        peeker.shelveScreenshot()
        check(peeker.state.screenshot.url == nil && peeker.shelf.items.last?.name == "Screenshot 2.png" && peeker.state.activity == .shelf,
              "Shelf keeps the file on the shelf and closes the peek")
        peeker.show(screenshot: shotA)
        peeker.screenshotDrag(.began)
        peeker.screenshotDrag(.ended(delivered: true))
        check(peeker.state.screenshot.url == nil && !peeker.state.expanded, "A drag that delivers the file closes the peek")
        peeker.stop()
        // Downloads: a marked file is reported once written, the row holds under the pointer, Shelf keeps it.
        func download(_ name: String, from: [String]? = nil, quarantined: Bool = true, age: TimeInterval = 0) throws {
            let path = scratchDownloads.appending(path: name).path
            try Data("file".utf8).write(to: URL(fileURLWithPath: path))
            func mark(_ attribute: String, _ value: Data) {
                _ = value.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, value.count, 0, 0) }
            }
            let stamp = String(UInt64(Date.now.timeIntervalSince1970 - age), radix: 16)
            if quarantined { mark("com.apple.quarantine", Data("0083;\(stamp);Safari;".utf8)) }
            if let from {
                mark("com.apple.metadata:kMDItemWhereFroms", try PropertyListSerialization.data(fromPropertyList: from, format: .binary, options: 0))
            }
        }
        let fetcher = makeExperience(defaults: defaults)
        fetcher.start()
        check(!fetcher.downloads.running, "The Downloads folder is not watched by default")
        fetcher.settings.downloadAlerts = true
        fetcher.settings.downloadDuration = 0.3
        check(fetcher.downloads.running, "Turning download alerts on watches it")
        try download("tool.zip", from: ["https://cdn.example/tool.zip", "https://github.com/x/releases"])
        try await settle(fetcher.state.download != nil)
        check(fetcher.state.download?.name == "tool.zip" && fetcher.state.download?.host == "github.com"
              && fetcher.state.download?.quarantined == true && fetcher.state.shape == .downloadPeek,
              "A quarantined download from GitHub drops its row")
        fetcher.hover(true)
        try await Task.sleep(for: .milliseconds(500))
        check(fetcher.state.download != nil && !fetcher.state.expanded, "The pointer holds it without opening the player")
        fetcher.hover(false)
        try await settle(fetcher.state.download == nil)
        check(fetcher.state.download == nil, "It leaves after its duration once the pointer has gone")
        try download("copied.txt", quarantined: false)
        try await Task.sleep(for: .milliseconds(300))
        check(fetcher.state.download == nil, "A file without marks, put there by hand, is not a download")
        try download("old.zip", from: ["https://example.org/old.zip"], age: 2 * 24 * 3600)
        try await Task.sleep(for: .milliseconds(300))
        check(fetcher.state.download == nil, "A copy of a download quarantined days ago is not a new one")
        // A file still waiting for marks is renamed away, and a new download of its name starts: neither the old
        // watch nor the placeholder reports it until the partial is gone.
        try download("race.pdf", quarantined: false)
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.moveItem(at: scratchDownloads.appending(path: "race.pdf"), to: scratchDownloads.appending(path: "moved.pdf"))
        try Data().write(to: scratchDownloads.appending(path: "race.Ab3dEf9h.pdf.part"))
        try download("race.pdf")
        try await Task.sleep(for: .milliseconds(300))
        check(fetcher.state.download == nil, "A replacement whose download is under way is not reported early")
        try FileManager.default.removeItem(at: scratchDownloads.appending(path: "race.Ab3dEf9h.pdf.part"))
        try await settle(fetcher.state.download?.name == "race.pdf")
        check(fetcher.state.download?.name == "race.pdf", "It is reported once its partial file is gone")
        fetcher.dismissDownload()
        try download("covered.zip")
        try await settle(fetcher.state.download?.name == "covered.zip")
        fetcher.hover(true)
        fetcher.show(screenshot: scratchShots.appending(path: "cover.png"))
        fetcher.hover(false)
        check(fetcher.state.shape == .screenshot, "A screenshot covers a held download")
        try await settle(fetcher.state.screenshot.url == nil && fetcher.state.download == nil)
        check(fetcher.state.download == nil, "Leaving while it is covered still lets the download go after its duration")
        try download("paper.pdf")
        try await settle(fetcher.state.download?.name == "paper.pdf")
        fetcher.shelfShowsClipboard = true
        fetcher.shelveDownload()
        check(fetcher.state.download == nil && fetcher.shelf.items.last?.name == "paper.pdf" && fetcher.state.activity == .shelf
              && !fetcher.shelfShowsClipboard,
              "Shelf keeps the download on the shelf, shows the files and closes the row")
        fetcher.settings.downloadAlerts = false
        check(!fetcher.downloads.running, "Turning alerts off stops watching")
        fetcher.shelf.removeAll()
        fetcher.stop()
        // Visibility rules: a condition hides the notch only with its switch on, and the notch returns closed.
        let aside = makeExperience(defaults: defaults)
        aside.settings = NotchSettings()
        aside.start()
        aside.surroundings = NotchSurroundings(fullscreen: true, missionControl: true, game: true)
        check(!aside.concealed, "The surroundings leave the notch alone while the switches are off")
        aside.settings.hideInFullscreen = true
        check(aside.concealed, "Turning a switch on hides the notch at once")
        aside.surroundings = NotchSurroundings()
        check(!aside.concealed, "Leaving fullscreen shows it again")
        aside.settings.hideInMissionControl = true
        aside.toggleExpanded()
        aside.hover(true)
        aside.surroundings = NotchSurroundings(missionControl: true)
        check(aside.concealed && !aside.state.expanded && !aside.state.pinned, "Mission Control closes and unpins the player")
        let volumeKey = NotchMediaKeyPress(subtype: 8, data1: (0 << 16) | (0xA << 8), modifiers: [])!
        aside.show(.volume)
        check(aside.state.hud == nil && aside.keys.onPress?(volumeKey) == false,
              "A hidden notch shows no indicator and leaves the volume keys to macOS")
        aside.hover(true)
        try await Task.sleep(for: .milliseconds(200))
        aside.surroundings = NotchSurroundings()
        try await Task.sleep(for: .milliseconds(200))
        check(!aside.concealed && !aside.state.expanded, "Hover intent from before or during the hide does not reopen the notch")
        aside.settings.hideWhileGaming = true
        aside.surroundings = NotchSurroundings(game: true)
        aside.hidden = true
        aside.surroundings = NotchSurroundings()
        check(aside.concealed, "The user's own hide outlasts the game")
        aside.hidden = false
        check(!aside.concealed, "and ends with the user's show")
        aside.stop()
        // Lock screen: locked or unlocking, the notch conceals itself, so nothing private opens or shows.
        let locked = makeExperience(defaults: defaults)
        locked.settings = NotchSettings()
        locked.start()
        locked.toggleExpanded()
        locked.locked = true
        check(locked.concealed && !locked.state.expanded && !locked.state.pinned, "Locking closes and unpins the notch")
        locked.hover(true)
        try await Task.sleep(for: .milliseconds(200))
        locked.open()
        locked.beginDrag()
        locked.toggleExpanded()
        _ = locked.swipe(.began, dx: 0, dy: 0)
        check(!locked.swipe(.changed, dx: 0, dy: 60) && !locked.state.expanded && !locked.state.dropTargeted,
              "While locked, hover, a click, a drag, a swipe and the menu open nothing")
        let lockedShelf = locked.shelf.items.count
        let lockedFile = FileManager.default.temporaryDirectory.appendingPathComponent("NotchLockCheck-\(UUID().uuidString).png")
        try Data("x".utf8).write(to: lockedFile)
        defer { try? FileManager.default.removeItem(at: lockedFile) }
        locked.receiveDrop([lockedFile], zone: .shelf)
        locked.show(screenshot: lockedFile)
        check(locked.shelf.items.count == lockedShelf && locked.state.screenshot.url == nil,
              "While locked no file lands on the shelf and no screenshot shows")
        locked.show(.battery)
        locked.show(.volume)
        check(locked.state.hud == nil && locked.keys.onPress?(volumeKey) == false,
              "While locked no indicator shows and the volume keys stay with macOS")
        locked.locked = false
        check(!locked.concealed && !locked.state.expanded && locked.state.hud == nil, "Unlocking brings the notch back closed")
        // A Quick Peek and a T3 Code alert waiting behind an indicator, or under a hide, are dropped by a lock rather
        // than shown the moment it unlocks, and none arrives while locked.
        let lockEvent = NotchEvent(id: "lock", title: "Review", start: .now.addingTimeInterval(300), end: .now.addingTimeInterval(900))
        let lockPeek = NotchEventPeek(event: lockEvent, starting: false)
        let lockAlert = NotchAgentAlert(thread: NotchAgentThread(
            id: "t1", title: "Private", projectID: "p", project: "Eclipse", branch: nil, model: "", phase: .done, runID: nil,
            runStarted: nil, runCompleted: nil, updated: .now, requestID: nil, pullRequest: nil))
        locked.show(.volume)
        locked.calendar.onPeek?(lockPeek)
        locked.state.agentPeek = lockAlert
        check(locked.state.hud != nil && locked.state.eventPeek == lockPeek && locked.state.agentPeek == lockAlert,
              "A Quick Peek and a T3 Code alert wait behind an indicator")
        locked.locked = true
        check(locked.state.eventPeek == nil && locked.state.agentPeek == nil, "Locking drops both")
        locked.calendar.onPeek?(lockPeek)
        check(locked.state.eventPeek == nil, "While locked no Quick Peek arrives")
        locked.locked = false
        check(locked.state.shape == .closed, "Unlocking shows nothing private")
        locked.hidden = true
        locked.calendar.onPeek?(lockPeek)
        locked.state.agentPeek = lockAlert
        locked.locked = true
        locked.hidden = false
        check(locked.state.eventPeek == nil && locked.state.agentPeek == nil, "Locking a hidden notch drops them too")
        locked.locked = false
        locked.stop()
        // Output devices: the indicator's duration, and its priority over volume changes it did not cause.
        let routed = makeExperience(defaults: defaults)
        routed.settings = NotchSettings()
        routed.settings.audioDeviceDuration = 0.2
        routed.start()
        let headset = NotchAudioDevice(uid: "AA-BB", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        let joined = NotchHUD.audioDevice(NotchAudioChange(device: headset, connected: true))
        routed.audioDevices.onChange?(NotchAudioChange(device: headset, connected: true))
        routed.volume.onChange?()
        check(routed.state.hud == joined, "A level the new output reports by itself does not cover the device indicator")
        _ = routed.keys.onPress?(NotchMediaKeyPress(subtype: 8, data1: (0 << 16) | (0xA << 8), modifiers: [])!)
        check(routed.state.hud == .volume, "A volume key press does")
        routed.dismiss()
        try await Task.sleep(for: .milliseconds(1700))
        routed.audioDevices.onChange?(NotchAudioChange(device: headset, connected: false))
        try await Task.sleep(for: .milliseconds(100))
        check(routed.state.hud == .audioDevice(NotchAudioChange(device: headset, connected: false)), "A device going away shows")
        try await Task.sleep(for: .milliseconds(200))
        check(routed.state.hud == nil, "The device indicator ends after its own duration")
        routed.settings.audioDeviceHUD = false
        routed.audioDevices.onChange?(NotchAudioChange(device: headset, connected: true))
        check(routed.state.hud == nil, "Switched off, device changes show nothing")
        routed.stop()
        // Who wins the wings: alerts wait for a busy notch, feedback covers them for a moment, peeks give way.
        // Durations leave 150 ms or more between deadlines and checks.
        let busy = makeExperience(defaults: defaults)
        busy.settings = NotchSettings()
        busy.settings.sottoLinked = true
        busy.settings.hudDuration = 0.4
        busy.settings.batteryDuration = 1
        busy.settings.audioDeviceDuration = 0.4
        busy.settings.peekDuration = 0.3
        busy.start()
        busy.open()
        busy.show(.battery)
        check(busy.state.hud == nil && busy.state.expanded, "An alert does not cover an open notch")
        busy.dismiss()
        check(busy.state.hud == .battery, "and shows as soon as it closes")
        busy.show(.volume)
        check(busy.state.hud == .volume, "A key press covers an alert at once")
        try await Task.sleep(for: .milliseconds(550))
        check(busy.state.hud == .battery, "and the alert comes back once the meter ends")
        play(busy, "During an alert")
        try await Task.sleep(for: .milliseconds(400))
        check(busy.state.trackPeek == nil && busy.state.hud == .battery, "A track change during an alert does not peek")
        let pods = NotchAudioDevice(uid: "CC-DD", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)
        let podsOn = NotchAudioChange(device: pods, connected: true)
        busy.audioDevices.onChange?(podsOn)
        check(busy.state.hud == .battery, "A second alert waits for the first")
        busy.volume.onChange?()
        check(busy.state.hud == .battery, "The level a waiting device reports does not cover the alert")
        try await Task.sleep(for: .milliseconds(600))
        check(busy.state.hud == .audioDevice(podsOn), "and the device follows it")
        try await Task.sleep(for: .milliseconds(450))
        check(busy.state.hud == nil, "Each alert keeps its own duration")
        play(busy, "After the alerts")
        try await Task.sleep(for: .milliseconds(400))
        check(busy.state.trackPeek != nil, "With no alert left, track changes peek again")
        busy.show(.battery)
        check(busy.state.shape == .indicator && busy.state.hud == .battery, "and an alert covers the peek")
        busy.hidden = true
        busy.hidden = false
        try await Task.sleep(for: .milliseconds(250))
        busy.socket.dictation.update(NotchDictationUpdate(state: .recording, level: 0.4))
        busy.show(.battery)
        check(busy.state.dictating && busy.state.hud == nil, "Dictation keeps the wings")
        busy.socket.dictation.update(NotchDictationUpdate(state: .idle, level: 0))
        check(busy.state.hud == .battery, "and the alert shows when it ends")
        busy.show(screenshot: URL(fileURLWithPath: "/tmp/notch-alert-shot.png"))
        check(busy.state.shape == .screenshot && busy.state.hud == nil, "A screenshot takes the wings from an alert")
        busy.hidden = true
        busy.hidden = false
        busy.open()
        busy.dismiss()
        check(busy.state.hud == nil, "Hiding the notch forgets waiting alerts")
        busy.stop()
        // The level row: volume and brightness keys grow the open Music page instead of the wings.
        let levelSuite = "ro.andrei.NotchLab.HoverChecks.Level.\(UUID().uuidString)"
        let levelDefaults = UserDefaults(suiteName: levelSuite)!
        defer { levelDefaults.removePersistentDomain(forName: levelSuite) }
        let row = makeExperience(defaults: levelDefaults)
        row.settings.hudDuration = 0.2
        row.start()
        let up = NotchMediaKeyPress(subtype: 8, data1: (0 << 16) | (0xA << 8), modifiers: [])!
        let mute = NotchMediaKeyPress(subtype: 8, data1: (7 << 16) | (0xA << 8), modifiers: [])!
        let brighter = NotchMediaKeyPress(subtype: 8, data1: (2 << 16) | (0xA << 8), modifiers: [])!
        check(row.keys.onPress?(up) == true && row.state.hud == .volume && row.state.level == nil,
              "Closed, a volume key still shows the wings")
        row.state.dismissHUD()
        row.open()
        check(row.keys.onPress?(up) == true && row.state.level == .volume && row.state.shape == .openLevel && row.state.hud == nil,
              "Open on Music, it grows the volume row instead")
        try await Task.sleep(for: .milliseconds(120))
        _ = row.keys.onPress?(up)
        _ = row.keys.onPress?(up)
        try await Task.sleep(for: .milliseconds(120))
        check(row.state.level == .volume && row.volume.level == 0.5 + 4 / 16, "Repeated presses keep the row and restart its time")
        check(row.keys.onPress?(brighter) == true && row.state.level == .brightness, "A brightness key switches the row")
        _ = row.keys.onPress?(mute)
        check(row.state.level == .volume && row.volume.muted, "Mute switches back and mutes")
        try await Task.sleep(for: .milliseconds(260))
        check(row.state.level == nil && row.state.expanded && row.state.shape == .open, "The row retracts after the duration")
        _ = row.keys.onPress?(up)
        row.holdLevel(.pointer, true)
        try await Task.sleep(for: .milliseconds(260))
        check(row.state.level == .volume, "The pointer on the row holds it")
        row.holdLevel(.drag, true)
        row.holdLevel(.pointer, false)
        try await Task.sleep(for: .milliseconds(260))
        check(row.state.level == .volume, "So does a drag after the pointer leaves")
        row.holdLevel(.drag, false)
        try await Task.sleep(for: .milliseconds(120))
        check(row.state.level == .volume, "Letting go starts its time over")
        try await Task.sleep(for: .milliseconds(140))
        check(row.state.level == nil, "and then it retracts")
        row.holdLevel(.pointer, true)
        _ = row.keys.onPress?(up)
        try await Task.sleep(for: .milliseconds(260))
        check(row.state.level == nil, "A hover reported while no row showed does not hold the next one")
        row.toggleVolumeLevel()
        check(row.state.level == .volume, "The Volume button grows the volume row")
        row.toggleVolumeLevel()
        check(row.state.level == nil, "and a second press retracts it")
        _ = row.keys.onPress?(brighter)
        row.toggleVolumeLevel()
        check(row.state.level == .volume, "Over the brightness row it switches to volume")
        row.volume.available = false
        check(row.keys.onPress?(up) == false && row.state.level == .volume,
              "An output without volume control passes the key to macOS and leaves the row to show it dimmed")
        row.volume.available = true
        row.holdLevel(.pointer, true)
        row.state.swipe(by: 1)
        check(row.state.level == nil && row.state.activity == .calendar, "Turning the page retracts the row")
        check(row.keys.onPress?(up) == true && row.state.level == nil && row.state.hud == nil,
              "Other open pages show neither the row nor the wings, as before")
        row.state.swipe(by: -1)
        _ = row.keys.onPress?(up)
        row.dismiss()
        check(row.state.level == nil && row.state.shape == .closed, "Closing mid-grow takes the row with it")
        let lookups = row.media.webLookups
        row.open()
        check(row.state.activity == .music && row.media.webLookups == lookups + 1,
              "Opening on the Music page asks Safari again for a website a failed read left unknown")
        row.settings.volumeHUD = false
        check(row.keys.onPress?(up) == true && row.state.level == nil, "Show volume changes off: no row either")
        row.settings.volumeHUD = true
        _ = row.keys.onPress?(up)
        row.locked = true
        check(row.state.level == nil && !row.state.expanded && row.keys.onPress?(up) == false,
              "Locking ends the row and leaves the keys to macOS")
        check(row.media.webLookupsPaused, "and pauses Safari's website lookups")
        row.locked = false
        check(!row.media.webLookupsPaused, "until it unlocks")
        row.stop()

        // Timer: the wings, phase alerts waiting their turn, the finish and its Done row, a timer restored after
        // the app was away, the dial and the page switch. The timer's clock moves by hand.
        let timerSuite = "ro.andrei.NotchLab.TimerChecks.\(UUID().uuidString)"
        let timerDefaults = UserDefaults(suiteName: timerSuite)!
        defer { timerDefaults.removePersistentDomain(forName: timerSuite) }
        var clock = Date(timeIntervalSinceReferenceDate: 813_000_000.25)
        var sounds: [String] = []
        var buzzes = 0
        let ticking = NotchTimer(defaults: timerDefaults, now: { clock })
        let timed = makeExperience(timer: ticking, defaults: timerDefaults, hapticFeedback: { buzzes += 1 },
                                    playSound: { sounds.append($0) })
        timed.start()
        check(timed.state.activities == [.music, .calendar, .timer, .shelf], "The Timer page is on by default, after Calendar")
        ticking.begin(minutes: 25)
        check(timed.state.timer && timed.state.shape == .indicator && ticking.seconds == 1500, "A running timer widens the closed wings")
        timed.open()
        clock += 15 * 60 + 0.01
        ticking.update()
        clock += 5 * 60
        ticking.update()
        check(timed.state.expanded && timed.state.hud == nil, "A phase alert waits while the notch is open")
        timed.dismiss()
        check(timed.state.hud == .timer(minutes: 5) && timed.state.shape == .timerAlert, "and shows on close, the newest phase only")
        clock += 4 * 60
        ticking.update()
        check(timed.state.hud == .timer(minutes: 1), "A newer phase replaces the one shown")
        timed.show(.timer)
        timed.open()
        let buzzed = buzzes
        clock += 60
        ticking.update()
        check(ticking.done?.late == false && ticking.run == nil && sounds == ["Glass"] && buzzes == buzzed + 1,
              "The finish plays its sound and the haptic once")
        check(timed.state.shape == .open && timed.state.activity == .timer, "The open Timer page shows the finish itself")
        timed.dismiss()
        check(timed.state.shape == .timerDone && !timed.state.timer, "Closing hands it to the Done row, the cut-short phase alert dropped")
        timed.hover(true)
        check(!timed.state.expanded && timed.state.shape == .timerDone, "Hover holds the Done row instead of opening")
        timed.hover(false)
        ticking.dismissDone()
        check(timed.state.shape == .closed, "Stop ends it")
        ticking.begin(minutes: 1)
        clock += 61
        ticking.update()
        timed.show(.music)
        timed.toggleExpanded()
        check(timed.state.activity == .timer && timed.state.timerDone, "Opening over the Done row from the menu shows the Timer page")
        ticking.addMinute()
        check(ticking.done == nil && ticking.run?.total == 60 && timed.state.timer, "+1 min from Done starts a fresh minute")
        timed.dismiss()
        timed.settings.timerDoneDuration = 0.1
        let closedSounds = sounds.count, closedBuzzes = buzzes
        clock += 61
        ticking.update()
        check(timed.state.shape == .timerDone, "A finish in the closed notch drops the Done row")
        check(sounds.count == closedSounds + 1 && buzzes == closedBuzzes + 1, "and plays its sound and the haptic once")
        try await Task.sleep(for: .milliseconds(200))
        check(ticking.done == nil && timed.state.shape == .closed, "The Done row leaves after its duration")
        // The dial: a vertical scroll on the idle page's dial sets the length instead of closing the notch.
        timed.show(.timer)
        timed.open()
        timed.timerDialHovered = true
        let dialed = ticking.dial, dialBuzzes = buzzes
        _ = timed.swipe(.began, dx: 0, dy: 0)
        _ = timed.swipe(.changed, dx: 0, dy: -15)
        check(timed.swipe(.changed, dx: 0, dy: -15) && ticking.dial == dialed + 2 && buzzes == dialBuzzes + 2 && timed.state.expanded,
              "Fingers up on the dial lengthen the timer a detent per 12 pt, each with a haptic")
        _ = timed.swipe(.changed, dx: 0, dy: 12)
        check(ticking.dial == dialed + 1 && timed.state.expanded, "Fingers back down shorten it again")
        _ = timed.swipe(.ended, dx: 0, dy: 0)
        timed.timerDialHovered = false
        _ = timed.swipe(.began, dx: 0, dy: 0)
        _ = timed.swipe(.changed, dx: 0, dy: -60)
        _ = timed.swipe(.ended, dx: 0, dy: 0)
        check(!timed.state.expanded && ticking.dial == dialed + 1, "Off the dial the swipe up closes the notch as usual")
        // Pausing keeps the time left, and both a paused timer and one that ended while away survive a relaunch.
        ticking.begin(minutes: 5)
        clock += 100.4
        ticking.pause()
        clock += 3600
        ticking.update()
        check(ticking.seconds == 200 && ticking.run?.paused == true, "A paused timer keeps its time")
        let relaunched = NotchTimer(defaults: timerDefaults, now: { clock })
        relaunched.update()
        check(relaunched.run == ticking.run && relaunched.seconds == 200, "A paused timer is restored as it was")
        ticking.resume()
        timed.stop()
        clock += 3600
        let returned = NotchTimer(defaults: timerDefaults, now: { clock })
        let back = makeExperience(timer: returned, defaults: timerDefaults, playSound: { sounds.append($0) })
        let played = sounds.count
        back.start()
        check(returned.done?.late == true && returned.run == nil && back.state.shape == .timerDone && sounds.count == played,
              "A timer that ended while the app was away shows Done once, silently")
        check(NotchTimer(defaults: timerDefaults, now: { clock }).run == nil, "and is not stored any more")
        back.settings.timer = true
        returned.begin(minutes: 5)
        back.settings.timer = false
        check(returned.run == nil && returned.done == nil && !back.state.timer && !back.state.activities.contains(.timer),
              "Switching the Timer page off cancels the timer and leaves the swipe order")
        back.stop()
        // Seconds tick only while something shows them; hidden, the timer wakes at its phases and its end.
        let guarded = NotchTimer(defaults: timerDefaults, now: { clock })
        let lockable = makeExperience(timer: guarded, defaults: timerDefaults, playSound: { sounds.append($0) })
        lockable.settings.timer = true
        lockable.settings.timerDoneDuration = 0.1
        lockable.start()
        guarded.begin(minutes: 25)
        check(guarded.displayed && guarded.wakeAt == guarded.run?.nextTick(after: clock), "The closed wings tick each second")
        lockable.hidden = true
        check(!guarded.displayed && guarded.wakeAt == guarded.end?.addingTimeInterval(-600), "Hidden, it wakes only at its next phase")
        clock += 30
        lockable.hidden = false
        check(guarded.displayed && guarded.seconds == 1470 && guarded.wakeAt == guarded.run?.nextTick(after: clock),
              "Back on screen it looks again at once and ticks")
        lockable.show(.music)
        lockable.open()
        check(!guarded.displayed, "The open notch on another page does not tick it")
        lockable.show(.timer)
        check(guarded.displayed, "the Timer page does")
        lockable.dismiss()
        // A finish while locked rings at once; its Done row waits until it can be seen, and locking stops its time.
        lockable.locked = true
        let rung = sounds.count
        clock += 1470
        guarded.update()
        check(sounds.count == rung + 1 && guarded.done?.late == false, "A timer ending while locked still rings")
        try await Task.sleep(for: .milliseconds(200))
        check(guarded.done != nil, "Its Done row waits while the notch is concealed")
        lockable.locked = false
        check(lockable.state.shape == .timerDone, "and shows on unlock")
        try await Task.sleep(for: .milliseconds(200))
        check(guarded.done == nil && lockable.state.shape == .closed, "then leaves after its duration")
        guarded.begin(minutes: 1)
        clock += 61
        guarded.update()
        lockable.locked = true
        try await Task.sleep(for: .milliseconds(200))
        check(guarded.done != nil, "Locking over the Done row stops its time")
        lockable.locked = false
        try await Task.sleep(for: .milliseconds(200))
        check(guarded.done == nil, "and unlocking starts it again")
        // Its end passing while the Mac slept is a miss, however recent.
        guarded.begin(minutes: 1)
        lockable.stop()
        clock += 70
        let quiet = sounds.count
        lockable.start()
        check(guarded.done?.late == true && sounds.count == quiet && lockable.state.shape == .timerDone,
              "A timer that ended 10 s before the Mac woke shows Done silently, as missed")
        // The wake is a relative sleep: setting the clock past the end must look again at once.
        guarded.begin(minutes: 25)
        lockable.hidden = true
        let beforeClock = sounds.count
        clock += 1501
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        check(guarded.run == nil && guarded.done?.late == false && sounds.count == beforeClock + 1,
              "Setting the clock past a timer's end finishes it at once")
        lockable.hidden = false
        lockable.stop()
        // Corrupt defaults never reach the timer.
        let corruptSuite = "ro.andrei.NotchLab.TimerCorrupt.\(UUID().uuidString)"
        let corrupt = UserDefaults(suiteName: corruptSuite)!
        defer { corrupt.removePersistentDomain(forName: corruptSuite) }
        func restored(_ json: String) -> NotchTimer {
            corrupt.set(Data(json.utf8), forKey: NotchTimer.key)
            let timer = NotchTimer(defaults: corrupt, now: { clock })
            timer.update()
            return timer
        }
        check(restored(#"{"run":{"clock":{"paused":{"remaining":30}},"total":60},"dial":5}"#).seconds == 30,
              "A sound stored run restores")
        let oversized = restored(#"{"run":{"clock":{"paused":{"remaining":1e20}},"total":1e20},"dial":100000}"#)
        check(oversized.run == nil && oversized.dial == 720, "An oversized stored run is dropped and the dial clamped")
        oversized.begin(minutes: oversized.dial)
        check(oversized.seconds == 43_200, "so the longest timer starts safely")
        check(restored(#"{"run":{"clock":{"running":{"end":1e300}},"total":60},"dial":5}"#).run == nil,
              "An end far past the timer's length is dropped")
        // Across the round's features: the countdown turns the page only once it shows in the wings, and while locked
        // no timer phase, track peek or like read gets through, nor shows on unlock.
        let mixedSuite = "ro.andrei.NotchLab.MixedChecks.\(UUID().uuidString)"
        let mixedDefaults = UserDefaults(suiteName: mixedSuite)!
        defer { mixedDefaults.removePersistentDomain(forName: mixedSuite) }
        let mixedCalendar = NotchCalendar()
        let mixedTimer = NotchTimer(defaults: mixedDefaults, now: { clock })
        let mixed = makeExperience(calendar: mixedCalendar, timer: mixedTimer, defaults: mixedDefaults)
        mixed.settings.peekDuration = 0.3
        mixed.start()
        mixedTimer.begin(minutes: 25)
        let sync = NotchEvent(id: "sync", title: "Sync", start: .now.addingTimeInterval(600), end: .now.addingTimeInterval(1200))
        mixedCalendar.countdown = NotchCountdown(event: sync, minutes: 10)
        check(mixed.state.countdown && mixed.state.shape == .indicator && mixed.state.activity == .music,
              "A countdown beginning under a running timer leaves the page alone")
        mixedTimer.cancel()
        check(mixed.state.activity == .calendar, "and turns it to Calendar once the timer leaves it the wings")
        mixedTimer.begin(minutes: 25)
        mixed.locked = true
        clock += 15 * 60 + 0.01
        mixedTimer.update()
        check(mixed.state.hud == nil, "While locked a timer phase shows nothing")
        play(mixed, "Locked track")
        try await Task.sleep(for: .milliseconds(450))
        mixed.locked = false
        try await Task.sleep(for: .milliseconds(100))
        check(mixed.state.hud == nil && mixed.state.trackPeek == nil && mixed.state.shape == .indicator,
              "and neither it nor a track change made while locked shows on unlock")
        mixed.show(.music)
        mixed.open()
        check(mixed.state.playerOnScreen, "The open player reads its like")
        mixed.locked = true
        check(!mixed.state.playerOnScreen, "Locking closes it, so no like script runs")
        mixed.locked = false
        mixed.stop()
        print("\(checks) hover, swipe and shelf checks passed")
    }
}
