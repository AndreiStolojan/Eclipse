import AppKit

/// The lock screen's state machine, the unlock animation's timing and the media widget's placement. Nothing
/// here posts the system's lock notifications: they would reach every app on the Mac.
@main
struct NotchLockChecks {
    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
            print("PASS \(name)")
        }

        var state = NotchLockState()
        check(!state.secured && !state.presented, "Unlocked, nothing is concealed or presented")
        state.reconcile(locked: false)
        check(state.phase == .unlocked, "A launch while unlocked plays no unlock")
        state.unlock()
        check(state.phase == .unlocked, "An unlock while unlocked does nothing")
        state.lock()
        check(state.phase == .locked && state.secured && state.presented, "Locking conceals the notch and presents the lock")
        state.unlock()
        check(state.phase == .opening && state.secured && state.presented, "Unlocking opens the shackle, still concealed")
        state.retracted()
        check(state.phase == .opening, "The wing does not retract before the shackle has opened")
        state.opened()
        check(state.phase == .retracting && state.secured, "Then the wing retracts, still concealed")
        state.retracted()
        check(state.phase == .unlocked && !state.secured && !state.presented, "Then the notch is back and the windows go")

        state.lock()
        state.unlock()
        state.lock()
        check(state.phase == .locked, "A relock during the shackle wins")
        state.opened()
        state.retracted()
        check(state.phase == .locked, "and late steps of the earlier unlock do nothing")
        state.unlock()
        state.opened()
        state.lock()
        check(state.phase == .locked, "A relock while the wing retracts wins too")

        state.cover(.asleep, true)
        check(state.phase == .locked && state.secured && !state.presented, "Asleep and locked: concealed, windows down")
        state.cover(.asleep, false)
        state.reconcile(locked: true)
        check(state.phase == .locked && state.presented, "Waking locked shows the lock again")
        state.unlock()
        state.cover(.asleep, true)
        check(state.phase == .unlocked, "Sleeping during the unlock animation skips the rest of it")
        state.cover(.asleep, false)

        state.lock()
        state.cover(.screenSaver, true)
        check(!state.presented, "The screen saver hides the lock")
        state.unlock()
        check(state.phase == .unlocked, "An unlock nobody sees ends at once")
        state.cover(.screenSaver, false)
        check(!state.presented, "and leaves nothing to present when the screen saver stops")

        state.lock()
        state.cover(.displaysAsleep, true)
        check(state.secured && !state.presented, "Displays off: concealed, windows down")
        state.cover(.displaysAsleep, false)
        check(state.presented, "Displays on: the lock is back")

        state.cover(.sessionInactive, true)
        check(!state.presented, "Another user's session never shows this one's lock screen")
        state.cover(.sessionInactive, false)
        state.reconcile(locked: false)
        check(state.phase == .opening, "Returning to the session unlocked plays the unlock")
        state.opened()
        state.retracted()

        for _ in 0..<50 {
            state.lock()
            state.cover(.screenSaver, true)
            state.cover(.screenSaver, false)
            state.unlock()
            state.opened()
            state.retracted()
        }
        check(state == NotchLockState(), "Fifty locks leave the state as it began")

        // The monitor's timing, driven directly: the steps run on their own and a relock cancels them.
        let monitor = NotchLockMonitor()
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.apply { $0.lock() }
        monitor.apply { $0.unlock() }
        check(monitor.state.phase == .opening && changes == 2, "The monitor reports each change once")
        try await Task.sleep(for: .seconds(NotchLockState.openingDuration + 0.15))
        check(monitor.state.phase == .retracting, "The shackle's time passes, then the wing retracts")
        try await Task.sleep(for: .seconds(NotchLockState.retractDuration + 0.15))
        check(monitor.state.phase == .unlocked, "and the notch is back on its own")
        monitor.apply { $0.lock() }
        monitor.apply { $0.unlock() }
        try await Task.sleep(for: .seconds(0.3))
        monitor.apply { $0.lock() }
        try await Task.sleep(for: .seconds(NotchLockState.openingDuration + NotchLockState.retractDuration + 0.2))
        check(monitor.state.phase == .locked, "A relock mid-animation cancels the pending steps")
        monitor.apply { $0.unlock() }
        monitor.skipUnlockAnimation()
        check(monitor.state.phase == .unlocked, "Without a lock on screen the unlock ends at once")
        try await Task.sleep(for: .seconds(NotchLockState.openingDuration + 0.15))
        check(monitor.state.phase == .unlocked, "and no step of it runs later")

        // Lock notifications can arrive late, after the opposite one; the session's own answer decides.
        var session = true
        let reordered = NotchLockMonitor(sessionLocked: { session })
        reordered.screenLockChanged(true)
        // Unlocked and relocked at once: the relock's notification overtakes the unlock's.
        reordered.screenLockChanged(true)
        reordered.screenLockChanged(false)
        check(reordered.state.phase == .locked, "A stale unlock after a relock does not start the animation")
        try await Task.sleep(for: .seconds(NotchLockMonitor.recheckDelay + NotchLockState.openingDuration + 0.2))
        check(reordered.state.phase == .locked && reordered.state.secured, "and the notch stays concealed")
        // Locked and unlocked at once: the lock's notification comes last.
        session = false
        reordered.screenLockChanged(false)
        reordered.screenLockChanged(true)
        try await Task.sleep(for: .seconds(NotchLockMonitor.recheckDelay + NotchLockState.openingDuration
                                           + NotchLockState.retractDuration + 0.2))
        check(reordered.state.phase == .unlocked, "A stale lock after an unlock does not conceal the notch")
        // The session flag trailing a real unlock: read again shortly after.
        session = true
        reordered.screenLockChanged(true)
        reordered.screenLockChanged(false)
        check(reordered.state.phase == .locked, "An unlock the session does not confirm yet waits")
        session = false
        try await Task.sleep(for: .seconds(NotchLockMonitor.recheckDelay + 0.15))
        check(reordered.state.phase == .opening, "and plays once the session agrees")
        reordered.stop()

        // Placement: low on the screen like an iPhone's Now Playing card, a gap above the login block, below the clock.
        typealias Layout = NotchLockScreenLayout
        /// The widget's top and bottom, and the login block's top, in points from the top of the screen.
        func edges(_ frame: CGRect, _ screen: CGRect) -> (top: CGFloat, bottom: CGFloat, login: CGFloat) {
            (screen.maxY - frame.maxY, screen.maxY - frame.minY, Layout.loginTop(screen.height))
        }
        func clear(_ frame: CGRect, _ screen: CGRect) -> Bool {
            let (top, bottom, login) = edges(frame, screen)
            return top >= Layout.clockBottom(screen.height) - 0.5 && bottom <= login - Layout.minimumGap + 0.5
        }
        let macBook = CGRect(x: 0, y: 0, width: 1470, height: 956)
        /// The widget's frame, or a rect that fails every placement check when it does not fit.
        func widget(_ screen: CGRect, _ offset: Double) -> CGRect { Layout.widgetFrame(in: screen, offset: offset) ?? .zero }
        let placed = widget(macBook, 0)
        let (top, bottom, login) = edges(placed, macBook)
        check(placed.size == Layout.widgetSize && placed.midX == 735, "The widget is centred")
        // The real lock screen at 1470 × 956: the clock ends 24.5 % down, the user picture starts 82.6 % down.
        check(top > 0.245 * 956 && bottom + Layout.gap <= 0.826 * 956, "Clear of the measured clock and user picture")
        check(abs(login - bottom - Layout.gap) <= 0.5 && top / 956 > 0.6, "In the lower part, \(Int(Layout.gap)) pt above the login block")
        for offset in [-1000.0, Layout.offsetRange.lowerBound, Layout.offsetRange.upperBound, 1000] {
            check(clear(widget(macBook, offset), macBook), "Offset \(offset) stays in the band")
        }
        let lowest = widget(macBook, Layout.offsetRange.upperBound)
        check(abs(login - edges(lowest, macBook).bottom - Layout.minimumGap) <= 0.5,
              "The slider's lowest place leaves the least gap, and no lower")
        check(widget(macBook, -40).midY == placed.midY + 40, "A negative offset moves it up")
        let external = CGRect(x: -1920, y: 180, width: 1920, height: 1080)
        let outside = widget(external, 0)
        check(outside.midX == -960 && clear(outside, external), "An offset external display places it on that display")
        for screen in [CGRect(x: 0, y: 0, width: 1280, height: 800), CGRect(x: 0, y: 0, width: 1512, height: 982),
                       CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: 0, y: 0, width: 2560, height: 1440),
                       CGRect(x: 0, y: 0, width: 3008, height: 1692)] {
            let frame = widget(screen, 0)
            let (_, bottom, login) = edges(frame, screen)
            // A login block placed by proportion (82.6 %) or from the bottom edge (172 pt up) is clear either way.
            check(clear(frame, screen) && bottom + Layout.gap <= min(0.826 * screen.height, screen.height - 172) + 0.5
                  && login - bottom >= Layout.gap - 0.5, "\(Int(screen.width)) × \(Int(screen.height)): \(Int(Layout.gap)) pt above the login block")
            let stage = Layout.stage(in: screen, offset: 0)!
            let artTop = screen.maxY - stage.art.maxY
            check(stage.canEnlarge && artTop >= Layout.clockBottom(screen.height) + Layout.artPadding - 0.5
                  && stage.art.minY - stage.widget.maxY == Layout.artGap && stage.art.midX == stage.widget.midX
                  && Int(stage.art.width) % 2 == 0, "\(Int(screen.width)) × \(Int(screen.height)): the artwork fills the band below the clock")
        }
        // Every screen height and offset: the widget and the large window, padding included, clear the clock and the
        // login block, or there is no widget at all. The window holds the artwork with its padding all round.
        let heights = stride(from: 300.0, through: 1800, by: 4)
        let offsets = [-1000.0, Layout.offsetRange.lowerBound, 0, Layout.offsetRange.upperBound, 1000]
        let stages = heights.flatMap { height in
            offsets.map { (CGRect(x: 0, y: 0, width: 1280, height: height), Layout.stage(in: CGRect(x: 0, y: 0, width: 1280, height: height), offset: $0)) }
        }
        check(stages.allSatisfy { screen, stage in
            guard let stage else { return Layout.widgetFrame(in: screen, offset: 0) == nil }
            let clock = Layout.clockBottom(screen.height), floor = Layout.loginTop(screen.height) - Layout.minimumGap
            let padded = stage.art.insetBy(dx: -Layout.artPadding, dy: -Layout.artPadding)
            return [stage.widget, stage.frame].allSatisfy { rect in
                screen.maxY - rect.maxY >= clock - 0.5 && screen.maxY - rect.minY <= floor + 0.5
            } && screen.maxY - stage.widget.maxY >= clock + Layout.artPadding - 0.5
                && (stage.canEnlarge ? stage.frame.contains(padded) && screen.contains(padded) : stage.frame == stage.widget)
        }, "Short or tall, the widget and its large window stay clear of the clock and the login block")
        check(Layout.stage(in: CGRect(x: 0, y: 0, width: 640, height: 480), offset: 0) == nil,
              "640 × 480 has no room between the clock and the login block: no widget")
        check(Layout.stage(in: CGRect(x: 0, y: 0, width: 800, height: 300), offset: 24) == nil, "Nor has a tiny screen")
        let short = CGRect(x: 0, y: 0, width: 1280, height: 720)
        check(Layout.stage(in: short, offset: 0).map { !$0.canEnlarge && $0.frame == $0.widget } == true,
              "1280 × 720 holds the widget but no enlarged artwork, so its window stays the widget's")
        let stage = Layout.stage(in: macBook, offset: 0)!
        let raised = Layout.stage(in: macBook, offset: Layout.offsetRange.lowerBound)!
        check(raised.canEnlarge && raised.art.width < stage.art.width, "Raised to the top of the slider, the artwork shrinks to the band left")
        check(macBook.maxY - stage.frame.maxY == Layout.clockBottom(956) && stage.local(stage.art, in: stage.frame).minY == Layout.artPadding,
              "On this Mac the large window reaches the clock's edge, \(Int(Layout.artPadding)) pt above the artwork")
        // The wash sits above the lock screen: faint over the clock and the login block, full around the artwork.
        let stops = stage.washStops
        check(zip(stops, stops.dropFirst()).allSatisfy { $0.location <= $1.location }, "The wash's stops run downwards")
        check(stage.washOpacity(at: 0) == 0 && stage.washOpacity(at: 1) == 0, "No wash at the menu bar or the bottom edge")
        check(stride(from: 0.085, through: 0.245, by: 0.01).allSatisfy { stage.washOpacity(at: $0) <= 0.25 },
              "At most a quarter of the wash over the clock")
        check(stride(from: 0.826, through: 0.95, by: 0.01).allSatisfy { stage.washOpacity(at: $0) <= 0.15 },
              "At most 15 % of it over the picture, name and password prompt")
        check(stage.washOpacity(at: (macBook.maxY - stage.art.midY) / macBook.height) == 1, "Full behind the artwork")
        check(Layout.stage(in: short, offset: Layout.offsetRange.lowerBound)!.washStops.allSatisfy { (0...1).contains($0.location) },
              "A short screen still gets stops within it")

        // The enlarged artwork: tap, idle, a new track, the shrink settling, and the lock screen going away.
        var art = NotchLockArtState()
        check(!art.staged && !art.expanded, "The artwork starts on the tile")
        art.tap()
        check(art.expanded && art.staged && art.animated, "A tap enlarges it on the spring")
        let waiting = art.generation
        art.trackChanged()
        check(art.expanded && art.generation != waiting, "A new track keeps it enlarged and starts the wait over")
        art.idle(waiting)
        check(art.expanded, "so the earlier wait ending does nothing")
        art.idle(art.generation)
        check(art.phase == .collapsing && art.staged, "Idle: it shrinks, the window still large")
        let shrinking = art.generation
        art.trackChanged()
        check(art.generation == shrinking, "A new track while it shrinks does not hold it")
        art.settled(shrinking)
        check(art.phase == .collapsed && !art.staged, "Once settled on the tile, the window is small again")
        art.tap()
        art.tap()
        check(art.phase == .collapsing, "A second tap shrinks it")
        let late = art.generation
        art.tap()
        check(art.expanded, "A tap while it shrinks grows it again")
        art.settled(late)
        check(art.expanded, "and the earlier shrink settling does nothing")
        art.follow(available: true, shown: true)
        check(art.expanded, "Locked with the widget showing, it stays")
        art.follow(available: true, shown: false)
        check(art.phase == .collapsing && art.animated, "The widget leaving with its track shrinks it on the spring")
        // Unlocking while enlarged, then locking again, driven through the lock state.
        var lock = NotchLockState()
        lock.lock()
        art = NotchLockArtState()
        art.follow(available: lock.phase == .locked && lock.presented, shown: true)
        art.tap()
        lock.unlock()
        art.follow(available: lock.phase == .locked && lock.presented, shown: false)
        check(art.phase == .collapsed && !art.animated, "Unlocking while enlarged cuts back at once")
        lock.opened()
        lock.retracted()
        lock.lock()
        art.follow(available: lock.phase == .locked && lock.presented, shown: true)
        check(!art.staged, "A relock starts on the tile")
        art.tap()
        lock.cover(.asleep, true)
        art.follow(available: lock.phase == .locked && lock.presented, shown: true)
        check(!art.staged, "Sleep while enlarged cuts it too")
        lock.cover(.asleep, false)
        art.tap()
        art.follow(available: false, shown: true)
        check(!art.staged, "So does the switch going off")
        art.tap()
        art.cut()
        let cut = art.generation
        art.idle(cut - 1)
        art.settled(cut - 1)
        check(art.phase == .collapsed, "Late timers after a cut do nothing")

        // The wash's colours: the artwork's regions, deepened so white text stays readable over them.
        let image = NSImage(size: NSSize(width: 90, height: 90), flipped: true) { rect in
            NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: rect.width, height: rect.height / 2).fill()
            NSColor(srgbRed: 0.1, green: 0.2, blue: 0.95, alpha: 1).setFill()
            CGRect(x: 0, y: rect.height / 2, width: rect.width, height: rect.height / 2).fill()
            return true
        }
        let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        let palette = png.flatMap { NotchLockPalette(artwork: $0.base64EncodedString()) }
        check(palette?.colors.count == 9, "Nine colours from an artwork")
        if let colors = palette?.colors {
            check(colors[0].x > colors[0].z && colors[8].z > colors[8].x, "Red on top, blue below, as in the artwork")
            check(colors.allSatisfy { max($0.x, $0.y, $0.z) <= 0.5 + 0.001 && max($0.x, $0.y, $0.z) >= 0.18 - 0.001 },
                  "Every colour deep enough for white text, none black")
        }
        check(NotchLockPalette(artwork: "bm90IGFuIGltYWdl") == nil, "Data that is not an image gives no palette")
        print("\(checks) lock checks passed")
    }
}
