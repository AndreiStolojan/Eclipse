import AppKit
import CoreAudio
import JavaScriptCore

@main
struct NotchCoreChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
            print("PASS \(name)")
        }
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                     safeTop: 32, leftWidth: 645.5, rightWidth: 645.5)
        check(geometry.cutoutWidth == 179, "Measured MacBook cutout")
        check(geometry.compactSize == CGSize(width: 259, height: 32), "Idle wings size")
        check(geometry.frame(.open).size == CGSize(width: 320, height: 168), "Approved B dimensions")
        for expanded in [false, true] {
            let frame = geometry.frame(expanded ? .open : .closed)
            check(frame.midX == 735 && frame.maxY == 956, "Camera-centred \(expanded)")
        }
        let external = NotchGeometry(screenFrame: CGRect(x: -1920, y: 180, width: 1920, height: 1080),
                                     safeTop: 0, leftWidth: nil, rightWidth: nil)
        check(external.cutoutWidth == 160 && external.topHeight == 28, "No-notch fallback")
        check(external.frame(.open).maxY == 1260 && external.frame(.open).midX == -960,
              "Offset external display coordinates")
        let small = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 240, height: 700),
                                  safeTop: 0, leftWidth: nil, rightWidth: nil)
        check(small.frame(.open).width == 240, "Expanded width fits display")
        check(geometry.contains(CGPoint(x: 620, y: 942), .closed), "Idle wing receives mouse events")
        check(geometry.contains(CGPoint(x: 620, y: 956), .closed), "Cursor pinned to the top edge stays inside")
        check(!geometry.contains(CGPoint(x: 620, y: 956.5), .closed), "Points above the screen stay outside")
        check(!geometry.contains(CGPoint(x: 590, y: 830), .closed), "Transparent expanded area passes clicks through")
        check(geometry.contains(CGPoint(x: 590, y: 830), .open), "Expanded player receives mouse events")
        check(!geometry.contains(CGPoint(x: 575.1, y: 788.1), .open), "Rounded corner passes clicks through")
        var custom = NotchSettings()
        custom.expandedWidth = 400; custom.expandedHeight = 150; custom.wingWidth = 60; custom.cornerRadius = 12
        let sized = NotchGeometry(screenFrame: geometry.screenFrame, safeTop: 32, leftWidth: 645.5, rightWidth: 645.5, settings: custom)
        check(sized.frame(.open).size == CGSize(width: 400, height: 182) && sized.compactSize.width == 299,
              "Settings drive expanded and compact sizes")
        check(sized.contains(CGPoint(x: 575.1, y: 788.1), .open), "Smaller corner radius covers the former corner gap")
        let suite = UserDefaults(suiteName: "ro.andrei.NotchLab.CoreChecks.\(UUID().uuidString)")!
        suite.set(#"{"expandedWidth": 360, "retiredSetting": true}"#.data(using: .utf8), forKey: NotchSettings.key)
        let loaded = NotchSettings.load(from: suite)
        check(loaded.expandedWidth == 360 && loaded.expandedHeight == 136 && loaded.haptics,
              "Partial or outdated stored settings merge over the defaults")
        check(NotchSettings.load(from: UserDefaults(suiteName: "ro.andrei.NotchLab.Empty.\(UUID().uuidString)")!) == NotchSettings(),
              "Missing settings fall back to defaults")
        suite.set(#"{"animationDuration": 0.28, "animationBounce": 0.08}"#.data(using: .utf8), forKey: NotchSettings.key)
        let motion = NotchSettings.load(from: suite)
        check(motion.openAnimationDuration == 0.55 && motion.closeAnimationDuration == 0.42 && motion.openAnimationBounce == 0.08
              && motion.closeAnimationDuration < motion.openAnimationDuration,
              "The old fast animation values are left behind for slower opening and a quicker, softer close")
        var state = NotchState()
        check(!state.expanded && !state.pinned, "Launch starts compact and unpinned")
        state.hover(true)
        check(state.expanded && !state.pinned, "Hover opens player")
        check(!state.pinned, "Opening by hover does not pin the player")
        state.hover(false)
        check(!state.expanded, "Hover exit closes player")
        state.togglePin()
        state.hover(false)
        check(state.expanded && state.pinned, "Pinned player stays open")
        state.dismiss()
        check(!state.expanded && !state.pinned, "Dismiss clears pin")
        state.togglePin(); state.togglePin()
        check(!state.expanded && !state.pinned, "Second click collapses player")
        state.hover(true); state.toggleExpanded()
        check(!state.expanded && !state.pinned, "Menu collapses a hover-open player instead of pinning it")
        state.toggleExpanded(); state.toggleExpanded()
        check(!state.expanded && !state.pinned, "Menu expands then collapses a pinned player")
        state.dragEnter()
        check(state.expanded && state.dropTargeted, "File drag opens notch")
        state.hover(false)
        check(state.expanded, "Hover exit waits while a drag is over the notch")
        state.dragExit()
        check(!state.expanded && !state.dropTargeted, "Drag exit closes notch")
        state.dragEnter(); state.drop()
        check(state.expanded && !state.dropTargeted, "Drop keeps notch open")
        state.hover(false)
        check(!state.expanded, "Hover exit closes notch after drop")
        state.togglePin(); state.dragEnter(); state.dragExit()
        check(state.expanded && state.pinned, "Pinned player stays open after drag exit")
        state.dismiss()
        check(state.activity == .music, "Notch starts on music")
        state.swipe(by: 1)
        check(state.activity == .calendar, "Swipe moves from music to the calendar")
        state.swipe(by: 1)
        check(state.activity == .timer, "then to the timer")
        state.swipe(by: 1)
        check(state.activity == .shelf, "The next swipe reaches the shelf")
        let turn = state.pages.turn
        state.swipe(by: 1)
        check(state.activity == .music && state.pages.turn == turn + 1, "Swipe past the last view wraps forward to music")
        state.swipe(by: -1)
        check(state.activity == .shelf && state.pages.turn == turn, "Swipe back from the first view wraps back to the last")
        state.swipe(by: -1); state.swipe(by: -1); state.swipe(by: -1); state.swipe(by: -1); state.swipe(by: -1)
        check(state.activity == .timer && state.pages.turn == turn - 5, "Turns keep counting down past the wrap")
        state.settlePages()
        check(state.pages.strip(in: state.activities).map(\.page) == [.calendar, .timer, .shelf]
              && state.pages.strip(in: state.activities).map(\.turn) == [turn - 6, turn - 5, turn - 4],
              "The strip shows each neighbour on its own side")
        // The rest pages between three or two views, without the timer.
        state.timerEnabled = false
        state.activity = .music
        state.calendarEnabled = false
        state.swipe(by: 1)
        check(state.activity == .shelf && state.activities == [.music, .shelf], "With the calendar off, music pages to the shelf")
        check(state.pages.strip(in: state.activities).map(\.page) == [.music, .shelf, .music],
              "With two views the other one waits on both sides")
        state.swipe(by: 1)
        check(state.activity == .music, "and the next swipe wraps back to music")
        state.calendarEnabled = true
        state.activity = .calendar
        state.calendarEnabled = false
        check(state.activity == .music, "Turning the calendar off leaves its page for music")
        state.calendarEnabled = true
        state.timerEnabled = true
        // Direct jumps slide the shorter way round, forward on a tie.
        var jumps = NotchPages()
        let all: [NotchActivity] = [.music, .calendar, .shelf, .agents]
        jumps.show(.agents, in: all)
        check(jumps.current == .agents && jumps.turn == -1, "Music to T3 Code goes back across the wrap")
        jumps.settle()
        jumps.show(.calendar, in: all)
        check(jumps.turn == 0, "Two views apart goes forward")
        jumps.settle()
        jumps.show(.shelf, in: [.music, .shelf])
        check(jumps.turn == 1, "A view gone from the order goes forward")
        // A page leaving keeps its place on the strip until the slide comes to rest.
        var sliding = NotchState()
        sliding.timerEnabled = false
        sliding.hover(true)
        sliding.swipe(by: 1); sliding.settlePages()
        let calendarTurn = sliding.pages.turn
        sliding.calendarEnabled = false
        check(sliding.activity == .music && sliding.pages.turn == calendarTurn + 1
              && sliding.pages.strip(in: sliding.activities).contains(.init(turn: calendarTurn, page: .calendar)),
              "Turning the calendar off while it shows slides it out as itself, not as the shelf")
        sliding.settlePages()
        check(sliding.pages.strip(in: sliding.activities).map(\.page) == [.shelf, .music, .shelf],
              "Once at rest the calendar is gone from the strip")
        let rest = sliding.pages.turn
        sliding.swipe(by: 1); sliding.swipe(by: 1)
        check(sliding.pages.strip(in: sliding.activities).map(\.turn) == Array(rest...rest + 3)
              && sliding.pages.strip(in: sliding.activities).first?.page == .music,
              "A turn started during another keeps the page that is still sliding out")
        sliding.swipe(by: -1)
        check(sliding.pages.turn == rest + 1 && sliding.activity == .shelf, "Turning back lands on the page sliding out")
        sliding.settlePages()
        check(sliding.pages.strip(in: sliding.activities).map(\.turn) == [rest, rest + 1, rest + 2],
              "At rest the strip is the current page and its neighbours")
        // With T3 Code on, a jump towards a page still sliding out crossfades in place instead of replacing it.
        var crossfade = NotchState()
        crossfade.timerEnabled = false
        crossfade.hover(true)
        crossfade.agentsEnabled = true
        crossfade.swipe(by: 1); crossfade.settlePages()
        crossfade.calendarEnabled = false
        let leaving = crossfade.pages.turn
        crossfade.activity = .agents
        check(crossfade.activity == .agents && crossfade.pages.turn == leaving
              && crossfade.pages.strip(in: crossfade.activities).contains(.init(turn: leaving - 1, page: .calendar)),
              "A jump never replaces a page still sliding out")
        // Closing drops pages still sliding out, so a reopened strip shows the order as it is then.
        var closing = NotchState()
        closing.timerEnabled = false
        closing.hover(true)
        closing.swipe(by: 1); closing.swipe(by: 1)
        closing.hover(false)
        closing.calendarEnabled = false
        closing.hover(true)
        check(closing.activity == .shelf && closing.pages.strip(in: closing.activities).map(\.page) == [.music, .shelf, .music],
              "Closing mid-slide leaves no page that was switched off meanwhile")
        var single = NotchPages()
        single.turn(by: 1, in: [.music]); single.turn(by: -1, in: [.music])
        check(single.current == .music && single.turn == 0 && single.strip(in: [.music]).count == 1,
              "A single view stays put with no neighbours")
        state.hover(true); state.hold(); state.hover(false)
        check(state.expanded, "A hold keeps the notch open after the pointer leaves")
        state.release(pointerInside: false)
        check(!state.expanded && !state.held, "Release outside closes the notch")
        state.hover(true); state.hold(); state.release(pointerInside: true)
        check(state.expanded, "Release inside keeps the notch open")
        // A track change peeks: the closed notch opens for a moment and ignores the pointer leaving.
        var peek = NotchState()
        _ = peek.show(.volume)
        check(peek.peek() && peek.expanded && peek.peeking && peek.hud == nil, "A track change opens the closed notch and ends an indicator")
        peek.hover(false)
        check(peek.expanded, "The pointer leaving does not end a peek")
        check(peek.peek() && peek.peeking, "Another change during a peek keeps it")
        peek.endPeek(pointerInside: false)
        check(!peek.expanded && !peek.peeking, "The peek ends closed without the pointer")
        _ = peek.peek(); peek.hover(true); peek.endPeek(pointerInside: true)
        check(peek.expanded && !peek.peeking, "The peek ends open under the pointer")
        peek.hover(false)
        check(!peek.expanded, "Hover exit then closes it as usual")
        peek.hover(true)
        check(!peek.peek() && !peek.peeking, "An open notch does not peek")
        peek.dismiss()
        _ = peek.peek(); peek.dismiss()
        check(!peek.expanded && !peek.peeking, "Dismiss ends a peek")
        _ = peek.peek(); peek.togglePin(); peek.endPeek(pointerInside: false)
        check(peek.expanded && peek.pinned && !peek.peeking, "Pinning during a peek keeps the notch open")
        peek.dismiss()
        _ = peek.peek(); peek.dragEnter(); peek.endPeek(pointerInside: false)
        check(peek.expanded && peek.dropTargeted && !peek.peeking, "A file drag takes over from the peek and keeps the notch open")
        peek.dragExit()
        check(!peek.expanded, "Drag exit closes it")
        check(NotchSettings().peekOnTrackChange && NotchSettings().peekDuration == 3 && !NotchSettings().trackPeekOpensNotch,
              "Peek defaults: on, 3 s, the mini peek")
        // The mini peek: a slim row under the closed wings, the lowest passing layer.
        var mini = NotchState()
        let song = NotchTrackPeek(title: "Weightless", artist: "Marconi Union", site: nil, player: "Spotify", browser: false)!
        check(mini.show(trackPeek: song) && mini.shape == .trackPeek && !mini.expanded && mini.acceptsSwipes,
              "A track change drops the closed notch to a track peek, which takes swipes")
        check(mini.show(.volume) && mini.shape == .indicator && mini.trackPeek == song, "An indicator covers it")
        mini.dismissHUD()
        mini.countdown = true
        check(mini.shape == .trackPeek, "It shows again afterwards, over the countdown")
        mini.eventPeek = NotchEventPeek(event: NotchEvent(id: "standup", title: "Stand-up", start: .now, end: .now.addingTimeInterval(900)),
                                        starting: false)
        check(mini.shape == .eventPeek, "A Quick Peek covers it")
        let other = NotchTrackPeek(title: "Teardrop", artist: "Massive Attack", site: nil, player: nil, browser: false)!
        check(!mini.show(trackPeek: other) && mini.trackPeek == song, "and a newer track does not replace it meanwhile")
        mini.eventPeek = nil
        check(mini.show(trackPeek: other) && mini.trackPeek == other, "A newer track replaces the one shown")
        mini.hover(true)
        check(mini.expanded && mini.trackPeek == nil, "Opening the notch ends it")
        check(!mini.show(trackPeek: song) && mini.trackPeek == nil, "An open notch shows no track peek")
        mini.dismiss()
        mini.beginDictation()
        check(!mini.show(trackPeek: song), "Nor does dictation")
        mini.endDictation()
        _ = mini.show(screenshot: URL(fileURLWithPath: "/tmp/shot.png"))
        check(!mini.show(trackPeek: song), "Nor a screenshot")
        check(geometry.frame(.trackPeek).size == CGSize(width: 259, height: 66)
              && geometry.frame(.trackPeek).height < geometry.frame(.eventPeek).height
              && geometry.frame(.trackPeek).width == geometry.frame(.closed).width,
              "The track peek is 259 × 66 here: the closed wings' width, shorter than a Quick Peek")
        check(NotchGeometry.grows(from: geometry.frame(.closed).size, to: geometry.frame(.trackPeek).size),
              "It grows from the closed notch on the opening spring")
        check(external.frame(.trackPeek).width == 240 && external.frame(.trackPeek).height == 62,
              "On a display without a notch it follows the simulated cutout")
        // What the row says: the artist, or for web video the website, never an empty title.
        check(NotchTrackPeek(title: "  ", artist: "A", site: nil, player: nil, browser: false) == nil
              && NotchTrackPeek(title: nil, artist: "A", site: nil, player: nil, browser: false) == nil,
              "A track without a title shows nothing")
        check(NotchTrackPeek(title: "Video", artist: "Channel", site: "YouTube", player: "Safari", browser: true)?.detail == "YouTube"
              && NotchTrackPeek(title: "Video", artist: "Channel", site: nil, player: "Safari", browser: true)?.detail == "Channel"
              && NotchTrackPeek(title: "Video", artist: nil, site: nil, player: "Safari", browser: true)?.detail == "Safari",
              "Web video names its website, then the artist, then the browser")
        check(NotchTrackPeek(title: "Song", artist: "", site: "YouTube", player: "Spotify", browser: false)?.detail == "Spotify",
              "An app's track names the artist, or the app without one")
        check("שלום עולם".readsRightToLeft && "  «مرحبا» 2026".readsRightToLeft && !"Hello".readsRightToLeft
              && !"夜に駆ける".readsRightToLeft && !"🎧 Daft Punk".readsRightToLeft && !"1999 ⚡️".readsRightToLeft,
              "Hebrew and Arabic titles read right to left; Latin, Japanese, emoji and digits do not")
        check(NotchSettings().swipeToToggle && NotchSettings().swipeToPage && NotchSettings().swipeToSkip,
              "Gesture defaults: swipes open and close, page and skip")
        var tracks = NotchTrackWatch()
        let heard = ContinuousClock.now
        func at(_ seconds: Double) -> ContinuousClock.Instant { heard + .seconds(seconds) }
        let reminder = Double(NotchTrackWatch.reminder.components.seconds)
        check(!tracks.update(source: "Music", title: "a", playing: true, at: at(0))
              && !tracks.update(source: "Music", title: "a", artist: "Band", album: "LP", playing: true, at: at(1)),
              "What already plays at launch does not peek, nor its artist and album arriving")
        check(!tracks.update(source: "Music", title: "a", playing: false, at: at(10))
              && !tracks.update(source: "Music", title: "a", artist: "Band", playing: true, at: at(10 + reminder - 1)),
              "Resuming the same track after a shorter pause does not peek")
        check(!tracks.update(source: "Music", title: "a", playing: true, at: at(1200)),
              "Neither does repeat-one replaying it, nor time spent playing")
        check(!tracks.update(source: "Music", title: "a", playing: false, at: at(1300))
              && !tracks.update(source: "Music", title: "a", playing: false, at: at(1800))
              && tracks.update(source: "Music", title: "a", playing: true, at: at(1300 + reminder)),
              "Resuming after a long pause peeks as a reminder, timed from when it stopped")
        check(!tracks.update(source: "Music", title: "a", playing: false, at: at(2000))
              && tracks.update(source: "Music", title: "a", playing: true, at: at(2000 + reminder))
              && !tracks.update(source: "Music", title: "a", playing: false, at: at(2000.1 + reminder))
              && tracks.update(source: "Music", title: "a", playing: true, at: at(2005 + reminder)),
              "A flicker of playing after a long pause leaves the reminder for when it really plays")
        check(!tracks.update(source: "Music", title: "b", playing: false, at: at(3000)), "A track picked while paused does not peek")
        check(tracks.update(source: "Music", title: "b", playing: true, at: at(3001)), "It peeks once it plays")
        check(tracks.update(source: "Music", title: "c", playing: true, at: at(3010))
              && !tracks.update(source: "Music", title: "c", playing: false, at: at(3010.1))
              && !tracks.update(source: "Music", title: "b", playing: true, at: at(3011))
              && tracks.update(source: "Music", title: "c", playing: true, at: at(3020)),
              "A track that only flickered still peeks when it really plays")
        check(!tracks.update(source: nil, title: nil, playing: false, at: at(3030))
              && tracks.update(source: "Music", title: "d", playing: true, at: at(3031)),
              "The next track after a player quit peeks")
        check(tracks.update(source: "Safari", title: "d", playing: true, at: at(3040)),
              "The same title playing in another player peeks")
        check(tracks.update(source: "Safari", title: "e", playing: true, at: at(3050))
              && !tracks.update(source: "Safari", title: "e", playing: false, at: at(3060))
              && !tracks.update(source: "Safari", title: "e", playing: true, at: at(3061)),
              "Another Safari tab peeks only when what it reports differs: tabs share Safari's identity")
        check(tracks.update(source: "Music", title: "Intro", playing: true, at: at(3070))
              && !tracks.update(source: "Music", title: "Intro", artist: "X", playing: true, at: at(3070.5))
              && tracks.update(source: "Music", title: "Intro", artist: "Y", playing: true, at: at(3080)),
              "A detail arriving is the same track; one that contradicts is another")
        check(!tracks.update(source: "Music", title: "Intro", playing: false, at: at(3090))
              && !tracks.update(source: "Music", title: "Intro", playing: true, at: at(3095))
              && tracks.update(source: "Music", title: "Intro", artist: "X", playing: true, at: at(3096)),
              "After a short pause, a track that leaves out the artist and then names another one is another track")
        var untitled = NotchTrackWatch()
        check(!untitled.update(source: "Spotify", title: nil, playing: true, at: at(0))
              && !untitled.update(source: "Spotify", title: "a", artist: "Band", playing: true, at: at(1))
              && !untitled.update(source: "Spotify", title: "a", playing: false, at: at(10))
              && untitled.update(source: "Spotify", title: "b", playing: true, at: at(11)),
              "Playback found at launch stays quiet when its title arrives late; the next track peeks")
        var stopped = NotchTrackWatch()
        check(!stopped.update(source: "Spotify", title: nil, playing: true, at: at(0))
              && !stopped.update(source: nil, title: nil, playing: false, at: at(1))
              && stopped.update(source: "Spotify", title: "a", playing: true, at: at(2)),
              "Playback that stops before naming itself at launch peeks when play is pressed")
        var switched = NotchTrackWatch()
        check(!switched.update(source: "Safari", title: nil, playing: true, at: at(0))
              && switched.update(source: "Spotify", title: "a", playing: true, at: at(5)),
              "Another player starting while untitled launch playback never named itself peeks")
        var switchedUntitled = NotchTrackWatch()
        check(!switchedUntitled.update(source: "Safari", title: nil, playing: true, at: at(0))
              && !switchedUntitled.update(source: "Spotify", title: nil, playing: true, at: at(5))
              && switchedUntitled.update(source: "Spotify", title: "a", playing: true, at: at(6)),
              "So does another player that names its track a moment after it starts")
        var idle = NotchTrackWatch()
        check(!idle.update(source: nil, title: nil, playing: false) && idle.update(source: "Spotify", title: "a", playing: true),
              "Pressing play after a launch with nothing playing peeks")
        var cued = NotchTrackWatch()
        check(!cued.update(source: "Spotify", title: "a", playing: false) && cued.update(source: "Spotify", title: "a", playing: true),
              "So does playing a track that was paused at launch")
        let row = NotchTrackPeek(title: "Song", artist: "Band", site: nil, player: nil, browser: false)
        check(tracks.learn(row, artwork: nil) && !tracks.learn(row, artwork: nil), "Only news about the playing track is reported")
        check(tracks.learn(row, artwork: "AAAA") && tracks.learn(row, artwork: "BBBB") && !tracks.learn(row, artwork: "BBBB"),
              "Artwork arriving or replaced is news, the same artwork again is not")
        check(NotchDropZone(x: 100, width: 320) == .shelf && NotchDropZone(x: 211, width: 320) == .shelf
              && NotchDropZone(x: 212, width: 320) == .airDrop && NotchDropZone(x: 300, width: 320) == .airDrop,
              "Drop zones split mid-gap before the AirDrop target")
        let tabs = NotchWebSites.parse("""
            https://www.netflix.com/watch/1\tNetflix
            https://www.youtube.com/watch?v=x\t(3) Lo-fi beats to study to - YouTube
            https://music.youtube.com/watch?v=y\tWeightless - YouTube Music
            favorites://\t
            """)
        check(tabs.count == 3, "Tab output parses and skips pages without a host")
        // Swift matches tabs and the page's script checks the video by one rule: both agree on every fixture.
        let titles = ["Video  A", " Video\tA\n", "(3) Video A - YouTube", "Weightless - YouTube Music",
                      "Cafe\u{301} del\u{A0}Mar", "(12)Video A", "Video A - YouTube - YouTube", "A - YouTube Musical", ""]
        let plainScript = JSContext()!
        plainScript.evaluateScript(NotchWebSites.plainTitleScript)
        check(titles.allSatisfy { plainScript.objectForKeyedSubscript("plain").call(withArguments: [$0]).toString()
                                     == NotchWebSites.plainTitle($0) },
              "Swift and the page's script make titles plain alike")
        check(NotchWebSites.plainTitle("(3) Video  A - YouTube") == "Video A"
              && NotchWebSites.plainTitle("Cafe\u{301} del\u{A0}Mar") == "Caf\u{E9} del Mar",
              "Plain titles drop YouTube's count and suffix, collapse spaces and compose accents")
        let spaced = NotchWebSites.Tab(url: URL(string: "https://www.youtube.com/watch?v=a")!, title: "(1) Video A - YouTube")
        check(NotchWebSites.pick([spaced], trackTitle: "Video  A") == .named(spaced),
              "A track title with extra spaces still matches its tab, so it can be liked")
        check(NotchWebSites.pick(tabs, trackTitle: "Weightless") == .named(tabs[2])
              && NotchWebSites.pick(tabs, trackTitle: "lo-fi BEATS to study to") == .named(tabs[1]),
              "The tab titled like the track wins")
        let netflixTab = tabs[0]
        let mentalist = NotchWebSites.NetflixHeading(title: "The Mentalist", path: "/watch/1")
        check(NotchWebSites.pick(tabs, trackTitle: "Episode 4") == .readNetflix(netflixTab)
              && NotchWebSites.pick(tabs, trackTitle: "Episode 4", netflixHeading: mentalist) == .ambiguous
              && NotchWebSites.pick(Array(tabs.dropFirst()), trackTitle: "Episode 4") == .ambiguous,
              "Without a title match the Netflix player's heading is read first, and several sites open are unknown")
        // The case that prompted this: a Netflix tab first, and YouTube playing the next video before retitling its tab.
        let lagging = NotchWebSites.Tab(url: URL(string: "https://www.youtube.com/watch?v=idJQMJwHtyM")!,
                                        title: "Claude for Google Workspace\u{2122} - YouTube")
        let twitch = NotchWebSites.Tab(url: URL(string: "https://www.twitch.tv/somebody")!, title: "somebody - Twitch")
        let codex = "Does the $200 Codex plan suck now?"
        check(NotchWebSites.pick([netflixTab, lagging], trackTitle: codex, netflixHeading: mentalist) == .ambiguous
              && NotchWebSites.pick([netflixTab], trackTitle: codex, netflixHeading: mentalist) == .ambiguous
              && NotchWebSites.pick([lagging], trackTitle: codex) == .only(lagging)
              && NotchWebSites.pick([lagging, twitch], trackTitle: codex) == .ambiguous
              && NotchWebSites.pick([], trackTitle: codex) == nil,
              "A track no tab names never falls back past a Netflix player: unknown beside it, else the one other media site")
        let secondVideo = NotchWebSites.Tab(url: URL(string: "https://www.youtube.com/watch?v=b")!, title: "Other - YouTube")
        check(NotchWebSites.pick([lagging, secondVideo], trackTitle: codex) == .only(lagging),
              "Several tabs on one site still name the site, shown but not liked")
        let titledShow = NotchWebSites.Tab(url: URL(string: "https://www.netflix.com/title/1")!, title: "The Mentalist - Netflix")
        check(NotchWebSites.pick([titledShow, lagging], trackTitle: "The Mentalist") == .only(lagging)
              && NotchWebSites.pick([lagging, titledShow, netflixTab], trackTitle: "Netflix") == .named(netflixTab)
              && NotchWebSites.pick([lagging, netflixTab], trackTitle: "The Mentalist", netflixHeading: mentalist)
                  == .named(netflixTab),
              "Netflix is taken only on evidence: the track is \"Netflix\" or the show its player names, its player tab first")
        // A heading counts only for the video it was read on and only when no tab's title names the track too.
        let dune = NotchWebSites.NetflixHeading(title: "Dune", path: "/watch/1")
        let duneVideo = NotchWebSites.Tab(url: URL(string: "https://www.youtube.com/watch?v=d")!, title: "Dune - YouTube")
        let duneTrailer = NotchWebSites.Tab(url: URL(string: "https://www.youtube.com/watch?v=t")!, title: "Dune trailer - YouTube")
        let nextEpisode = NotchWebSites.Tab(url: URL(string: "https://www.netflix.com/watch/2?trackId=9")!, title: "Netflix")
        check(NotchWebSites.pick([netflixTab, duneVideo], trackTitle: "Dune", netflixHeading: dune) == .named(duneVideo)
              && NotchWebSites.pick([netflixTab, duneTrailer], trackTitle: "Dune", netflixHeading: dune) == .ambiguous
              && NotchWebSites.pick([nextEpisode, lagging], trackTitle: "Dune", netflixHeading: dune) == .readNetflix(nextEpisode)
              && NotchWebSites.pick([netflixTab, nextEpisode], trackTitle: "Dune", netflixHeading: dune) == .ambiguous,
              "An exact tab title beats Netflix's heading, a partial one competes, and a heading from another video or "
                  + "beside a second Netflix player names nothing")
        let read = NotchWebPage(title: "Dune", subtitle: nil, content: "https://www.netflix.com/watch/2")
        check(NotchWebSites.NetflixHeading(read) == NotchWebSites.NetflixHeading(title: "Dune", path: "/watch/2")
              && NotchWebSites.pick([nextEpisode], trackTitle: "Dune", netflixHeading: NotchWebSites.NetflixHeading(read))
                  == .named(nextEpisode)
              && NotchWebSites.NetflixHeading(NotchWebPage(content: "https://www.netflix.com/watch/2")) == nil,
              "A page read binds its heading to the player's video, as the address changes while it plays")
        check(NotchWebSites.host(of: URL(string: "https://m.youtube.com/x")!).map(NotchWebSites.name) == "YouTube"
              && NotchWebSites.name(forHost: "music.youtube.com") == "YouTube Music"
              && NotchWebSites.name(forHost: "example.org") == "example.org", "Sites get readable names")
        // The site belongs to one Safari track: a new one drops it at once, so a like never pairs it with the old tab.
        var lookup = NotchWebLookup()
        let siteA = NotchWebSite(name: "YouTube", host: "youtube.com", url: URL(string: "https://www.youtube.com/watch?v=a")!, icon: nil,
                                 matchesTrack: true)
        check(lookup.follow("A") == "A" && lookup.follow("A") == nil, "A Safari track is looked up once")
        check(lookup.finish(siteA, for: "A") && lookup.site == siteA && lookup.follow("A") == nil, "and keeps its site")
        check(lookup.follow("B") == "B" && lookup.site == nil
              && NotchLikeTarget(bundleIdentifier: "com.apple.Safari", page: lookup.site?.url) == .unsupported,
              "A new track drops the previous site at once, and with it the like")
        check(!lookup.finish(siteA, for: "A") && lookup.site == nil, "A late lookup for the previous track is dropped")
        lookup.paused = true
        check(lookup.follow("C") == nil && lookup.site == nil, "Paused, as while locked, a new track starts no lookup")
        lookup.paused = false
        check(lookup.follow("C") == "C", "and is looked up once lookups resume")
        lookup.abandon()
        check(lookup.follow("C") == "C", "A lookup stopped without a result is asked again")
        // A failure is retried about 0.5, 1.5 and 3 s on, as a tab retitles, then 5, 15 and 45 s after the last one;
        // past that only an explicit ask retries, once per ask.
        let failedAt = Date()
        check(lookup.retryAt == nil, "A lookup under way waits for no retry")
        lookup.fail(for: "C", now: failedAt)
        check(lookup.title == "C" && lookup.site == nil && lookup.retryAt == failedAt + 0.5
              && lookup.follow("C", now: failedAt + 0.4) == nil && lookup.follow("C", now: failedAt + 0.5) == "C",
              "A failed lookup, such as no tab titled like the track yet, stays unresolved and is asked again 0.5 s on")
        lookup.fail(for: "C", now: failedAt + 0.5)
        check(lookup.retryAt == failedAt + 1.5 && lookup.follow("C", now: failedAt + 1.5) == "C", "then 1.5 s on")
        let fallbackSite = NotchWebSite(name: "YouTube", host: "youtube.com", url: URL(string: "https://www.youtube.com/watch?v=b")!)
        check(lookup.finish(fallbackSite, for: "C", now: failedAt + 1.5) && lookup.site == fallbackSite
              && lookup.retryAt == failedAt + 3,
              "A site found without a title match shows, and counts as a failure, asked again 3 s on")
        lookup.paused = true
        check(lookup.retryAt == nil, "Locked, no retry is due")
        lookup.paused = false
        check(lookup.follow("C", now: failedAt + 3) == "C", "and the retry comes once unlocked")
        lookup.fail(for: "C", now: failedAt + 3)
        check(lookup.follow("C", now: failedAt + 7.9) == nil && lookup.follow("C", now: failedAt + 8) == "C",
              "Past the quick retries the slower budget follows: 5 s on")
        lookup.fail(for: "C", now: failedAt + 8)
        check(lookup.follow("C", now: failedAt + 22) == nil && lookup.follow("C", now: failedAt + 23) == "C", "then 15 s on")
        lookup.fail(for: "C", now: failedAt + 23)
        check(lookup.follow("C", now: failedAt + 67) == nil && lookup.follow("C", now: failedAt + 68) == "C",
              "then 45 s on")
        lookup.fail(for: "C", now: failedAt + 68)
        check(lookup.retryAt == nil && lookup.follow("C", now: failedAt + 3600) == nil,
              "after which no retry is due and metadata updates ask no more")
        check(lookup.follow("C", explicit: true, now: failedAt + 69) == nil
              && lookup.follow("C", explicit: true, now: failedAt + 73) == "C",
              "Opening the Music page or unlocking tries once more, 5 s after the last failure")
        lookup.fail(for: "C", now: failedAt + 73)
        check(lookup.follow("C", now: failedAt + 3600) == nil && lookup.follow("C", explicit: true, now: failedAt + 78) == "C",
              "and each explicit ask buys only that one try")
        check(lookup.finish(nil, for: "C") && lookup.follow("C", explicit: true, now: failedAt + 3600) == nil,
              "A lookup that found no site is final for the title")
        check(lookup.follow("D") == "D" && lookup.retryAt == nil, "A new title starts with a fresh budget")
        lookup.fail(for: "D", now: failedAt)
        check(lookup.follow("D", explicit: true, now: failedAt + 0.5) == "D",
              "An explicit ask during the quick retries waits no longer than they do")
        check(lookup.follow(nil) == nil && lookup.site == nil && lookup.title == nil, "Other sources have no site")
        // osascript stops when its task is cancelled or its time is up, and never starts for a cancelled task.
        func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> (value: T, seconds: Double) {
            let box = CheckBox<T>(), done = DispatchSemaphore(value: 0), start = Date()
            Task.detached { box.value = await body(); done.signal() }
            done.wait()
            return (box.value!, Date().timeIntervalSince(start))
        }
        let timedOut = blocking { await NotchWebSites.osascript("delay 10", timeout: 0.3) }
        check(timedOut.value.status != 0 && timedOut.seconds < 3, "A script past its time is terminated")
        let cancelled = blocking { () async -> Int32 in
            let script = Task { await NotchWebSites.osascript("delay 10") }
            try? await Task.sleep(for: .milliseconds(300))
            script.cancel()
            return await script.value.status
        }
        check(cancelled.value != 0 && cancelled.seconds < 3, "Cancelling a script's task terminates it")
        let unlaunched = blocking { () async -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return await NotchWebSites.osascript("return 1").error
        }
        check(unlaunched.value == "Cancelled", "A cancelled task launches no script")
        // Only an allowed or undecided target runs the script, so one that quit is never launched by a background read.
        let quit = blocking { await NotchWebSites.osascript("return 1", automating: "ro.andrei.NotchLab.never-running") }
        check(quit.value.status == procNotFound && quit.value.output.isEmpty, "A target that is not running gets no script")
        check(NotchLikeReply(status: OSStatus(procNotFound), output: "", error: "") == .missing,
              "A player that quit before the like ran has no track to like")
        // Indicators in the closed notch: geometry, state and the Focus record parser.
        check(geometry.frame(.indicator).size == CGSize(width: 291, height: 32), "An indicator widens the closed wings")
        check(geometry.contains(CGPoint(x: 595, y: 942), .indicator)
              && !geometry.contains(CGPoint(x: 595, y: 942), .closed), "Widened wings receive the pointer")
        check(geometry.cornerRadius(.closed) == 11 && geometry.cornerRadius(.open) == 28, "Corner radii of the closed and open shapes")
        check(NotchGeometry.fallback == geometry, "The fallback geometry is this MacBook's")
        // Dictation: a 242 × 58 pill by default that takes over the closed notch and turns hover into its controls.
        let pill = geometry.frame(.dictation)
        check(pill.size == CGSize(width: 242, height: 58) && pill.midX == 735 && pill.maxY == 956, "Camera-centred dictation pill")
        var unscaled = NotchSettings()
        unscaled.dictationPillScale = 1
        unscaled.dictationBarScale = 1
        let smallPill = NotchGeometry(screenFrame: geometry.screenFrame, safeTop: 32, leftWidth: 645.5, rightWidth: 645.5,
                                      settings: unscaled).frame(.dictation).size
        unscaled.dictationBarScale = 1.8
        let tallBars = NotchGeometry(screenFrame: geometry.screenFrame, safeTop: 32, leftWidth: 645.5, rightWidth: 645.5,
                                     settings: unscaled).frame(.dictation).size
        check(smallPill == CGSize(width: 220, height: 54) && tallBars == CGSize(width: 220, height: 70),
              "The size settings scale the pill, and its row grows to fit taller bars")
        check(geometry.contains(CGPoint(x: 735, y: 910), .dictation) && !geometry.contains(CGPoint(x: 600, y: 942), .dictation),
              "The pill's row receives the pointer and the tucked-in wings pass it through")
        var swiper = NotchState()
        check(swiper.acceptsSwipes, "The closed notch takes swipes")
        _ = swiper.show(.volume)
        check(swiper.acceptsSwipes, "So does an indicator")
        swiper.dismissHUD(); swiper.hover(true)
        check(swiper.acceptsSwipes, "And the open player")
        swiper.dragEnter()
        check(!swiper.acceptsSwipes, "The drop targets do not")
        swiper.dragExit(); swiper.beginDictation()
        check(!swiper.acceptsSwipes, "Nor the dictation pill")
        swiper.endDictation()
        _ = swiper.show(screenshot: URL(fileURLWithPath: "/tmp/swipe.png"))
        check(!swiper.acceptsSwipes, "Nor a screenshot")
        var dictation = NotchState()
        dictation.hover(true)
        dictation.beginDictation()
        check(dictation.shape == .dictation && !dictation.expanded, "Dictation closes a hovered player to the pill")
        dictation.hover(true)
        check(!dictation.expanded && dictation.dictationHover, "Hovering the pill shows its controls instead of the player")
        dictation.togglePin()
        check(!dictation.show(.volume) && !dictation.peek() && !dictation.pinned && dictation.shape == .dictation,
              "Indicators, peeks and pinning wait while dictating")
        dictation.dragEnter()
        check(dictation.shape == .open, "A file drag still opens the drop targets")
        dictation.dragExit()
        check(dictation.shape == .dictation, "The pill returns when the drag leaves")
        dictation.endDictation()
        check(dictation.shape == .closed && !dictation.dictationHover, "Dictation ending closes the notch")
        dictation.hold()
        dictation.beginDictation()
        check(dictation.shape == .open, "An AirDrop hold keeps the notch open when dictation starts")
        dictation.release(pointerInside: false)
        check(dictation.shape == .dictation, "Releasing the hold shows the pill")
        var hudState = NotchState()
        check(hudState.show(.volume) && hudState.hud == .volume, "A closed notch shows an indicator")
        check(hudState.show(.brightness) && hudState.hud == .brightness, "A newer indicator replaces the current one")
        hudState.hover(true)
        check(hudState.expanded && hudState.hud == nil, "Opening ends the indicator")
        check(!hudState.show(.focus) && hudState.hud == nil, "An open notch refuses indicators")
        hudState.dismiss()
        _ = hudState.show(.focus)
        hudState.dragEnter()
        check(hudState.hud == nil, "A file drag ends the indicator")
        hudState.dismiss()
        _ = hudState.show(.volume)
        hudState.dismissHUD()
        check(hudState.hud == nil && !hudState.expanded, "Dismissing an indicator leaves the notch closed")
        check(NotchSettings().hudDuration == 1.5 && NotchSettings().hudColorHex == "FFFFFF" && !NotchSettings().hudGlow
              && NotchSettings().replaceSystemHUD && NotchSettings().shows(.focus),
              "Indicator defaults")
        let legacy = UserDefaults(suiteName: "ro.andrei.NotchLab.CoreChecks.\(UUID().uuidString)")!
        legacy.set(Data("{\"wingWidth\":44}".utf8), forKey: NotchSettings.key)
        let migrated = NotchSettings.load(from: legacy)
        check(migrated.wingWidth == 44 && migrated.hudColorHex == "FFFFFF" && migrated.volumeHUD, "Older settings gain indicator defaults")
        let assertions = Data("""
            {"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work",
            "assertionDetailsIdentifier":"x"},"assertionStartDateTimestamp":1}]}],"version":1}
            """.utf8)
        let configurations = Data("""
            {"data":[{"modeConfigurations":{"com.apple.focus.work":{"mode":{"modeIdentifier":"com.apple.focus.work",
            "name":"Deep Work","symbolImageName":"laptopcomputer","tintColorName":"systemTeal"}}}}],"version":1}
            """.utf8)
        let parsed = NotchFocus.parse(assertions: assertions, configurations: configurations)?.first
        check(parsed?.name == "Deep Work" && parsed?.symbol == "laptopcomputer" && parsed?.tint == .systemTeal,
              "The configured name, symbol and tint of the asserted mode are read")
        let builtIn = NotchFocus.parse(assertions: assertions, configurations: nil)?.first
        check(builtIn?.name == "Work" && builtIn?.symbol == "lanyardcard.fill" && builtIn?.tint == nil,
              "Without a configuration Apple's modes fall back to known names")
        let privateSymbol = Data("""
            {"data":[{"modeConfigurations":{"com.apple.focus.work":{"mode":{"modeIdentifier":"com.apple.focus.work",
            "name":"Work","symbolImageName":"person.lanyardcard.fill"}}}}]}
            """.utf8)
        check(NotchFocus.parse(assertions: assertions, configurations: privateSymbol)?.first?.symbol == "lanyardcard.fill",
              "A configured symbol macOS cannot draw, such as Work's, falls back to the known one")
        check(NotchFocus.parse(assertions: Data("{\"data\":[{\"storeAssertionRecords\":[]}]}".utf8), configurations: configurations)?.isEmpty == true
              && NotchFocus.parse(assertions: Data("nonsense".utf8), configurations: nil) == nil,
              "No assertion means no Focus; unreadable data is told apart from it")
        let two = Data("""
            {"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.sleep.sleep-mode"}},
            {"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}
            """.utf8)
        check(NotchFocus.parse(assertions: two, configurations: nil)?.map(\.name) == ["Sleep", "Do Not Disturb"],
              "Every asserted mode is read, in file order")
        let ended = Data("""
            {"data":[{"storeInvalidationRecords":[{"assertion":{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.sleep.sleep-mode"}}}],
            "storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}]}]}
            """.utf8)
        check(NotchFocus.parse(assertions: ended, configurations: nil)?.map(\.name) == ["Work"]
              && NotchFocus.parse(assertions: Data("{\"data\":[{\"storeInvalidationRecords\":[{\"assertionDetailsModeIdentifier\":\"com.apple.focus.work\"}]}]}".utf8), configurations: nil)?.isEmpty == true,
              "Modes that ended stay in the invalidation records and are not active")
        check(NotchFocusMode.color(named: "systemIndigoColor") == .systemIndigo && NotchFocusMode.color(named: "mauve") == nil,
              "Tint names map to system colours or nothing")
        // Battery: power connected or removed, and the 20 %, 10 % and 5 % warnings, once each per discharge.
        var watch = NotchBatteryWatch()
        check(watch.update(NotchBatteryReading(level: 0.25, plugged: false)) == nil, "The first battery reading only sets the baseline")
        check(watch.update(NotchBatteryReading(level: 0.2, plugged: false)) == .low, "Reaching 20 % on battery warns")
        check(watch.update(NotchBatteryReading(level: 0.19, plugged: false)) == nil, "Falling further under 20 % does not warn again")
        check(watch.update(NotchBatteryReading(level: 0.1, plugged: false)) == .low, "Reaching 10 % warns once more")
        check(watch.update(NotchBatteryReading(level: 0.09, plugged: false)) == nil, "Nothing between 10 % and 5 %")
        check(watch.update(NotchBatteryReading(level: 0.05, plugged: false)) == .low, "Reaching 5 % warns a last time")
        check(watch.update(NotchBatteryReading(level: 0.04, plugged: false)) == nil, "Nothing under 5 %")
        check(watch.update(NotchBatteryReading(level: 0.04, plugged: true)) == .plugged, "Connecting power shows the charge")
        check(watch.update(NotchBatteryReading(level: 0.12, plugged: true)) == nil, "Charging on does not repeat")
        check(watch.update(NotchBatteryReading(level: 0.12, plugged: false)) == .low, "Unplugging under 20 % warns again")
        check(watch.update(NotchBatteryReading(level: 0.12, plugged: true)) == .plugged, "Reconnecting shows the charge again")
        check(watch.update(NotchBatteryReading(level: 0.64, plugged: true)) == nil, "Charging up stays quiet")
        check(watch.update(NotchBatteryReading(level: 0.64, plugged: false)) == .unplugged, "Unplugging above 20 % shows the level on battery")
        check(watch.update(NotchBatteryReading(level: 0.63, plugged: false)) == nil, "Draining on battery is quiet until a threshold")
        check(!NotchBatteryReading(level: 0.64, plugged: false).low && NotchBatteryReading(level: 0.2, plugged: false).low
              && !NotchBatteryReading(level: 0.05, plugged: true).low,
              "Low means on battery at or under 20 %")
        var lowStart = NotchBatteryWatch()
        check(lowStart.update(NotchBatteryReading(level: 0.15, plugged: false)) == nil
              && lowStart.update(NotchBatteryReading(level: 0.14, plugged: false)) == nil
              && lowStart.update(NotchBatteryReading(level: 0.1, plugged: false)) == .low,
              "Starting under 20 % skips that warning and keeps the 10 % one")
        check(NotchBattery.symbol(for: 0.82) == "battery.75percent" && NotchBattery.symbol(for: 1) == "battery.100percent"
              && NotchBattery.symbol(for: 0.1) == "battery.25percent" && NotchBattery.symbol(for: 0) == "battery.0percent",
              "Battery symbols fill to the nearest quarter and a low battery keeps a sliver")
        check(NotchSettings().batteryDuration == 5 && NotchSettings().shows(.battery)
              && NotchSettings().duration(for: .battery) == 5 && NotchSettings().duration(for: .volume) == 1.5,
              "Battery indicator defaults and its own duration")
        // Media keys arrive as system-defined events; the volume-up key down is code 0 with state 0xA.
        let volumeUp = NotchMediaKeyPress(subtype: 8, data1: (0 << 16) | (0xA << 8), modifiers: [])
        check(volumeUp?.key == .volumeUp && volumeUp?.down == true && volumeUp?.stepSize == 1 / 16, "Volume up decodes with a sixteenth step")
        let brightnessDownUp = NotchMediaKeyPress(subtype: 8, data1: (3 << 16) | (0xB << 8), modifiers: [.option, .shift])
        check(brightnessDownUp?.key == .brightnessDown && brightnessDownUp?.down == false && brightnessDownUp?.stepSize == 1 / 64,
              "Brightness down key-up decodes with the fine step under Option and Shift")
        check(NotchMediaKeyPress(subtype: 8, data1: (7 << 16) | (0xA << 8), modifiers: [.option])?.key == .mute
              && NotchMediaKeyPress(subtype: 8, data1: (7 << 16) | (0xA << 8), modifiers: [.option])?.fine == false,
              "Mute decodes; Option alone is not fine")
        check(NotchMediaKeyPress(subtype: 8, data1: (16 << 16) | (0xA << 8), modifiers: []) == nil
              && NotchMediaKeyPress(subtype: 7, data1: (0 << 16) | (0xA << 8), modifiers: []) == nil
              && NotchMediaKeyPress(subtype: 8, data1: (0 << 16) | (0xC << 8), modifiers: []) == nil,
              "Play/pause, other subtypes and unknown key states pass through")
        // Caps Lock: only a flip of its bit counts; the state at start and other modifiers are not changes.
        var caps = NotchCapsLockWatch(flags: .maskAlphaShift)
        check(caps.update(.maskAlphaShift) == nil, "Caps Lock already on at start shows nothing")
        check(caps.update([.maskAlphaShift, .maskShift]) == nil && caps.update([.maskAlphaShift, .maskCommand]) == nil,
              "Other modifiers pressed under Caps Lock are not changes")
        check(caps.update(.maskShift) == false && caps.update([]) == nil, "Caps Lock turning off reads once, whatever else is held")
        check(caps.update(.maskAlphaShift) == true, "Caps Lock turning on reads as on")
        var capsState = NotchState()
        check(capsState.show(.capsLock(on: true)) && capsState.hud == .capsLock(on: true)
              && capsState.show(.capsLock(on: false)) && capsState.hud == .capsLock(on: false),
              "The indicator carries the Caps Lock state, and a new change replaces it")
        var capsOff = NotchSettings()
        check(capsOff.shows(.capsLock(on: true)) && capsOff.duration(for: .capsLock(on: false)) == capsOff.hudDuration,
              "Caps Lock shows by default for the shared indicator duration")
        capsOff.capsLockHUD = false
        check(!capsOff.shows(.capsLock(on: true)) && !capsOff.shows(.capsLock(on: false)), "The setting hides both states")
        // Screenshots: where macOS saves them, which new names are finished images, and the thumbnail's lifetime.
        let home = URL(fileURLWithPath: "/Users/someone")
        func screenshotFolder(_ location: String?) -> String {
            NotchScreenshots.folder(location: location, home: home) {
                ["/Users/someone", "/Users/someone/ScreenShots", "/Volumes/Shots"].contains($0.path)
            }.path
        }
        check(screenshotFolder(nil) == "/Users/someone/Desktop", "No screenshot location means the Desktop")
        check(screenshotFolder("~/ScreenShots") == "/Users/someone/ScreenShots" && screenshotFolder("~") == "/Users/someone"
              && screenshotFolder("/Volumes/Shots") == "/Volumes/Shots", "A ~ location expands to the home folder; absolute ones stay")
        check(screenshotFolder("~/Missing") == "/Users/someone/Desktop" && screenshotFolder("Shots") == "/Users/someone/Desktop"
              && screenshotFolder("") == "/Users/someone/Desktop", "A missing folder or a relative location falls back to the Desktop")
        var scan = NotchScreenshotScan(baseline: ["Screenshot 1.png", "notes.txt"])
        check(scan.update(["Screenshot 1.png", "notes.txt", "..Screenshot 2.png-cBDzVE"]).isEmpty
              && scan.update(["Screenshot 1.png", "notes.txt", ".Screenshot 2.png"]).isEmpty,
              "Files present at start and the hidden names of a capture in progress are not new screenshots")
        check(scan.update(["Screenshot 1.png", "notes.txt", "Screenshot 2.png"]) == ["Screenshot 2.png"], "The final name is new")
        check(scan.update(["Screenshot 2.png"]).isEmpty && scan.update(["Screenshot 1.png", "Screenshot 2.png"]).isEmpty,
              "A screenshot is reported once, even after leaving and coming back")
        check(scan.update(["Recording.mov", "Shot.JPG", "Shot.heic", "Shot.pdf", "Shot.tiff", "draft.txt"])
              == ["Shot.JPG", "Shot.heic", "Shot.pdf", "Shot.tiff"], "Every capture image type counts; recordings and other files do not")
        let firstShot = URL(fileURLWithPath: "/s/1.png"), secondShot = URL(fileURLWithPath: "/s/2.png")
        var thumbnail = NotchScreenshotThumbnail()
        thumbnail.show(firstShot)
        thumbnail.show(secondShot)
        check(thumbnail.url == secondShot, "A newer screenshot replaces the shown one")
        thumbnail.expire(firstShot)
        check(thumbnail.url == secondShot, "The replaced screenshot's timeout leaves the newer one")
        thumbnail.expire(secondShot)
        check(thumbnail.url == nil, "Its own timeout dismisses the thumbnail")
        thumbnail.show(firstShot)
        check(thumbnail.take() == firstShot && thumbnail.url == nil && thumbnail.take() == nil,
              "A click or a drag to the shelf takes the screenshot out, once")
        thumbnail.show(firstShot)
        thumbnail.dismiss()
        check(thumbnail.url == nil, "Dismissing clears the thumbnail")
        // The screenshot peek, option C: 291 × 116 under the cutout for 1.5 s, in front of indicators and track peeks.
        check(NotchScreenshotThumbnail.duration == 1.5, "A screenshot stays 1.5 s")
        check(geometry.frame(.screenshot).size == CGSize(width: 291, height: 116) && geometry.cornerRadius(.screenshot) == 16,
              "A screenshot drops the closed notch to 291 × 116")
        check(geometry.contains(CGPoint(x: 600, y: 850), .screenshot) && !geometry.contains(CGPoint(x: 600, y: 850), .indicator),
              "The dropped notch receives the pointer")
        // Downloads: every browser's partial file waits, and the site is the page that linked the file.
        // Each listing maps names to inodes; a browser's rename gives the finished file a new one.
        var downloadScan = NotchDownloadScan(baseline: ["old.zip": 1])
        check(downloadScan.update(["old.zip": 1, "a.zip.crdownload": 2, "Unconfirmed 1.crdownload": 3, "b.dmg.download": 4,
                                   ".DS_Store": 5]).isEmpty,
              "Files present at start, partial files and hidden files are not downloads")
        check(downloadScan.update(["old.zip": 1, "c.pdf": 10, "c.Ab3dEf9h.pdf.part": 11]).isEmpty
              && downloadScan.update(["old.zip": 1, "c.pdf": 10, "c.Ab3dEf9h.pdf.part": 11, "notes": 12, "notes.Qw7xZ2pL.part": 13]).isEmpty,
              "Firefox's placeholder waits while its salted .part is there, with or without an extension")
        check(downloadScan.update(["old.zip": 1, "c.pdf": 11, "notes": 13]) == ["c.pdf", "notes"],
              "They count once the .part has become the file")
        check(downloadScan.update(["old.zip": 1, "c.pdf": 11, "b.dmg": 20, "b.dmg.download": 21]).isEmpty
              && downloadScan.update(["old.zip": 1, "c.pdf": 11, "b.dmg": 21]) == ["b.dmg"],
              "Safari's file counts once its .download bundle is gone")
        check(downloadScan.update(["old.zip": 1, "c.pdf": 11, "b.dmg": 21]).isEmpty && downloadScan.update(["old.zip": 1]).isEmpty
              && downloadScan.update(["old.zip": 1, "b.dmg": 21]) == ["b.dmg"],
              "A download counts once, and again after it left and came back")
        var redownload = NotchDownloadScan(baseline: ["paper.pdf": 30])
        check(redownload.update(["paper.pdf": 30, "paper.Ab3dEf9h.pdf.part": 31]).isEmpty
              && redownload.update(["paper.pdf": 31]) == ["paper.pdf"]
              && redownload.update(["paper.pdf": 31, "paper.pdf.crdownload": 32]).isEmpty
              && redownload.update(["paper.pdf": 32]) == ["paper.pdf"],
              "A download over a name already there counts when it finishes")
        check(redownload.update(["paper.pdf": 32, "paper.pdf.crdownload": 33]).isEmpty && redownload.update(["paper.pdf": 32]).isEmpty,
              "A cancelled download over it leaves the old file, which does not count again")
        check(redownload.update(["paper.pdf": 34]) == ["paper.pdf"], "A replacement whose partial came and went between listings counts")
        var dated = NotchDownloadScan(baseline: ["report.pdf": 40, "report.20261010.pdf.part": 41, "notes.txt": 42,
                                                 "notes.Ab3dEf9h.txt.crdownload": 43, "memo.pdf": 44, "memo.deadbeef.pdf.part": 45])
        check(dated.update(["report.pdf": 40, "notes.txt": 42, "memo.pdf": 44]).isEmpty,
              "A date is not a salt, only Firefox's .part carries one, and an unchanged file beside a lookalike stays as it was")
        var underway = NotchDownloadScan(baseline: ["done.zip": 50, "p.pdf": 51, "p.Zx81Qw7e.pdf.part": 52, "q.dmg.crdownload": 53])
        check(underway.update(["done.zip": 50, "p.pdf": 52, "q.dmg": 53]) == ["p.pdf", "q.dmg"],
              "Downloads already under way at the start count when they finish")
        let quarantinedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = String(UInt64(quarantinedAt.timeIntervalSince1970), radix: 16)
        check(NotchDownloads.fresh(quarantine: "0083;\(stamp);Safari;", now: quarantinedAt.addingTimeInterval(600))
              && !NotchDownloads.fresh(quarantine: "0083;\(stamp);Safari;", now: quarantinedAt.addingTimeInterval(7 * 3600))
              && NotchDownloads.fresh(quarantine: "0083", now: quarantinedAt),
              "A quarantine set minutes ago is a new download, one set hours ago a copy; one without a time counts")
        check(NotchDownload.host(whereFroms: ["https://objects.githubusercontent.com/1/tool.zip", "https://www.github.com/x/releases"]) == "github.com"
              && NotchDownload.host(whereFroms: ["https://example.org/paper.pdf"]) == "example.org"
              && NotchDownload.host(whereFroms: ["blob:null", "file:///Users/x/a.zip"]) == nil,
              "The site is the linking page, else the file's own host, never a non-web address")
        let zip = NotchDownload(url: URL(fileURLWithPath: "/d/tool.zip"), host: "github.com", quarantined: true)
        check(zip.detail == "github.com · quarantined"
              && NotchDownload(url: URL(fileURLWithPath: "/d/a"), host: nil, quarantined: false).detail == "not quarantined",
              "The second line says the site and the quarantine")
        check(geometry.frame(.downloadPeek).size == CGSize(width: 291, height: 74) && geometry.cornerRadius(.downloadPeek) == 24,
              "A download drops the closed notch to 291 × 74, like a Quick Peek")
        var downloadState = NotchState()
        _ = downloadState.show(.volume)
        check(downloadState.show(download: zip) && downloadState.shape == .downloadPeek && downloadState.hud == nil
              && !downloadState.show(.volume), "A download ends an indicator and keeps the wings")
        downloadState.hover(true)
        check(!downloadState.expanded && !downloadState.acceptsSwipes, "The pointer holds a download instead of opening; swipes pass it by")
        _ = downloadState.show(screenshot: firstShot)
        check(downloadState.shape == .screenshot && downloadState.download == zip, "A screenshot shows over it")
        downloadState.screenshot.dismiss()
        downloadState.expanded = true
        check(downloadState.download == nil && !downloadState.show(download: zip), "Opening ends it, and an open notch takes none")
        var shotState = NotchState()
        _ = shotState.show(.volume)
        check(shotState.show(screenshot: firstShot) && shotState.screenshot.url == firstShot && shotState.hud == nil,
              "A screenshot ends an indicator")
        check(shotState.show(screenshot: secondShot) && shotState.screenshot.url == secondShot, "A newer screenshot replaces it")
        shotState.hover(true)
        check(!shotState.expanded && !shotState.peek() && !shotState.show(.volume) && shotState.hud == nil,
              "Hover, track changes and indicators leave a screenshot in place")
        shotState.dragEnter()
        check(shotState.expanded && shotState.dropTargeted && shotState.screenshot.url == secondShot,
              "The drop targets of its own drag keep the screenshot")
        shotState.dragExit()
        check(!shotState.expanded && shotState.screenshot.url == secondShot, "Leaving the targets shows the screenshot again")
        shotState.togglePin()
        check(shotState.expanded && shotState.screenshot.url == nil, "Opening the notch ends a screenshot")
        check(!shotState.show(screenshot: firstShot) && shotState.screenshot.url == nil, "An open notch ignores a new screenshot")
        var peekState = NotchState()
        let quickPeek = NotchEventPeek(event: NotchEvent(id: "standup", title: "Stand-up", start: .now, end: .now.addingTimeInterval(900)),
                                  starting: true)
        peekState.countdown = true
        peekState.eventPeek = quickPeek
        check(peekState.shape == .eventPeek && !peekState.acceptsSwipes, "A Quick Peek drops the closed notch over the countdown")
        peekState.hover(true)
        check(!peekState.expanded && !peekState.peek(), "Hover and track changes leave it in place")
        check(peekState.show(.volume) && peekState.shape == .indicator, "An indicator covers it")
        peekState.dismissHUD()
        check(peekState.shape == .eventPeek, "It shows again when the indicator is gone")
        let fixture = NotchGeometry.fallback
        check(NotchGeometry.grows(from: fixture.frame(.indicator).size, to: fixture.frame(.eventPeek).size)
              && !NotchGeometry.grows(from: fixture.frame(.eventPeek).size, to: fixture.frame(.indicator).size),
              "An indicator ending over a Quick Peek grows the outline and takes the opening spring")
        _ = peekState.show(screenshot: URL(fileURLWithPath: "/tmp/shot.png"))
        peekState.beginDictation()
        check(peekState.shape == .dictation && peekState.eventPeek == quickPeek, "Dictation and screenshots cover it too")
        peekState.endDictation()
        check(peekState.shape == .eventPeek, "It waits under them")
        peekState.togglePin()
        check(peekState.expanded && peekState.eventPeek == nil, "Opening the notch ends it")
        peekState.eventPeek = quickPeek
        peekState.hover(true)
        check(peekState.eventPeek == quickPeek, "One arriving while the notch is open waits for it to close")
        var countdownState = NotchState()
        countdownState.countdown = true
        check(countdownState.shape == .indicator, "The countdown widens the closed wings like an indicator")
        check(countdownState.show(.volume) && countdownState.shape == .indicator, "An indicator shows over the countdown")
        countdownState.dismissHUD(); countdownState.countdown = false
        check(countdownState.shape == .closed, "Without the countdown or an indicator the wings close")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.locale = Locale(identifier: "en_GB")
        utc.firstWeekday = 2
        let date = { (day: Int, hour: Int, minute: Int, second: Int) in
            utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
        }
        let early = NotchEvent(id: "early", title: "Early", start: date(2, 8, 0, 0), end: date(2, 9, 0, 0))
        let standup = NotchEvent(id: "standup", title: "Stand-up", start: date(2, 11, 0, 0), end: date(2, 11, 15, 0))
        let sync = NotchEvent(id: "sync", title: "Sync", start: date(2, 11, 20, 0), end: date(2, 11, 30, 0))
        let review = NotchEvent(id: "review", title: "Review", start: date(2, 15, 30, 0), end: date(2, 16, 30, 0))
        let overnight = NotchEvent(id: "overnight", title: "Overnight", start: date(2, 23, 0, 0), end: date(3, 1, 0, 0))
        let holiday = NotchEvent(id: "holiday", title: "Holiday", start: date(2, 0, 0, 0), end: date(3, 0, 0, 0), allDay: true)
        let cook = NotchEvent(id: "cook", title: "Cook", start: date(3, 12, 0, 0), end: date(3, 13, 0, 0))
        let agenda = NotchAgenda(events: [cook, review, overnight, holiday, sync, standup, early])
        let now = date(2, 10, 48, 0)
        let today = agenda.day(now, now: now, calendar: utc)
        check(today.timed.map(\.id) == ["standup", "sync", "review", "overnight"] && today.allDay.map(\.id) == ["holiday"],
              "Today lists what has not ended, all-day apart")
        check(agenda.day(date(3, 9, 0, 0), now: now, calendar: utc).timed.map(\.id) == ["overnight", "cook"],
              "An event past midnight also belongs to tomorrow")
        let countdown = agenda.countdown(at: now, lead: 15 * 60)
        check(countdown?.event.id == "standup" && countdown?.minutes == 12 && countdown?.label == "12m",
              "The countdown rounds the minutes to the next event up")
        check(agenda.countdown(at: date(2, 10, 44, 59), lead: 15 * 60) == nil, "Nothing counts down before the lead time")
        check(agenda.countdown(at: date(2, 10, 45, 0), lead: 15 * 60)?.minutes == 15, "The countdown starts at the lead time")
        check(agenda.countdown(at: date(2, 11, 10, 0), lead: 15 * 60) == nil, "The wings stay quiet during an event")
        check(agenda.countdown(at: date(2, 11, 15, 0), lead: 15 * 60)?.event.id == "sync", "The next one counts down after it ends")
        check(agenda.countdown(at: date(2, 23, 30, 0), lead: 15 * 60) == nil, "All-day events never count down")
        check(agenda.nextChange(after: now, lead: 15 * 60, calendar: utc) == date(2, 10, 49, 0)
              && agenda.nextChange(after: date(2, 10, 48, 30), lead: 15 * 60, calendar: utc) == date(2, 10, 49, 0),
              "A running countdown wakes when its minute drops")
        check(agenda.nextChange(after: date(2, 9, 30, 0), lead: 15 * 60, calendar: utc) == date(2, 10, 45, 0),
              "Otherwise it sleeps until the next event enters the lead time")
        check(agenda.nextChange(after: date(2, 23, 30, 0), lead: 15 * 60, calendar: utc) == date(3, 0, 0, 0),
              "Midnight wakes it for the new day")
        let soon = agenda.peek(at: date(2, 10, 45, 0), lead: 15 * 60, shown: [])
        check(soon?.event.id == "standup" && soon?.starting == false, "Quick Peek shows when the countdown begins")
        check(agenda.peek(at: date(2, 10, 50, 0), lead: 15 * 60, shown: [soon?.id ?? ""]) == nil, "Each Quick Peek shows once")
        check(agenda.peek(at: date(2, 11, 0, 30), lead: 15 * 60, shown: [soon?.id ?? ""]) == NotchEventPeek(event: standup, starting: true),
              "It shows again when the event starts")
        check(agenda.peek(at: date(2, 11, 1, 0), lead: 15 * 60, shown: []) == nil,
              "A start more than a minute ago, during the event, shows nothing")
        check(agenda.peek(at: date(2, 0, 0, 30), lead: 15 * 60, shown: []) == nil, "All-day events never peek")
        var lab = NotchEvent(id: "lab", title: "Lab", start: date(2, 12, 0, 0), end: date(2, 13, 0, 0))
        lab.location = "Faculty"
        var talk = NotchEvent(id: "talk", title: "Talk", start: date(2, 17, 0, 0), end: date(2, 18, 0, 0))
        talk.location = "Hall"
        var fair = NotchEvent(id: "fair", title: "Fair", start: date(2, 0, 0, 0), end: date(3, 0, 0, 0), allDay: true)
        fair.location = "Park"
        var teamsCall = NotchEvent(id: "teams", title: "Sync", start: date(2, 14, 0, 0), end: date(2, 15, 0, 0))
        teamsCall.location = "Microsoft Teams Meeting"
        teamsCall.meeting = URL(string: "https://teams.microsoft.com/l/meetup-join/1")
        var hybrid = teamsCall
        hybrid.id = "hybrid"
        hybrid.coordinate = NotchCoordinate(latitude: 44.43, longitude: 26.05)
        var office = teamsCall
        office.id = "office"
        office.location = "Bd. Iuliu Maniu 7"
        let trips = NotchAgenda(events: [standup, lab, teamsCall, hybrid, office, talk, fair])
        check(trips.trips(after: now, done: []).map(\.id) == ["lab", "hybrid", "office", "talk"],
              "Time to leave looks at timed events with a place, never all-day ones or a call service named as the place")
        check(NotchEvent.namesCall("Microsoft Teams Meeting") && NotchEvent.namesCall("zoom") && NotchEvent.namesCall("Google Meet")
              && !NotchEvent.namesCall("Steamstrasse 5") && !NotchEvent.namesCall("Bd. Iuliu Maniu 7"),
              "Call services are matched as whole words")
        // The trip plan, with a 10 minute buffer, a 3 hour horizon and a remeasure 15 minutes before leaving.
        let plan = { (events: [NotchEvent], at: Date, measures: [NotchTripKey: NotchTripMeasure]) in
            NotchTripPlan(trips: NotchAgenda(events: events).trips(after: at, done: []), measures: measures, now: at,
                          buffer: 600, horizon: 3 * 3600, remeasure: 900)
        }
        let labKey = NotchTripKey(lab)
        check(plan([lab], date(2, 8, 0, 0), [:]) == NotchTripPlan(trips: [], measures: [:], now: now, buffer: 0, horizon: 0, remeasure: 0)
              .with(wake: date(2, 9, 0, 0)), "A trip sleeps until three hours before it")
        check(plan([lab], date(2, 9, 30, 0), [:]).measure == [lab], "Then it is measured")
        let measuredEarly = plan([lab], date(2, 9, 30, 0), [labKey: .travel(1200, measured: date(2, 9, 30, 0))])
        check(measuredEarly.measure.isEmpty && measuredEarly.leave.isEmpty && measuredEarly.wake == date(2, 11, 15, 0),
              "A 20 minute trip wakes 15 minutes before leaving at 11:30")
        check(plan([lab], date(2, 11, 15, 0), [labKey: .travel(1200, measured: date(2, 9, 30, 0))]).measure == [lab],
              "And is measured again")
        let fresh = [labKey: NotchTripMeasure.travel(1200, measured: date(2, 11, 15, 0))]
        check(plan([lab], date(2, 11, 20, 0), fresh).wake == date(2, 11, 30, 0) && plan([lab], date(2, 11, 30, 0), fresh).leave == [lab],
              "Then Leave is due at start minus travel minus the buffer")
        check(plan([lab], date(2, 10, 0, 0), [labKey: .unreachable]) == NotchTripPlan(trips: [], measures: [:], now: now, buffer: 0,
              horizon: 0, remeasure: 0), "An unreachable place is left alone")
        let retry = [labKey: NotchTripMeasure.retry(at: date(2, 10, 0, 0))]
        check(plan([lab], date(2, 9, 30, 0), retry).wake == date(2, 10, 0, 0) && plan([lab], date(2, 10, 0, 0), retry).measure == [lab],
              "A failed try comes back at its time")
        var far = lab
        far.id = "far"
        far.start = date(2, 12, 30, 0)
        let both = [labKey: NotchTripMeasure.travel(300, measured: date(2, 10, 0, 0)),
                    NotchTripKey(far): .travel(5400, measured: date(2, 10, 0, 0))]
        var remeasured = both
        remeasured[NotchTripKey(far)] = .travel(5400, measured: date(2, 10, 35, 0))
        check(plan([lab, far], date(2, 10, 0, 0), both).wake == date(2, 10, 35, 0)
              && plan([lab, far], date(2, 10, 35, 0), both).measure == [far]
              && plan([lab, far], date(2, 10, 50, 0), remeasured).leave == [far],
              "A later event farther away leaves first")
        check(trips.trips(after: date(2, 12, 30, 0), done: ["talk"]).map(\.id) == ["hybrid", "office"],
              "It skips events under way and those already announced")
        check(NotchHUD.leave(lab).isAlert && NotchSettings().shows(.leave(lab))
              && NotchSettings().duration(for: .leave(lab)) == 8, "Leave is an 8 s alert, on by default")
        let started = NotchEventPeek(event: standup, starting: true)
        check(soon?.due(at: date(2, 10, 59, 59)) == true && soon?.due(at: date(2, 11, 0, 0)) == false
              && started.due(at: date(2, 11, 4, 59)) && !started.due(at: date(2, 11, 5, 0)),
              "A held-back peek stays due until the start, or five minutes into the event")
        check(NotchCountdown(event: cook, minutes: 75).label == "1h 15m" && NotchCountdown(event: cook, minutes: 60).label == "1h",
              "Past an hour the countdown reads in hours and minutes")
        check(NotchEvent.meetingLink(in: [nil, "Room 1", "Join https://us02web.zoom.us/j/123?pwd=x or dial in"])?.host() == "us02web.zoom.us"
              && NotchEvent.meetingLink(in: ["https://meet.google.com/abc-defg-hij", "https://zoom.us/j/1"])?.host() == "meet.google.com"
              && NotchEvent.meetingLink(in: ["Agenda https://docs.google.com/document/d/1"]) == nil,
              "Join takes the first call link and ignores other links")
        let midnight = { (year: Int, month: Int, day: Int) in utc.date(from: DateComponents(year: year, month: month, day: day))! }
        let numbers = { (week: [Date]) in week.map { utc.component(.day, from: $0) } }
        let october = NotchMonth(containing: now, calendar: utc)
        check(october.weeks.count == 5 && numbers(october.weeks[0]) == [28, 29, 30, 1, 2, 3, 4]
              && numbers(october.weeks[4]) == [26, 27, 28, 29, 30, 31, 1] && october.start == midnight(2026, 10, 1),
              "October 2026 starts on a Thursday in a Monday-first grid, September and November filling its edges")
        check(october.interval == DateInterval(start: midnight(2026, 9, 28), end: midnight(2026, 11, 2))
              && october.contains(midnight(2026, 10, 31), calendar: utc) && !october.contains(midnight(2026, 9, 30), calendar: utc),
              "The grid's span runs from its first cell to the midnight after its last, and only October's days are its own")
        check(NotchMonth.weekdaySymbols(calendar: utc) == ["M", "T", "W", "T", "F", "S", "S"]
              && NotchMonth.isWeekend(column: 5, calendar: utc) && NotchMonth.isWeekend(column: 6, calendar: utc)
              && !NotchMonth.isWeekend(column: 0, calendar: utc), "Weekday headers and weekends follow the first weekday")
        var sundayFirst = utc
        sundayFirst.firstWeekday = 1
        check(numbers(NotchMonth(containing: now, calendar: sundayFirst).weeks[0]) == [27, 28, 29, 30, 1, 2, 3]
              && NotchMonth.isWeekend(column: 0, calendar: sundayFirst), "A Sunday-first grid shifts by one")
        let november = NotchMonth(containing: midnight(2026, 11, 15), calendar: utc)
        check(november.weeks.count == 6 && numbers(november.weeks[0]) == [26, 27, 28, 29, 30, 31, 1]
              && numbers(november.weeks[5]) == [30, 1, 2, 3, 4, 5, 6], "A month starting on a Sunday takes six weeks")
        var bucharest = utc
        bucharest.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        let dst = NotchMonth(containing: now, calendar: bucharest).weeks.flatMap { $0 }
        check(dst.count == 35 && Set(dst).count == 35 && dst.allSatisfy { bucharest.component(.hour, from: $0) == 0 },
              "Every cell is a midnight across the clocks going back on 25 October")
        let octoberDays = october.weeks.flatMap { $0 }
        check(agenda.busyDays(octoberDays, calendar: utc) == [midnight(2026, 10, 2), midnight(2026, 10, 3)],
              "Dots mark days with events, ended or not; an overnight event marks both days, an all-day one only its own")
        check(NotchAgenda().busyDays(octoberDays, calendar: utc).isEmpty, "No events, no dots")

        // The Calendar page's picked day and month.
        var selection = NotchCalendarSelection()
        check(selection.shownDay(today: now, calendar: utc) == midnight(2026, 10, 2) && selection.isToday(now, calendar: utc)
              && selection.shownMonth(today: now, calendar: utc) == october, "Untouched, the page shows today and its month")
        check(selection.shownDay(today: date(3, 0, 0, 30), calendar: utc) == midnight(2026, 10, 3),
              "And moves on at midnight by itself")
        selection.select(date(7, 9, 0, 0), today: now, calendar: utc)
        check(selection.day == midnight(2026, 10, 7) && !selection.isToday(now, calendar: utc) && selection.month == nil,
              "A click picks a day and keeps the month")
        check(selection.isToday(date(7, 0, 0, 1), calendar: utc), "A picked day that has become today reads as today")
        var again = selection
        again.select(midnight(2026, 10, 7), today: now, calendar: utc)
        check(again == NotchCalendarSelection(), "A click on the picked day goes back to today")
        again = selection
        again.select(date(2, 18, 0, 0), today: now, calendar: utc)
        check(again == NotchCalendarSelection(), "So does a click on today")
        again = NotchCalendarSelection()
        again.select(midnight(2026, 9, 29), today: now, calendar: utc)
        check(again.day == midnight(2026, 9, 29) && again.month == nil && again.intervals(today: now, calendar: utc) == [october.interval],
              "A neighbouring month's day in the grid can be picked without paging, and reads nothing more")
        selection.page(by: 1, today: now, calendar: utc)
        check(selection.month == midnight(2026, 11, 1) && selection.shownDay(today: now, calendar: utc) == midnight(2026, 10, 7),
              "Paging moves the month and leaves the picked day on the left")
        check(selection.intervals(today: now, calendar: utc)
              == [november.interval, DateInterval(start: midnight(2026, 10, 7), end: midnight(2026, 10, 8))],
              "A picked day paged out of the grid is read on its own")
        selection.page(by: -1, today: now, calendar: utc)
        check(selection.month == nil, "Back on today's month the grid follows today again")
        var lastYear = NotchCalendarSelection()
        lastYear.page(by: -10, today: now, calendar: utc)
        check(lastYear.month == midnight(2025, 12, 1) && lastYear.shownMonth(today: now, calendar: utc).start == midnight(2025, 12, 1),
              "Paging crosses years")
        var edge = NotchCalendarSelection(month: nil, day: midnight(2026, 11, 2))
        check(edge.intervals(today: now, calendar: utc).count == 2, "The first day after the grid is outside it")
        edge.day = midnight(2026, 11, 1)
        check(edge.intervals(today: now, calendar: utc).count == 1, "The grid's last cell is inside it")
        var closed = selection
        closed.select(midnight(2026, 10, 9), today: now, calendar: utc)
        closed.reopen(closedFor: NotchCalendarSelection.keep - 1)
        check(closed.day == midnight(2026, 10, 9), "Reopening the notch soon keeps the picked day")
        closed.page(by: 2, today: now, calendar: utc)
        closed.reopen(closedFor: NotchCalendarSelection.keep)
        check(closed == NotchCalendarSelection(), "After a longer close the page opens on today and its month")
        // Display choice and the simulated notch.
        let laptop = NotchDisplay(id: "BUILT-IN", name: "Built-in Retina Display", hasNotch: true, isMain: false)
        let dell = NotchDisplay(id: "DELL", name: "DELL U2720Q", hasNotch: false, isMain: true)
        let lg = NotchDisplay(id: "LG", name: "LG UltraFine", hasNotch: false, isMain: false)
        let desk = [dell, laptop, lg]
        check(NotchDisplay.resolve(.notch, in: desk) == laptop && NotchDisplay.resolve(.main, in: desk) == dell,
              "The notch and main choices pick the housing and the menu bar display")
        check(NotchDisplay.resolve(.display(id: "LG", name: "LG UltraFine"), in: desk) == lg, "A chosen display is used while connected")
        check(NotchDisplay.resolve(.display(id: "LG", name: "LG UltraFine"), in: [dell, laptop]) == laptop,
              "A disconnected display falls back to the notch display")
        check(NotchDisplay.resolve(.display(id: "LG", name: "LG UltraFine"), in: [dell]) == dell
              && NotchDisplay.resolve(.notch, in: [dell]) == dell, "Without a notch display the main display takes over")
        check(NotchDisplay.resolve(.main, in: []) == nil, "No display, no placement")
        var simulated = NotchSettings()
        simulated.simulatedNotchWidth = 200
        let plain = NotchGeometry(screenFrame: external.screenFrame, safeTop: 0, leftWidth: nil, rightWidth: nil, settings: simulated)
        check(plain.cutoutWidth == 200 && plain.compactSize == CGSize(width: 280, height: 28),
              "A display without a housing uses the simulated width")
        check(NotchGeometry(screenFrame: geometry.screenFrame, safeTop: 32, leftWidth: 645.5, rightWidth: 645.5,
                            settings: simulated).cutoutWidth == 179, "The housing wins unless the simulated notch is forced")
        simulated.forceSimulatedNotch = true
        let forced = NotchGeometry(screenFrame: geometry.screenFrame, safeTop: 32, leftWidth: 645.5, rightWidth: 645.5, settings: simulated)
        check(forced.cutoutWidth == 200 && forced.topHeight == 32 && forced.frame(.closed).midX == 735,
              "A forced simulated notch keeps the menu bar height and stays centred")
        let chosen = UserDefaults(suiteName: "ro.andrei.NotchLab.DisplayChecks.\(UUID().uuidString)")!
        var remembered = NotchSettings()
        remembered.display = .display(id: "LG", name: "LG UltraFine")
        remembered.save(to: chosen)
        check(NotchSettings.load(from: chosen).display == remembered.display, "A chosen display survives a restart")
        let defaultsOnly = NotchSettings()
        check(!defaultsOnly.hideInFullscreen && !defaultsOnly.hideInMissionControl && !defaultsOnly.hideWhileGaming
              && defaultsOnly.hideFromScreenCapture && defaultsOnly.display == .notch,
              "Only hiding from screen capture is on by default")
        // Visibility rules.
        var hideAll = NotchSettings()
        hideAll.hideInFullscreen = true; hideAll.hideInMissionControl = true; hideAll.hideWhileGaming = true
        check(!NotchSurroundings(fullscreen: true, missionControl: true, game: true).hide(NotchSettings()),
              "Nothing hides the notch while the switches are off")
        check(NotchSurroundings(fullscreen: true).hide(hideAll) && NotchSurroundings(missionControl: true).hide(hideAll)
              && NotchSurroundings(game: true).hide(hideAll) && !NotchSurroundings().hide(hideAll), "Each condition hides on its own")
        let fullscreenSpaces: [[String: Any]] = [["Display Identifier": "BUILT-IN", "Current Space": ["type": 4]],
                                                 ["Display Identifier": "DELL", "Current Space": ["type": 0]]]
        check(NotchSurroundings.fullscreen(spaces: fullscreenSpaces, display: "BUILT-IN")
              && !NotchSurroundings.fullscreen(spaces: fullscreenSpaces, display: "DELL"), "Fullscreen is judged per display")
        check(NotchSurroundings.fullscreen(spaces: [["Display Identifier": "Main", "Current Space": ["type": 4]]], display: "DELL")
              && NotchSurroundings.fullscreen(spaces: [["Display Identifier": "Main", "Current Space": ["type": 0, "TileLayoutManager": [:]]]], display: "DELL")
              && !NotchSurroundings.fullscreen(spaces: [], display: "DELL"),
              "Shared Spaces apply to every display, split view counts, nothing readable means no fullscreen")
        func window(pid: Int32, layer: Int, width: CGFloat, height: CGFloat) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: width, height: height).dictionaryRepresentation]
        }
        let sizes = [CGSize(width: 1470, height: 956)]
        check(NotchSurroundings.missionControl(windows: [window(pid: 90, layer: 19, width: 1470, height: 956)], windowManager: 90, displays: sizes),
              "WindowManager's display-sized backdrop means Mission Control")
        check(!NotchSurroundings.missionControl(windows: [window(pid: 90, layer: -2147483624, width: 1470, height: 956),
                                                          window(pid: 90, layer: 15, width: 169, height: 129),
                                                          window(pid: 91, layer: 20, width: 1470, height: 956)], windowManager: 90, displays: sizes),
              "Its desktop-level windows, small windows and the Dock's display-sized window do not")
        check(NotchSurroundings.game(category: "public.app-category.games", path: "/Applications/Chess.app")
              && NotchSurroundings.game(category: "public.app-category.role-playing-games", path: "/Applications/A.app")
              && NotchSurroundings.game(category: nil, path: "/Users/a/Library/Application Support/Steam/steamapps/common/Hades/Hades.app")
              && !NotchSurroundings.game(category: "public.app-category.developer-tools", path: "/Applications/Xcode.app")
              && !NotchSurroundings.game(category: nil, path: "/Applications/Safari.app"),
              "Games are told by their category or a Steam library")
        // Output devices: which route changes show, and with which symbol.
        let speakers = NotchAudioDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Air Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
        let jack = NotchAudioDevice(uid: "BuiltInHeadphoneOutputDevice", name: "External Headphones", transport: kAudioDeviceTransportTypeBuiltIn)
        let pods = NotchAudioDevice(uid: "AA-BB", name: "Polo’s AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        let monitor = NotchAudioDevice(uid: "HDMI-1", name: "LG HDR 4K", transport: kAudioDeviceTransportTypeHDMI)
        let teams = NotchAudioDevice(uid: "MSTeams", name: "Microsoft Teams Audio", transport: kAudioDeviceTransportTypeVirtual)
        check(!speakers.announced && !teams.announced && jack.announced && pods.announced && monitor.announced,
              "Built-in speakers and virtual devices are never announced; the headphone jack is")
        check(pods.symbol == "airpods.pro" && jack.symbol == "headphones" && monitor.symbol == "display"
              && NotchAudioDevice(uid: "x", name: "Polo's Galaxy Buds Live", transport: kAudioDeviceTransportTypeBluetooth).symbol == "earbuds"
              && NotchAudioDevice(uid: "x", name: "Boxă Vortex", transport: kAudioDeviceTransportTypeBluetooth).symbol == "headphones"
              && NotchAudioDevice(uid: "x", name: "Kitchen", transport: kAudioDeviceTransportTypeAirPlay).symbol == "airplay.audio",
              "Device symbols come from the product name, then the transport")
        var audio = NotchAudioWatch()
        check(audio.update(NotchAudioRoute(devices: [speakers, pods], output: pods)) == nil, "The first route is the baseline")
        check(audio.update(NotchAudioRoute(devices: [speakers, pods, monitor], output: pods)) == nil, "A device that only appears shows nothing")
        check(audio.update(NotchAudioRoute(devices: [speakers, pods, monitor], output: monitor)) == NotchAudioChange(device: monitor, connected: true),
              "Switching the output to a device shows it connected")
        check(audio.update(NotchAudioRoute(devices: [speakers, pods, monitor], output: speakers)) == nil,
              "Switching back to the built-in speakers shows nothing")
        check(audio.update(NotchAudioRoute(devices: [speakers, monitor], output: speakers)) == NotchAudioChange(device: pods, connected: false),
              "A former output going away shows it disconnected, after macOS moved the output first")
        _ = audio.update(NotchAudioRoute(devices: [speakers, monitor, pods], output: pods))
        check(audio.update(NotchAudioRoute(devices: [speakers, monitor], output: speakers)) == NotchAudioChange(device: pods, connected: false),
              "The output going away in the same change shows it disconnected")
        check(audio.update(NotchAudioRoute(devices: [speakers], output: speakers)) == NotchAudioChange(device: monitor, connected: false),
              "A device that was the output a while ago still shows going away")
        let dock = NotchAudioDevice(uid: "USB-1", name: "CalDigit Audio", transport: kAudioDeviceTransportTypeUSB)
        _ = audio.update(NotchAudioRoute(devices: [speakers, dock], output: speakers))
        check(audio.update(NotchAudioRoute(devices: [speakers], output: speakers)) == nil,
              "A device that never was the output leaves silently")
        _ = audio.update(NotchAudioRoute(devices: [speakers, monitor], output: monitor))
        check(audio.update(NotchAudioRoute(devices: [speakers, jack], output: jack)) == NotchAudioChange(device: jack, connected: true),
              "When a device leaves and another becomes the output at once, the new output wins")
        let podsOn = NotchHUD.audioDevice(NotchAudioChange(device: pods, connected: true))
        check(NotchSettings().shows(podsOn) && NotchSettings().duration(for: podsOn) == 3, "Device changes show for 3 s by default")
        var audioState = NotchState()
        _ = audioState.show(.capsLock(on: true))
        check(audioState.show(podsOn) && audioState.hud == podsOn && audioState.shape == .indicator,
              "A device change replaces the indicator shown and widens the wings like the others")
        audioState.hover(true)
        check(!audioState.show(podsOn) && audioState.hud == nil, "An open notch shows no device change")
        // Waiting alerts: arrival order, one per kind, an interrupted one first again, stale ones dropped.
        check(NotchHUD.battery.isAlert && NotchHUD.focus.isAlert && podsOn.isAlert
              && !NotchHUD.volume.isAlert && !NotchHUD.brightness.isAlert && !NotchHUD.capsLock(on: true).isAlert,
              "Battery, Focus and devices are alerts; volume, brightness and Caps Lock are feedback")
        let start = ContinuousClock.now
        let podsOff = NotchHUD.audioDevice(NotchAudioChange(device: pods, connected: false))
        var queue = NotchAlertQueue()
        queue.add(NotchAlert(hud: .battery, remaining: 5, arrived: start))
        queue.add(NotchAlert(hud: podsOn, remaining: 3, arrived: start))
        queue.add(NotchAlert(hud: podsOff, remaining: 3, arrived: start + .seconds(1)))
        check(queue.waiting.map(\.hud) == [.battery, podsOff], "A newer device change replaces the waiting one")
        let first = queue.next(at: start + .seconds(2))
        check(first?.hud == .battery && queue.waiting.map(\.hud) == [podsOff], "Alerts show in order of arrival")
        queue.resume(first!, remaining: 2.4)
        check(queue.waiting.first == NotchAlert(hud: .battery, remaining: 2.4, arrived: start),
              "An interrupted alert goes first with the time it had left")
        queue.removeAll()
        queue.resume(first!, remaining: 3600)
        check(queue.waiting.first?.remaining == 5, "never more than it had")
        queue.removeAll()
        queue.resume(first!, remaining: 0.3)
        check(queue.isEmpty, "An alert interrupted near its end counts as seen")
        queue.add(NotchAlert(hud: .focus, remaining: 1.5, arrived: start))
        queue.add(NotchAlert(hud: .battery, remaining: 5, arrived: start + .seconds(30)))
        check(queue.next(at: start + .seconds(61))?.hud == .battery && queue.isEmpty, "An alert that waited over a minute is dropped")
        // T3 Code: an alert drops below a Quick Peek's level, opening shows its thread, and the page goes away
        // with the link.
        var agents = NotchState()
        agents.agentsEnabled = true
        let thread = NotchAgentThread(id: "t1", title: "Quick Peek", projectID: "p", project: "Eclipse", branch: nil, model: "",
                                      phase: .done, runID: nil, runStarted: nil, runCompleted: nil, updated: .now,
                                      requestID: nil, pullRequest: nil)
        agents.agentPeek = NotchAgentAlert(thread: thread)
        check(agents.shape == .agentPeek && geometry.frame(.agentPeek).size == CGSize(width: 291, height: 74),
              "A T3 alert drops the closed notch at the countdown's width, like a Quick Peek")
        agents.hud = .volume
        check(agents.shape == .indicator, "An indicator covers a T3 alert")
        agents.hud = nil
        agents.hover(true)
        check(agents.shape == .thread && agents.activity == .agents && agents.agentThread == "t1" && agents.agentPeek == nil,
              "Opening over a T3 alert shows that thread's page")
        check(geometry.frame(.thread).size == CGSize(width: 360, height: 220), "A thread's page is D1, 360 × 220")
        var larger = NotchSettings()
        larger.agentAlertScale = 1.2
        let scaled = NotchGeometry(screenFrame: geometry.screenFrame, safeTop: 32, leftWidth: 645.5, rightWidth: 645.5, settings: larger)
        check(scaled.frame(.agentPeek).size == CGSize(width: 349, height: 82) && NotchSettings().agentAlertDuration == 2.5,
              "The alert's size follows its setting; it stays 2.5 s by default")
        agents.swipe(by: 1)
        check(agents.shape == .open && agents.activity == .agents, "A swipe goes back from a thread's page to the list")
        agents.agentThread = "t1"
        agents.hover(false)
        check(agents.agentThread == nil, "Closing leaves a thread's page for the list")
        agents.activity = .music
        agents.hover(true)
        agents.agentPeek = NotchAgentAlert(thread: thread)
        agents.hover(true)
        check(agents.activity == .music && agents.agentThread == nil && agents.agentPeek != nil,
              "An alert waiting under an open notch does not move it to the thread")
        agents.hover(false)
        check(agents.shape == .agentPeek, "and shows once the notch closes")
        agents.agentsEnabled = false
        check(agents.activity == .music && !agents.activities.contains(.agents), "Off, the T3 Code page leaves the swipe order")
        // The level row grows the open Music page downward and belongs to that page alone.
        check(geometry.frame(.openLevel).size == CGSize(width: 320, height: 198) && geometry.frame(.openLevel).maxY == 956
              && geometry.cornerRadius(.openLevel) == geometry.cornerRadius(.open), "The level row adds 30 pt under the open player")
        let rowPoint = CGPoint(x: 735, y: 956 - 185)
        check(geometry.contains(rowPoint, .openLevel) && !geometry.contains(rowPoint, .open),
              "The row's area receives the pointer only while the row shows")
        var levels = NotchState()
        check(!levels.show(level: .volume) && levels.level == nil && levels.shape == .closed, "A closed notch grows no level row")
        levels.hover(true)
        check(levels.show(level: .volume) && levels.shape == .openLevel && levels.acceptsSwipes, "The open Music page grows the row")
        check(levels.show(level: .brightness) && levels.level == .brightness, "The other key switches its kind")
        levels.swipe(by: 1)
        check(levels.level == nil && levels.shape == .open && !levels.show(level: .volume), "Turning the page ends it, and other pages refuse it")
        levels.swipe(by: -1)
        _ = levels.show(level: .volume)
        levels.dragEnter()
        check(levels.level == nil && levels.shape == .open, "A file drag ends it")
        levels.dragExit()
        levels.hover(true)
        _ = levels.show(level: .volume)
        levels.hover(false)
        check(levels.level == nil && levels.shape == .closed, "Closing ends it")
        levels.hover(true)
        check(levels.shape == .open, "and reopening does not bring it back")
        check(NotchSettings().playerLeftButton == .shuffle && NotchSettings().playerRightButton == .repeat,
              "The slots default to shuffle and repeat, the approved player")
        // Like goes to Music, to Spotify once its Client ID is set, and to YouTube pages in Safari; the rest have none.
        let video = URL(string: "https://www.youtube.com/watch?v=abc")!
        check(NotchLikeTarget(bundleIdentifier: "com.apple.Music", page: nil) == .music
              && NotchLikeTarget(bundleIdentifier: "com.apple.Safari", page: video) == .youTube(video)
              && NotchLikeTarget(bundleIdentifier: "com.apple.Safari", page: URL(string: "https://music.youtube.com/watch?v=abc")) != .unsupported,
              "Like reaches Music and YouTube in Safari")
        check(NotchLikeTarget(bundleIdentifier: "com.spotify.client", page: nil) == .unsupported
              && NotchLikeTarget(bundleIdentifier: "com.apple.Safari", page: URL(string: "https://www.netflix.com/watch/1")) == .unsupported
              && NotchLikeTarget(bundleIdentifier: "com.apple.Safari", page: nil) == .unsupported,
              "Spotify without a Client ID, other sites and an unread Safari tab have no like")
        check(NotchLikeReply(status: 0, output: "true\n", error: "") == .liked(true)
              && NotchLikeReply(status: 0, output: "false", error: "") == .liked(false)
              && NotchLikeReply(status: 0, output: "missing\n", error: "") == .missing
              && NotchLikeReply(status: 1, output: "", error: "You must enable 'Allow JavaScript from Apple Events'") == .javaScriptOff
              && NotchLikeReply(status: 1, output: "", error: "Not authorized to send Apple events (-1743)") == .failed,
              "Like replies parse, Safari's JavaScript refusal apart from other failures")
        check(NotchLikeReply(status: 0, output: "changed\n", error: "") == .changed, "Music reports another track playing")
        // The YouTube script runs only on the video asked about, and a title is data, never code.
        func page(playing: String?, pageTitle: String = "", script: String) -> (reply: String?, clicks: Int32) {
            let context = JSContext()!
            context.setObject(playing, forKeyedSubscript: "playingTitle" as NSString)
            context.setObject(pageTitle, forKeyedSubscript: "pageTitle" as NSString)
            context.evaluateScript("""
                var clicks = 0;
                var navigator = { mediaSession: { metadata: playingTitle == null ? null : { title: playingTitle } } };
                var button = { getAttribute: function () { return 'false'; }, click: function () { clicks += 1; } };
                var document = { title: pageTitle, querySelector: function () { return button; } };
                """)
            let reply = context.evaluateScript(script)?.toString()
            return (reply, context.objectForKeyedSubscript("clicks").toInt32())
        }
        let liked = page(playing: "Video A", script: NotchLike.youTubeScript(toggle: true, title: "Video A"))
        check(liked.reply == "true" && liked.clicks == 1, "Like clicks on the video asked about")
        let next = page(playing: "Video B", script: NotchLike.youTubeScript(toggle: true, title: "Video A"))
        check(next.reply == "changed" && next.clicks == 0, "and leaves the next video in the same tab alone")
        let tricky = #"A "quoted" title'); clicks = 99; ('"#
        let quoted = page(playing: tricky, script: NotchLike.youTubeScript(toggle: true, title: tricky))
        check(quoted.reply == "true" && quoted.clicks == 1, "A title with quotes stays a string")
        check(page(playing: nil, pageTitle: "(3) Video A - YouTube",
                   script: NotchLike.youTubeScript(toggle: false, title: "Video A")).reply == "false",
              "A page without media session details is known by its own title")
        let unnamed = page(playing: nil, script: NotchLike.youTubeScript(toggle: true, title: "Video A"))
        check(unnamed.reply == "missing" && unnamed.clicks == 0, "A page that names no video is left alone")
        let composed = page(playing: "Caf\u{E9}  del Mar", script: NotchLike.youTubeScript(toggle: true, title: "Cafe\u{301} del Mar"))
        check(composed.reply == "true" && composed.clicks == 1, "Composed and decomposed accents and extra spaces match")
        let live = page(playing: "Video A (Live)", script: NotchLike.youTubeScript(toggle: true, title: "Video A"))
        let accent = page(playing: "Cafe del Mar", script: NotchLike.youTubeScript(toggle: true, title: "Caf\u{E9} del Mar"))
        check(live.reply == "changed" && accent.reply == "changed" && live.clicks + accent.clicks == 0,
              "Genuinely different titles do not")
        // Like follows the track in view: a reply for one track never lands on the next.
        let trackA = NotchLikeRequest(target: .music, track: "A-X-", title: "A", artist: "X")
        let trackB = NotchLikeRequest(target: .music, track: "B-X-", title: "B", artist: "X")
        var ledger = NotchLikeLedger()
        check(ledger.show(nil) == nil && ledger.beginToggle() == nil, "Out of view, nothing is read or toggled")
        let readA = ledger.show(trackA)
        let readB = ledger.show(trackB)
        check(readA != nil && readB != nil && !ledger.finishRead(.liked(true), generation: readA!) && ledger.liked == nil,
              "A skipped track's read is dropped")
        check(ledger.finishRead(.liked(false), generation: readB!) && ledger.liked == false, "The latest read lands")
        _ = ledger.show(trackA)
        _ = ledger.finishRead(.liked(false), generation: ledger.generation)
        check(ledger.beginToggle() == trackA && ledger.liked == true && ledger.beginToggle() == nil,
              "A press flips the heart at once and a second waits for the toggle")
        check(ledger.show(trackB) == nil && ledger.liked == nil, "A skip during the toggle blanks the heart and waits")
        let skipped = ledger.finishToggle(.liked(true), serial: ledger.toggleSerial)
        check(!skipped.landed && skipped.read != nil && ledger.request == trackB && ledger.liked == nil,
              "The toggle's reply for the skipped track stays off the new one, which is then read")
        check(ledger.finishRead(.liked(false), generation: skipped.read!) && ledger.liked == false, "and its read lands")
        _ = ledger.beginToggle()
        let failed = ledger.finishToggle(.changed, serial: ledger.toggleSerial)
        check(failed.landed && failed.read == nil && ledger.liked == false, "A toggle Music refused puts the like back")
        let hidden = ledger.show(nil)
        check(hidden == nil && ledger.liked == false && ledger.reread() == nil && ledger.beginToggle() == nil,
              "Leaving the page keeps the heart, stops reads and ignores presses")
        let hiddenRead = ledger.generation
        check(!ledger.finishRead(.liked(true), generation: hiddenRead - 1), "A read under way when the page left is dropped")

        // Timer: labels, ticks, phases, pause and restore, on a reference date with a fractional part, as real
        // dates have.
        check(NotchState().activities == [.music, .calendar, .timer, .shelf], "The Timer page follows Calendar")
        var noTimer = NotchState()
        noTimer.activity = .timer
        noTimer.timerEnabled = false
        check(noTimer.activity == .music && !noTimer.activities.contains(.timer), "Off, the Timer page leaves the swipe order")
        check(NotchTimerRun.label(0) == "0:00" && NotchTimerRun.label(59) == "0:59" && NotchTimerRun.label(299) == "4:59"
              && NotchTimerRun.label(3600) == "1:00:00" && NotchTimerRun.label(3899) == "1:04:59",
              "Timer labels are m:ss, h:mm:ss from an hour")
        let origin = Date(timeIntervalSinceReferenceDate: 813_000_000.123_456)
        let five = NotchTimerRun.start(300, at: origin)
        check(five.seconds(at: origin) == 300 && five.seconds(at: origin.addingTimeInterval(299.5)) == 1
              && five.seconds(at: origin.addingTimeInterval(300)) == 0, "A timer starts on its length and ends on 0")
        /// Follows a run's ticks as the timer would, each wake landing up to 5 ms early or 400 ms late, and returns
        /// every label shown, a label shown again on an early wake counted once, with the phases announced.
        func walk(_ run: NotchTimerRun, from start: Date) -> (labels: [Int], phases: [Int]) {
            var labels = [run.seconds(at: start)], phases: [Int] = []
            var now = start, last = start, seed: UInt64 = 7
            while let next = run.nextTick(after: now) {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                now = next.addingTimeInterval(Double(seed >> 33 % 406) / 1000 - 0.005)
                if let phase = run.phase(after: last, at: now) { phases.append(phase) }
                last = now
                if run.seconds(at: now) != labels.last { labels.append(run.seconds(at: now)) }
            }
            return (labels, phases)
        }
        let walked = walk(NotchTimerRun.start(25 * 60, at: origin), from: origin)
        check(walked.labels == Array((0...1500).reversed()), "Jittered wakes neither skip nor repeat a second")
        check(walked.phases == [10, 5, 1], "A 25 min timer announces 10, 5 and 1 min left, once each")
        check(walk(five, from: origin).phases == [1] && walk(NotchTimerRun.start(600, at: origin), from: origin).phases == [5, 1]
              && walk(NotchTimerRun.start(60, at: origin), from: origin).phases.isEmpty,
              "Only phases shorter than the timer are announced")
        let tenMark = origin.addingTimeInterval(15 * 60)
        let long = NotchTimerRun.start(25 * 60, at: origin)
        check(long.phase(after: tenMark.addingTimeInterval(-1), at: tenMark.addingTimeInterval(0.2)) == 10
              && long.phase(after: tenMark.addingTimeInterval(-60), at: tenMark.addingTimeInterval(120)) == nil,
              "A phase crossed during sleep is not announced late")
        var paused = five
        paused.pause(at: origin.addingTimeInterval(100.4))
        check(paused.paused && paused.seconds(at: origin.addingTimeInterval(5000)) == 200 && paused.nextTick(after: origin) == nil
              && paused.phase(after: origin, at: origin.addingTimeInterval(5000)) == nil,
              "Pausing keeps the time left and stops ticking")
        paused.resume(at: origin.addingTimeInterval(1000))
        check(paused.seconds(at: origin.addingTimeInterval(1000)) == 200
              && paused.seconds(at: origin.addingTimeInterval(1199.6)) == 0, "Resuming counts on from the same second")
        var added = five
        added.add(60, at: origin)
        check(added.total == 360 && added.seconds(at: origin) == 360, "+1 min lengthens the timer and its whole")
        let stored = try! JSONDecoder().decode(NotchTimerRun.self, from: JSONEncoder().encode(paused))
        check(stored == paused && stored.seconds(at: origin.addingTimeInterval(1000)) == 200, "A stored timer restores as it was")
        var phaseQueue = NotchAlertQueue()
        let queued = ContinuousClock.now
        phaseQueue.add(NotchAlert(hud: .timer(minutes: 10), remaining: 2, arrived: queued))
        phaseQueue.add(NotchAlert(hud: .timer(minutes: 5), remaining: 2, arrived: queued))
        check(phaseQueue.waiting.count == 1 && phaseQueue.next(at: queued + .seconds(11)) == nil,
              "Only the newest phase alert waits, and only for 10 s")
        check(NotchTimerDial.step(58, by: 3) == 65 && NotchTimerDial.step(65, by: -2) == 59
              && NotchTimerDial.step(2, by: -5) == 1 && NotchTimerDial.step(720, by: 1) == 720,
              "The dial steps by minutes to an hour, then by five, within its range")
        // Corrupt or tampered defaults: a stored run is checked before it is trusted, and nothing traps.
        let huge = NotchTimerRun(clock: .paused(remaining: 1e20), total: 1e20)
        check(!huge.isValid(at: origin) && huge.seconds(at: origin) == 43_200, "An oversized run is rejected and its seconds stay safe")
        check(!NotchTimerRun(clock: .running(end: origin.addingTimeInterval(1e12)), total: 60).isValid(at: origin)
              && !NotchTimerRun(clock: .paused(remaining: .nan), total: 60).isValid(at: origin)
              && NotchTimerRun(clock: .paused(remaining: 30), total: 60).isValid(at: origin)
              && NotchTimerRun.start(60, at: origin).isValid(at: origin.addingTimeInterval(500)),
              "Only finite runs with no more left than their length are valid, ended ones included")
        var full = NotchTimerRun.start(NotchTimerRun.maximum - 30, at: origin)
        full.add(60, at: origin)
        check(full.total == NotchTimerRun.maximum && full.seconds(at: origin) == 43_200, "+1 min stops at 12 h")
        check(NotchTimerDial.clamp(100_000) == 720 && NotchTimerDial.clamp(-3) == 1, "The dial clamps to its range")
        // With nothing showing the seconds, a timer wakes only at its phases and its end.
        let quarter = NotchTimerRun.start(25 * 60, at: origin)
        check(quarter.nextMoment(after: origin) == origin.addingTimeInterval(15 * 60)
              && quarter.nextMoment(after: origin.addingTimeInterval(24 * 60)) == origin.addingTimeInterval(25 * 60)
              && five.nextMoment(after: origin) == origin.addingTimeInterval(4 * 60) && huge.nextMoment(after: origin) == nil,
              "Unseen, a timer wakes at its next phase or its end, never while paused")

        // The right wing's wave moves only while it can be seen doing so.
        let defaults = NotchSettings()
        check(defaults.playingWave && defaults.waveStyle == .bars && !defaults.waveArtworkColor
              && defaults.artworkTransition == .slide, "The wave is on, as white bars; artwork slides by default")
        check(NotchWave.moves(playing: true, shape: .closed), "The wave moves while a track plays in the closed notch")
        check(!NotchWave.moves(playing: false, shape: .closed), "Paused, it rests")
        check([NotchShape.open, .openLevel, .thread, .indicator, .timerAlert, .timerDone, .trackPeek, .eventPeek, .agentPeek,
               .screenshot, .dictation].allSatisfy { !NotchWave.moves(playing: true, shape: $0) },
              "Open, or with an indicator, the timer, a peek, a screenshot or dictation in the notch, it rests")
        var timing = NotchState()
        timing.timer = true
        check(!NotchWave.moves(playing: true, shape: timing.shape), "A running timer takes the right wing from the wave")
        var wave = NotchWaveMotion()
        check(!wave.moves(at: 0) && !wave.update(moving: false, visible: true, at: 0), "At rest nothing moves or changes")
        check(wave.update(moving: true, visible: true, at: 1) && wave.amplitude(at: 1) == 0 && wave.amplitude(at: 1.6) == 1
              && !wave.update(moving: true, visible: true, at: 2), "Moving, it rises from rest once")
        let fadeEnd = 10 + NotchWave.ease
        check(wave.update(moving: false, visible: true, at: 10) && wave.moves(at: fadeEnd - 0.1) && !wave.moves(at: fadeEnd)
              && wave.amplitude(at: fadeEnd) == 0,
              "A pause flattens the wave during the wings' fade and stops it when the artwork has gone, with no settle after")
        _ = wave.update(moving: true, visible: true, at: 20)
        let risen = wave.amplitude(at: 20.3)
        check(wave.update(moving: false, visible: true, at: 20.3) && abs(wave.amplitude(at: 20.3) - risen) < 1e-9,
              "A pause mid-rise flattens from where the rise had got to")
        check(wave.update(moving: false, visible: false, at: 20.4) && !wave.moves(at: 20.4) && wave.amplitude(at: 20.4) == 0,
              "Hidden, locked, covered or with the displays asleep, it stops at once, mid-settle too")
        check(wave.update(moving: true, visible: true, at: 30) && wave.amplitude(at: 30) == 0, "Seen again, it rises from rest")
        let bar = { (time: Double) in NotchWave.looped(at: time) { NotchWave.level(2, at: $0) } }
        check(abs(bar(NotchWave.period - 1e-6) - bar(0)) < 1e-4 && bar(NotchWave.period * 3 + 1) == bar(1)
              && bar(5) == NotchWave.level(2, at: 5), "The motion repeats every period without a jump at the seam")
        /// A solid square encoded as PNG, as a player reports artwork.
        func artwork(_ color: NSColor, side: Int = 600) -> String {
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
            let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            return png?.base64EncodedString() ?? ""
        }
        let red = NotchWave.tint(artwork: artwork(.init(srgbRed: 0.5, green: 0, blue: 0, alpha: 1)))?.usingColorSpace(.sRGB)
        check(red.map { $0.redComponent > 0.85 && $0.greenComponent > 0.3 && $0.saturationComponent <= 0.61 } == true,
              "A dark red cover tints the wave a bright, softened red")
        let grey = NotchWave.tint(artwork: artwork(.black))?.usingColorSpace(.sRGB)
        check(grey.map { $0.brightnessComponent >= 0.89 && $0.saturationComponent < 0.01 } == true, "A black cover tints it white")
        check(NotchWave.tint(artwork: "not an image") == nil, "Unreadable artwork has no tint")
        let samples = stride(from: 0.0, to: 600, by: 0.37)
        check(samples.allSatisfy { time in (0..<NotchWave.bars).allSatisfy { (0...1).contains(NotchWave.level($0, at: time)) } }
              && samples.allSatisfy { abs(NotchWave.line(at: 0.5, time: $0)) <= 1 },
              "Bar levels stay within 0...1 and the line within its height")
        check(samples.allSatisfy { abs(NotchWave.line(at: 0, time: $0)) < 1e-9 && abs(NotchWave.line(at: 1, time: $0)) < 1e-9 },
              "The line is pinned at both ends")

        // The player's artwork turns once per new image, the way Eclipse's own skip went.
        let turnStart = ContinuousClock.now
        var flow = NotchArtworkFlow()
        check(flow.report(1, at: turnStart) == .turned && flow.turn == .init(number: 1, direction: .next),
              "The first image turns in, forward")
        check(flow.report(1, at: turnStart + .seconds(1)) == .unchanged, "A pause, a seek or a new title keep the same image")
        flow.skipped(.previous, at: turnStart + .seconds(2))
        check(flow.report(nil, at: turnStart + .seconds(2.1)) == .wait(until: turnStart + .seconds(2.1) + NotchArtworkFlow.settle),
              "A removed image waits a moment for the next one")
        check(flow.report(nil, at: turnStart + .seconds(2.2)) == .wait(until: turnStart + .seconds(2.1) + NotchArtworkFlow.settle),
              "Repeated reports while it waits do not postpone it")
        check(flow.report(2, at: turnStart + .seconds(2.3)) == .turned && flow.turn == .init(number: 2, direction: .previous),
              "An image arriving meanwhile is one turn straight to it, back after Previous")
        check(flow.report(3, at: turnStart + .seconds(3)) == .turned && flow.turn.direction == .next,
              "A skip sets the direction of one turn only")
        flow.skipped(.previous, at: turnStart + .seconds(4))
        check(flow.report(4, at: turnStart + .seconds(9)) == .turned && flow.turn.direction == .next,
              "A skip long ago no longer sets the direction")
        _ = flow.report(nil, at: turnStart + .seconds(10))
        check(flow.report(nil, at: turnStart + .seconds(10) + NotchArtworkFlow.settle) == .turned && flow.shown == nil
              && flow.turn.number == 5, "A track without artwork turns to the placeholder once the moment has passed")
        check(flow.report(5, at: turnStart + .seconds(11)) == .turned && flow.turn.number == 6, "and on to artwork arriving later")

        func pose(_ transition: NotchArtworkTransition, _ progress: Double, _ direction: NotchSkipDirection = .next,
                  outgoing: Bool, reduceMotion: Bool = false) -> NotchArtworkPose {
            NotchArtworkPose(transition, progress: progress, direction: direction, outgoing: outgoing, reduceMotion: reduceMotion)
        }
        check(pose(.slide, 0, outgoing: false).offset > 0 && pose(.slide, 0.5, outgoing: true).offset < 0
              && pose(.slide, 0, .previous, outgoing: false).offset < 0 && pose(.slide, 0.5, .previous, outgoing: true).offset > 0,
              "A slide brings the next artwork in from the right and the previous one from the left")
        check(pose(.slide, 1, outgoing: false) == NotchArtworkPose() && pose(.slide, 0, outgoing: true) == NotchArtworkPose(),
              "A slide starts and ends with the faces in place")
        let progresses = stride(from: 0.0, through: 1, by: 0.05)
        check(progresses.allSatisfy { pose(.flip, $0, outgoing: true).opacity + pose(.flip, $0, outgoing: false).opacity == 1 },
              "A flip shows exactly one face at a time")
        check(progresses.allSatisfy { progress in
            [NotchArtworkTransition.crossfade, .blur].allSatisfy { pose($0, progress, outgoing: true).opacity == 1 }
        }, "Fade and blur keep the old artwork whole beneath the new one, so the tile is never empty")
        check(progresses.allSatisfy { progress in
            NotchArtworkTransition.allCases.allSatisfy { style in
                var plain = NotchArtworkPose()
                plain.opacity = progress
                return pose(style, progress, outgoing: false, reduceMotion: true) == plain
                    && pose(style, progress, outgoing: true, reduceMotion: true) == NotchArtworkPose()
            }
        }, "Under Reduce Motion every style only crossfades")

        // Seeking from the progress bar: the chosen position holds until the player reports it.
        let sentAt = Date(timeIntervalSinceReferenceDate: 813_000_000)
        let sent = NotchSeek(target: 120, at: sentAt, playing: true, track: "a")
        check(sent.position(reported: 30, at: sentAt.addingTimeInterval(0.5)) == 120.5,
              "After a seek the bar keeps the chosen position, running on with playback, while the player reports the old one")
        check(sent.position(reported: 121, at: sentAt.addingTimeInterval(1)) == nil, "and lets go once the player reports one near it")
        check(sent.position(reported: 30, at: sentAt.addingTimeInterval(NotchSeek.patience)) == nil,
              "A player that never confirms is believed after a moment")
        check(NotchSeek(target: 120, at: sentAt, playing: false, track: "a").position(reported: 30, at: sentAt.addingTimeInterval(2)) == 120,
              "Paused, the chosen position stays put")
        var hold = NotchSeekHold()
        hold.send(120, at: sentAt, playing: false, track: "a")
        hold.settle(reported: 30, track: "a", at: sentAt.addingTimeInterval(1))
        check(hold.pending != nil, "A paused seek holds while the player has not confirmed it")
        if let seek = hold.pending { hold.expire(seek) }
        check(hold.pending == nil, "and its deadline clears it without waiting for a redraw")
        hold.send(120, at: sentAt, playing: false, track: "a")
        hold.settle(reported: 120.5, track: "a", at: sentAt.addingTimeInterval(1))
        check(hold.pending == nil, "Confirmation ends the hold before the deadline")
        hold.send(120, at: sentAt, playing: true, track: "a")
        check(hold.position(reported: 30, track: "b", at: sentAt.addingTimeInterval(1)) == nil,
              "A new track shows its own position at once")
        hold.settle(reported: 30, track: "b", at: sentAt.addingTimeInterval(1))
        check(hold.pending == nil, "and forgets the seek")
        hold.send(120, at: sentAt, playing: false, track: "a")
        let replaced = hold.pending
        hold.send(60, at: sentAt.addingTimeInterval(2), playing: false, track: "a")
        if let replaced { hold.expire(replaced) }
        check(hold.position(reported: 30, track: "a", at: sentAt.addingTimeInterval(3)) == 60,
              "A second seek replaces the first, whose deadline no longer clears it")
        // The like reads and the progress ticks only while the player is on screen.
        var player = NotchState()
        check(!player.playerOnScreen, "The closed notch shows no player")
        player.hover(true)
        check(player.playerOnScreen, "The open Music page does")
        player.swipe(by: 1)
        check(!player.playerOnScreen, "Another page does not")
        player.swipe(by: -1)
        player.dragEnter()
        check(!player.playerOnScreen, "Nor do drop targets over it")
        checkWebPages(check)
        checkSourcePick(check)
        checkScriptedPlayers(check)
        checkConfirmations(check)
        print("\(checks) checks passed")
    }
}

/// Web video read from the page (Netflix and YouTube in Safari): parsing, the presentation and when reads run. The
/// Netflix text is what Safari returned for a playing tab's player on 7 October 2026; JavaScript from Apple Events was
/// off. Read again with the controls idle, the same tab's text was only blank lines.
@MainActor
private func checkWebPages(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let netflix = NotchWebSite(name: "Netflix", host: "netflix.com", url: URL(string: "https://www.netflix.com/watch/80014505?trackId=1")!,
                               matchesTrack: true)
    let youTube = NotchWebSite(name: "YouTube", host: "youtube.com", url: URL(string: "https://www.youtube.com/watch?v=Q4u5NKi5mOk")!,
                               matchesTrack: true)
    let request = NotchWebPageRequest(site: netflix, title: "Netflix", durationKnown: false)!
    let episode = "https://www.netflix.com/watch/80014505"
    func reply(_ text: String) -> NotchWebPagePoll.Outcome {
        NotchWebPages.outcome(of: "text\n\(episode)?trackId=264293154&tctx=1%2C0\n" + text, for: request)
    }
    func page(_ text: String) -> NotchWebPage? { NotchWebPage.parse(netflixText: text) }
    // Subtitles, five blank lines, the time left, eight blank lines, then the title heading run together, last.
    let playing = "Deci pleci să te distrezi și ne lași cu\nPhilo să scoatem castanele din foc?\n\n\n\n\n\n39:09"
        + "\n\n\n\n\n\n\n\n\nThe MentalistE17Cheap Burgundy" + String(repeating: "\n", count: 11)
    check(reply(playing) == .read(NotchWebPage(title: "The Mentalist", subtitle: "E17 · Cheap Burgundy", content: episode)),
          "Netflix's text names the show and the episode, for the video in the tab's address without its query")
    check(reply("\n\n\n") == .empty(content: episode) && reply("Deci pleci\nPhilo?\n") == .empty(content: episode),
          "The idle player's blank text, or subtitles alone, name nothing")
    // Subtitle lines are never the heading: one cue's lines follow each other directly, and the heading comes last.
    check(page("12:34\nRun, hide!") == nil && page("Hi\n\n12:34\n\nRun, hide!") == nil
          && page("39:09\n\n\n\nThe MentalistE17Cheap Burgundy\n\n\nRun, hide!") == nil,
          "A line after a time inside the subtitles, or after the heading, is not taken")
    check(page("\n\n\n1:02:03\n\n\n\nGlass Onion: A Knives Out Mystery\n")?.title == "Glass Onion: A Knives Out Mystery"
          && page("\n\n\n1:02:03\n\n\n\nGlass Onion\n")?.subtitle == nil,
          "A film's heading stays whole, without an episode, after an hours-long time left")
    check(page("Mi-e frică\n\n\n\n24:10\n\n\n\nLa casa de papelT1:E3Ai greșit\n")
          == NotchWebPage(title: "La casa de papel", subtitle: "T1:E3 · Ai greșit"),
          "Localized text and season markers split")
    // Splitting the heading.
    func split(_ line: String) -> [String?]? { NotchWebPage.split(line).map { [$0.title, $0.subtitle] } }
    check(split("The MentalistE17Cheap Burgundy") == ["The Mentalist", "E17 · Cheap Burgundy"]
          && split("ShowT5:E17Episode") == ["Show", "T5:E17 · Episode"]
          && split("The Mentalist S5:E17 Cheap Burgundy") == ["The Mentalist", "S5:E17 · Cheap Burgundy"]
          && split("DarkF3Vergangenheit und Gegenwart") == ["Dark", "F3 · Vergangenheit und Gegenwart"]
          && split("The Office (U.S.)E3Health Care") == ["The Office (U.S.)", "E3 · Health Care"],
          "Episodes and seasons split where they run into the show")
    check(split("Glass Onion") == ["Glass Onion", nil] && split("M3GAN") == ["M3GAN", nil] && split("Apollo 13") == ["Apollo 13", nil],
          "Films stay whole")
    check(split("SE7EN") == nil && split("SUITSE3Pilot") == nil && split("ShowE3iCarly") == nil,
          "A marker run into a word that cannot be told apart is rejected rather than split wrongly")
    // Which tab answered.
    check(NotchWebPages.outcome(of: "same\n\(episode)?trackId=9", for: request) == .unchanged(content: episode)
          && NotchWebPages.outcome(of: "ambiguous", for: request) == .unavailable
          && NotchWebPages.outcome(of: "missing", for: request) == .unavailable
          && NotchWebPages.outcome(of: "off", for: request) == .unavailable
          && NotchWebPages.outcome(of: "text\nhttps://www.netflix.com/watch/?x=1\n" + playing, for: request) == .unavailable,
          "Two player tabs, none, or a Netflix page without a video read nothing")
    check(request.content(of: "https://www.netflix.com/watch/81234567#t") == "https://www.netflix.com/watch/81234567"
          && request.content(of: "https://www.netflix.com/browse") == nil,
          "The video is the player's /watch/ id")
    // The page script against stand-ins for Netflix's player and a YouTube watch page.
    let at = Date(timeIntervalSince1970: 1_000)
    func run(_ setup: String) -> String {
        let context = JSContext()!
        context.evaluateScript(setup)
        return context.evaluateScript(NotchWebPages.pageScript).toString()
    }
    let netflixPage = run("""
        var heading = { textContent: 'The MentalistE17Cheap Burgundy',
          children: [{ textContent: 'The Mentalist' }, { textContent: 'E17' }, { textContent: ' Cheap Burgundy ' }] };
        var video = { currentTime: 302.5, duration: 2700, paused: false, clientWidth: 1440, clientHeight: 810 };
        var navigator = {};
        var document = { title: 'Netflix', querySelector: function (s) { return s === '[data-uia="video-title"]' ? heading : null; },
          querySelectorAll: function () { return [video]; } };
        """)
    let read = NotchWebPage.parse(script: netflixPage, expected: nil, now: at)
    check(read?.title == "The Mentalist" && read?.subtitle == "E17 · Cheap Burgundy"
          && read?.progress == NotchWebPage.Progress(elapsed: 302.5, duration: 2700, playing: true, at: at),
          "The page script reads Netflix's heading and video")
    check(read?.progress?.elapsed(at: at.addingTimeInterval(3)) == 305.5 && read?.progress?.elapsed(at: at.addingTimeInterval(9_999)) == 2700,
          "The page's position runs on while playing, up to the end")
    let youTubePage = run("""
        var navigator = { mediaSession: { metadata: { title: 'NBA Top 10', artist: 'NBA' } } };
        var document = { title: 'NBA Top 10 - YouTube', querySelector: function () { return null; },
          querySelectorAll: function () { return [{ currentTime: 5, duration: NaN, paused: true, clientWidth: 1, clientHeight: 1 }]; } };
        """)
    check(NotchWebPage.parse(script: youTubePage, expected: "NBA Top 10")?.progress == nil,
          "A video without a finite duration gives no position")
    let video = NotchWebPageRequest(site: youTube, title: "NBA Top 10", durationKnown: false)!
    check(NotchWebPages.outcome(of: "js\n\(youTube.url.absoluteString)\n" + youTubePage, for: video) != .unavailable
          && NotchWebPages.outcome(of: "js\n\(youTube.url.absoluteString)\n" + youTubePage,
                                   for: NotchWebPageRequest(site: youTube, title: "Another video", durationKnown: false)!) == .unavailable,
          "A page playing another video than the track is not its page")
    // What the open player shows.
    let bare = NotchPlayerPresentation(title: "Netflix", artist: "", duration: nil, hasArtwork: true, player: "Safari", kind: .netflix,
                                       site: netflix, page: nil)
    check(bare.title == "Netflix" && bare.subtitle == "Safari" && bare.siteTile && bare.progress == .hidden,
          "Netflix alone: its logo as a site tile, no badge, no empty times, no repeated name")
    let full = NotchPlayerPresentation(title: "Netflix", artist: "", duration: nil, hasArtwork: true, player: "Safari", kind: .netflix,
                                       site: netflix, page: read)
    check(full.title == "The Mentalist" && full.subtitle == "E17 · Cheap Burgundy" && full.progress == .page(read!.progress!),
          "Netflix read: the show, the episode and the page's position, display only")
    let reported = NotchPlayerPresentation(title: "Netflix", artist: nil, duration: 2700, hasArtwork: true, player: "Safari", kind: .netflix,
                                           site: netflix, page: NotchWebPage(title: "Glass Onion"))
    check(reported.subtitle == "Netflix" && reported.progress == .player(duration: 2700, seekable: false),
          "A film keeps the website below it, and Netflix is never sought through MediaRemote")
    let clip = NotchPlayerPresentation(title: "NBA Top 10", artist: "NBA", duration: 129, hasArtwork: true, player: "Safari", kind: .youTube,
                                       site: youTube, page: nil)
    check(clip.title == "NBA Top 10" && clip.subtitle == "NBA" && !clip.siteTile && clip.progress == .player(duration: 129, seekable: true),
          "YouTube keeps its own artwork, badge and seekable bar")
    check(NotchPlayerPresentation(title: "Clip", artist: nil, duration: 60, hasArtwork: false, player: "Safari", kind: .youTube, site: youTube, page: nil)
          .siteTile, "A website without artwork gets the site tile")
    let app = NotchPlayerPresentation(title: "Weightless", artist: "  ", duration: .infinity, hasArtwork: false, player: "Spotify",
                                      kind: .app, site: nil, page: nil)
    check(app.subtitle == "Spotify" && app.progress == .player(duration: 0, seekable: false) && !app.siteTile,
          "An app without times keeps its empty row, so the transport never moves, and names the player")
    // Which layout each source gets.
    func shown(_ title: String?, _ artist: String?, duration: TimeInterval? = nil, artwork: Bool, player: String = "Safari",
               kind: NotchMediaKind = .genericWeb, site: NotchWebSite?) -> NotchPlayerPresentation {
        NotchPlayerPresentation(title: title, artist: artist, duration: duration, hasArtwork: artwork, player: player,
                                kind: kind, site: site, page: nil)
    }
    check(NotchMediaKind(host: "netflix.com") == .netflix && NotchMediaKind(host: "youtube.com") == .youTube
          && NotchMediaKind(host: "music.youtube.com") == .youTube && NotchMediaKind(host: "soundcloud.com") == .genericWeb,
          "Netflix, YouTube and YouTube Music by their host; any other website is generic web media")
    check(bare.skips && bare.logoArtwork && clip.skips && app.skips, "Netflix, YouTube and apps keep the full transport")
    let soundCloud = NotchWebSite(name: "SoundCloud", host: "soundcloud.com", url: URL(string: "https://soundcloud.com/a/b")!,
                                  matchesTrack: true)
    let track = shown("Midnight City", "M83", duration: 243, artwork: true, site: soundCloud)
    check(!track.skips && track.siteTile && track.subtitle == "M83" && track.progress == .player(duration: 243, seekable: true),
          "A page reporting its own artwork and artist is still generic: the site tile, no skips, a seekable bar")
    let bbc = NotchWebSite(name: "bbc.co.uk", host: "bbc.co.uk", url: URL(string: "https://www.bbc.co.uk/news/1")!, matchesTrack: true)
    let page = shown("Inside the Large Hadron Collider", "", artwork: false, site: bbc)
    check(!page.skips && page.siteTile && !page.logoArtwork && page.progress == .hidden
          && page.title == "Inside the Large Hadron Collider" && page.subtitle == "bbc.co.uk",
          "Any other page: its title and site on a site tile, play or pause alone, no row without times")
    check(shown("Inside CERN", "", duration: 754, artwork: false, site: bbc).progress == .player(duration: 754, seekable: true),
          "Generic web media with real times keeps a seekable bar")
    check(shown("SoundCloud", "M83", artwork: true, site: soundCloud).logoArtwork,
          "A title that is only the site's name makes its artwork the site's logo")
    let chrome = shown("A video", nil, artwork: false, player: "Google Chrome", site: nil)
    check(chrome.siteTile && !chrome.skips && chrome.subtitle == "Google Chrome",
          "Another browser's page: the glyph tile, the browser's name, no skips")
    let zen = shown("NBA Top 10", "NBA", duration: 129, artwork: true, player: "Zen", kind: .youTube, site: nil)
    check(zen.skips && !zen.siteTile && zen.subtitle == "NBA" && zen.progress == .player(duration: 129, seekable: true),
          "YouTube recognised in another browser keeps its thumbnail, channel, skips and seekable bar")
    let waiting = shown("Netflix", "", artwork: true, kind: .pending, site: nil)
    check(!waiting.skips && waiting.siteTile && !waiting.logoArtwork && waiting.progress == .hidden,
          "While the website is read: a tile without its logo, play or pause alone, no row without times")
    check(NotchWebSites.browsers.contains("com.google.Chrome") && NotchWebSites.browsers.contains("app.zen-browser.zen")
          && !NotchWebSites.browsers.contains("com.spotify.client"),
          "Chrome and Zen media is web media; Spotify's is not")
    // How long a browser track waits for its website.
    var wait = NotchMediaKindWait()
    wait.follow(player: "zen", title: "Clip", now: at)
    check(wait.kind(host: nil, reading: true, now: at) == .pending
          && wait.kind(host: nil, reading: true, now: at.addingTimeInterval(1)) == .pending,
          "A player's first track waits, neutral, while its website is read")
    check(wait.kind(host: "youtube.com", reading: true, now: at.addingTimeInterval(1.2)) == .youTube && wait.deadline == nil,
          "A website found decides at once")
    wait.follow(player: "zen", title: "Next clip", now: at.addingTimeInterval(10))
    check(wait.kind(host: nil, reading: true, now: at.addingTimeInterval(10 + NotchWebLookup.quickDelays.reduce(0, +)))
          == .youTube,
          "The player's next track keeps the kind its last one settled on while it is read, so YouTube's skips never flicker")
    check(wait.kind(host: nil, reading: true, now: at.addingTimeInterval(10 + NotchMediaKindWait.limit)) == .genericWeb
          && wait.kind(host: nil, reading: true, now: at.addingTimeInterval(10.1)) == .genericWeb,
          "Past the limit it is generic web media, and stays so until a website is found")
    wait.follow(player: "zen", title: "A page", now: at.addingTimeInterval(20))
    check(wait.kind(host: nil, reading: true, now: at.addingTimeInterval(20.1)) == .genericWeb,
          "After a generic page, the next track waits as generic")
    wait.follow(player: "safari", title: "Netflix", now: at.addingTimeInterval(30))
    check(wait.kind(host: nil, reading: true, now: at.addingTimeInterval(30.1)) == .pending
          && wait.kind(host: nil, reading: false, now: at.addingTimeInterval(30.2)) == .genericWeb,
          "Another player starts neutral, and reads ending without a website make it generic at once")
    check(wait.kind(host: "netflix.com", reading: false, now: at.addingTimeInterval(30.3)) == .netflix, "Netflix found is Netflix")
    wait.follow(player: "safari", title: "Does the $200 Codex plan suck now?", now: at.addingTimeInterval(35))
    check(wait.kind(host: nil, reading: true, now: at.addingTimeInterval(35.1)) == .pending,
          "A new title after Netflix waits neutral, never in Netflix's layout, since Netflix's tracks are all \"Netflix\"")
    wait.follow(player: nil, title: "Weightless", now: at.addingTimeInterval(40))
    check(wait.deadline == nil && wait.track == nil, "Apps never wait")
    // YouTube in other browsers, from their tab and window titles.
    let youTubeTitles: [(String, String, String?)] = [
        ("NBA Top 10 - YouTube", "NBA Top 10", "youtube.com"),
        ("(3) NBA Top 10 - YouTube", "NBA Top 10", "youtube.com"),
        ("NBA  Top\u{00A0}10 - YouTube — Mozilla Firefox", "NBA Top 10", "youtube.com"),
        ("nba top 10 - YouTube - Google Chrome - Personal", "NBA Top 10", "youtube.com"),
        ("Cafe\u{301} - YouTube", "Caf\u{E9}", "youtube.com"),
        ("Midnight City - YouTube Music", "Midnight City", "music.youtube.com"),
        ("YouTube", "NBA Top 10", nil),
        ("NBA Top 10 - Vimeo", "NBA Top 10", nil),
        ("Another video - YouTube", "NBA Top 10", nil),
        ("NBA Top 10 - YouTube Rewind", "NBA Top 10", nil),
        ("Introduction - YouTube", "Intro", nil),
        ("Intro (Live) - YouTube — Zen", "Intro", nil),
        ("Intro - YouTube - Introduction - YouTube", "Intro", nil),
        ("A - YouTube - YouTube", "A", nil),
        ("A - YouTube - YouTube — Zen", "A - YouTube", "youtube.com"),
        ("Anything - YouTube", " ", nil)
    ]
    check(youTubeTitles.allSatisfy { NotchBrowserTabs.youTubeHost(title: $0.0, track: $0.1) == $0.2 },
          "A tab or window titled exactly the track with YouTube's suffix names YouTube; a longer title, the home page, another site or video does not")
    let chromeTabs = NotchWebSites.parse("https://www.youtube.com/\tYouTube\nhttps://vimeo.com/1\tNBA Top 10 - Vimeo\n"
                                         + "https://m.youtube.com/watch?v=a\t(2) NBA Top 10 - YouTube\n"
                                         + "https://www.youtube.com/watch?v=b\tNBA Top 10 Plays - YouTube\n")
    check(NotchBrowserTabs.matches(tabs: chromeTabs, track: "NBA Top 10") == ["youtube.com"]
          && NotchBrowserTabs.matches(tabs: chromeTabs, track: "Another video").isEmpty
          && NotchBrowserTabs.matches(tabs: Array(chromeTabs.prefix(2)), track: "NBA Top 10").isEmpty,
          "Chrome's tabs name YouTube by a tab on YouTube whose title is the track's")
    let suffixed = NotchWebSites.parse("https://www.youtube.com/watch?v=c\tA - YouTube - YouTube\n")
    let plain = NotchWebSites.parse("https://www.youtube.com/watch?v=d\tA - YouTube\n")
    check(NotchBrowserTabs.matches(tabs: suffixed, track: "A - YouTube") == ["youtube.com"]
          && NotchBrowserTabs.matches(tabs: plain, track: "A - YouTube").isEmpty
          && NotchBrowserTabs.matches(tabs: suffixed, track: "A").isEmpty,
          "Chrome's tabs are parsed once like window titles: a video titled \"A - YouTube\" is not track \"A\"")
    let twice = NotchBrowserTabs.matches(titles: ["Clip - YouTube", "Clip - YouTube — Mozilla Firefox", "Other - YouTube"], track: "Clip")
    check((try? NotchBrowserTabs.host(of: ["youtube.com"])) == "youtube.com" && (try? NotchBrowserTabs.host(of: [])) == .some(nil)
          && twice.count == 2 && (try? NotchBrowserTabs.host(of: twice)) == nil,
          "One match names its host, none names nothing, and two tabs with the track's title are an ambiguous read")
    check(NotchWebSites.scriptTimeout(permission: OSStatus(errAEEventWouldRequireUserConsent), prompting: false) == nil
          && NotchWebSites.scriptTimeout(permission: OSStatus(errAEEventWouldRequireUserConsent), prompting: true) == NotchWebSites.promptTimeout
          && NotchWebSites.scriptTimeout(permission: noErr, prompting: false) == 5
          && NotchWebSites.scriptTimeout(permission: OSStatus(errAEEventNotPermitted), prompting: true) == nil,
          "A read no press asked for never runs a script that would show the Automation prompt")
    var allowance = NotchAXAllowance(now: at, seconds: 0.75, requests: 2)
    let first = allowance.spend(now: at.addingTimeInterval(0.25), cancelled: false)
    check(first.map { abs($0 - 0.5) < 0.001 } == true && allowance.spend(now: at.addingTimeInterval(0.5), cancelled: true) == nil
          && allowance.spend(now: at.addingTimeInterval(0.5), cancelled: false) != nil
          && allowance.spend(now: at.addingTimeInterval(0.5), cancelled: false) == nil,
          "Accessibility requests share one budget and wait only the time left; a cancelled lookup sends none")
    var late = NotchAXAllowance(now: at, seconds: 0.75)
    check(late.spend(now: at.addingTimeInterval(0.75), cancelled: false) == nil, "No request starts after the lookup's deadline")
    var tabs = NotchTabLookup()
    check(tabs.follow("zen|Clip") == "zen|Clip" && tabs.follow("zen|Clip") == nil, "One read per track at a time")
    tabs.finish("youtube.com", for: "zen|Clip")
    check(tabs.host == "youtube.com" && tabs.follow("zen|Next") == "zen|Next", "A result is kept; a new title is read")
    tabs.finish(nil, for: "zen|Next")
    check(tabs.host == nil && tabs.follow("zen|Clip") == nil && tabs.host == "youtube.com",
          "A track coming back is remembered, and not read again")
    _ = tabs.follow("zen|Third")
    _ = tabs.follow("zen|Fourth")
    tabs.finish("youtube.com", for: "zen|Third")
    check(tabs.host == nil, "A read for a track no longer playing is dropped")
    tabs.fail(for: "zen|Fourth")
    check(tabs.follow("zen|Fourth") == nil && tabs.follow("zen|Fourth", explicit: true) == "zen|Fourth",
          "A failed read is tried again only when asked")
    tabs.abandon()
    tabs.paused = true
    check(tabs.follow("zen|Fifth") == nil && tabs.follow(nil) == nil, "Nothing is read while locked, nor for Safari and apps")
    tabs.paused = false
    check(tabs.follow("zen|Fifth") == "zen|Fifth", "The track waiting is read after unlock")
    // Which pages are read, and when.
    check(NotchWebPageRequest(site: netflix, title: "Netflix", durationKnown: true) == request
          && request.address == "https://www.netflix.com/watch/" && request.prefix,
          "Netflix is always read, from its one player tab whatever the episode")
    check(NotchWebPageRequest(site: youTube, title: "NBA Top 10", durationKnown: true) == nil && video.expected == "NBA Top 10"
          && NotchWebPageRequest(site: nil, title: "Weightless", durationKnown: false) == nil,
          "Other sites only when MediaRemote lacks times, and apps never")
    var unmatched = youTube
    unmatched.matchesTrack = false
    check(NotchWebPageRequest(site: unmatched, title: "NBA Top 10", durationKnown: false) == nil,
          "Nor a tab only guessed as the first media site")
    check(NotchWebPagePoll.active(request, onScreen: true, locked: false) && !NotchWebPagePoll.active(request, onScreen: false, locked: false)
          && !NotchWebPagePoll.active(request, onScreen: true, locked: true) && !NotchWebPagePoll.active(nil, onScreen: true, locked: false),
          "Reads run only with the player on screen and the Mac unlocked")
    let named = NotchWebPage(title: "The Mentalist", subtitle: "E17 · Cheap Burgundy", content: episode)
    var timed = named
    timed.progress = read?.progress
    var poll = NotchWebPagePoll()
    check(poll.known == nil && poll.next(after: .read(timed), playing: true) == 2 && poll.known == nil,
          "A page with a position is read in full every 2 s")
    check(poll.next(after: .read(named), playing: true) == 10 && poll.known == episode
          && poll.next(after: .unchanged(content: episode), playing: true) == 10 && poll.known == episode,
          "A video named without a position is only checked every 10 s, its text not read again")
    check(poll.next(after: .read(named), playing: false) == nil && poll.next(after: .unavailable, playing: true) == nil,
          "Once while paused, never for an unreadable page")
    var idle = NotchWebPagePoll()
    let empties = (0..<3).map { _ in idle.next(after: .empty(content: episode), playing: true) }
    check(empties == [10, 10, 10] && idle.known == episode, "Text naming nothing is read three times, then only checked")
    check(idle.next(after: .empty(content: "https://www.netflix.com/watch/80014506"), playing: true) == 10 && idle.known == nil,
          "Another video in the tab is read in full again")
    let retries = (0..<4).map { _ in idle.next(after: .failed, playing: true) }
    check(retries == [5, 15, 45, nil], "Failures retry on the website lookup's budget, then stop")
    check(idle.next(after: .read(timed), playing: true) == 2 && idle.failures == 0, "A read restores the budget")
    check(NotchWebPagePoll(known: named).known == episode && NotchWebPagePoll(known: timed).known == nil,
          "Reads starting again check a video already named first")
    // What may be shown: the cache, its owner and its confirmation.
    let start = Date(timeIntervalSince1970: 50_000)
    var cache = NotchWebPageCache()
    check(cache.follow(owner: "Netflix--|netflix", locked: false) && !cache.follow(owner: "Netflix--|netflix", locked: false),
          "The owner is followed")
    cache.land(.read(named), now: start)
    check(cache.shown == named && cache.known == episode, "A read is shown")
    cache.begin(now: start.addingTimeInterval(5))
    check(cache.shown == named, "Reads starting again within 10 s, as after a quick close and reopen, keep showing it")
    cache.begin(now: start.addingTimeInterval(30))
    check(cache.shown == nil && cache.page == named, "After longer, as after the displays slept, the plain site shows until a check")
    cache.land(.unchanged(content: episode), now: start.addingTimeInterval(31))
    check(cache.shown == named, "A check finding the same video shows it again")
    cache.land(.empty(content: episode), now: start.addingTimeInterval(40))
    check(cache.shown == named, "The same video naming nothing, its controls hidden, keeps it")
    cache.land(.empty(content: "https://www.netflix.com/watch/80014506"), now: start.addingTimeInterval(50))
    check(cache.shown == nil && cache.page == nil && cache.known == "https://www.netflix.com/watch/80014506",
          "Another video drops it, and a peek's read skips the text that named nothing")
    cache.land(.read(named), now: start)
    cache.land(.unchanged(content: "https://www.netflix.com/watch/80014506"), now: start)
    check(cache.shown == named, "A check for another video confirms nothing else")
    cache.land(.unavailable, now: start)
    check(cache.page == nil && cache.known == nil, "Two player tabs or none drop it")
    cache.land(.read(named), now: start)
    cache.begin(now: start.addingTimeInterval(3_601))
    check(cache.page == nil, "An hour after its last confirmation it is dropped rather than checked")
    cache.land(.read(named), now: start)
    check(!cache.follow(owner: "Netflix--|netflix", locked: true) && cache.page == nil && cache.owner == "Netflix--|netflix",
          "Locking drops it")
    cache.land(.read(named), now: start)
    check(cache.follow(owner: "Weightless-Marconi Union-|x", locked: false) && cache.page == nil,
          "Another track or tab drops it")
    // Netflix's controls hide: the script finds the video but no heading, and its media session names only the site.
    let headless = #"{"sessionTitle":"Netflix","sessionArtist":"","documentTitle":"Netflix","time":320,"duration":2700,"paused":false}"#
    let hidden = NotchWebPages.outcome(of: "js\n\(episode)?trackId=1\n" + headless, for: request, now: start.addingTimeInterval(2))
    guard case .read(let positioned) = hidden else { return check(false, "A Netflix page without its heading still gives the position") }
    check(positioned.title == nil, "Netflix's media session never names the video")
    var headed = timed
    headed.content = episode
    var shows = NotchWebPageCache()
    shows.land(.read(headed), now: start)
    shows.land(hidden, now: start.addingTimeInterval(2))
    check(shows.shown?.title == "The Mentalist" && shows.shown?.subtitle == "E17 · Cheap Burgundy"
          && shows.shown?.progress == positioned.progress, "A read without the heading keeps the name of the same video and moves its position")
    var next = positioned
    next.content = "https://www.netflix.com/watch/80014506"
    shows.land(.read(next), now: start.addingTimeInterval(4))
    check(shows.shown == next, "Another video's read gets no name from the one before")
    // Failing reads: a confirmation lapses `trust` after the first failure, unless a read renews it.
    var failing = NotchWebPageCache()
    failing.land(.read(named), now: start)
    failing.land(.failed, now: start.addingTimeInterval(12))
    failing.land(.failed, now: start.addingTimeInterval(17))
    check(failing.shown == named && failing.lapse == start.addingTimeInterval(22), "A failure or two keeps it, its lapse set by the first")
    failing.expire(now: start.addingTimeInterval(22))
    check(failing.shown == nil && failing.page == named, "Once reads failed for 10 s, the plain site shows even with retries stopped")
    failing.land(.unchanged(content: episode), now: start.addingTimeInterval(60))
    failing.land(.failed, now: start.addingTimeInterval(70))
    failing.land(.read(named), now: start.addingTimeInterval(75))
    failing.expire(now: start.addingTimeInterval(200))
    check(failing.shown == named && failing.lapse == nil, "A read after a failure renews it, so it never flaps")
}

/// Spotify's and Music's AppleScript reads (`NotchScriptedPlayer`) and Netflix's confirmation for following Safari.
private func checkScriptedPlayers(_ check: (@autoclosure () -> Bool, String) -> Void) {
    // Spotify's reply on 7 October, paused.
    let spotify = NotchScriptedPlayer.parse(
        "paused\nWhisper My Name\nDrake\nICEMAN\n222580\n93,856002807617\nhttps://i.scdn.co/image/ab67616d0000b273\n",
        app: "com.spotify.client")
    check(spotify == NotchScriptedPlayer(playing: false, title: "Whisper My Name", artist: "Drake", album: "ICEMAN",
                                         duration: 222.58, position: 93.856002807617,
                                         artworkURL: URL(string: "https://i.scdn.co/image/ab67616d0000b273")),
          "Spotify's read gives its duration in milliseconds and its position with the locale's decimal comma")
    check(NotchScriptedPlayer.parse("playing\nSong\n\nAlbum\n245.5\n12\n", app: "com.apple.Music")
          == NotchScriptedPlayer(playing: true, title: "Song", album: "Album", duration: 245.5, position: 12),
          "Music's read gives its duration in seconds, and an empty artist is none")
    check(NotchScriptedPlayer.parse("stopped\n", app: "com.apple.Music") == NotchScriptedPlayer()
          && NotchScriptedPlayer.parse("execution error", app: "com.apple.Music") == nil
          && NotchScriptedPlayer.parse("playing\nSong", app: "com.apple.Music") == nil,
          "A stopped player is not playing; output that is not the read's is nothing")
    check(NotchScriptedPlayer.script(for: "com.spotify.client")?.contains("artwork url") == true
          && NotchScriptedPlayer.script(for: "com.apple.Music")?.contains("artwork url") == false
          && NotchScriptedPlayer.script(for: "app.zen-browser.zen") == nil,
          "Only Spotify's read asks for a cover address, and other players have no read")

    let watch = "https://www.netflix.com/watch/81", now = Date(timeIntervalSince1970: 1_000)
    func page(playing: Bool?) -> NotchWebPage {
        NotchWebPage(progress: playing.map { .init(elapsed: 10, duration: 100, playing: $0, at: now) }, content: watch)
    }
    func netflix(_ outcome: NotchWebPagePoll.Outcome, watched: String? = watch, sounding: Bool = true,
                 capturing: Bool = false) -> Bool? {
        NotchWebPages.netflixPlays(outcome, watched: watched, sounding: sounding, capturing: capturing)
    }
    check(netflix(.read(page(playing: true)), watched: nil, sounding: false, capturing: true) == true
          && netflix(.read(page(playing: false)), capturing: true) == false,
          "With JavaScript Netflix's page says by its video whether it plays, whatever Safari's audio or video read last")
    check(netflix(.read(page(playing: nil))) == true && netflix(.unchanged(content: watch)) == true
          && netflix(.unchanged(content: watch), sounding: false) == false,
          "Without JavaScript the video read last plays while Safari makes sound and captures nothing")
    check(netflix(.read(page(playing: nil)), capturing: true) == nil && netflix(.empty(content: watch), capturing: true) == nil,
          "Without JavaScript, during a Safari call, whether it plays cannot be told")
    check(netflix(.read(page(playing: nil)), watched: "https://www.netflix.com/watch/82") == false
          && netflix(.empty(content: watch), watched: nil) == false,
          "Read by its text, the tab must still be at the video read last")
    check(netflix(.unavailable) == false && netflix(.failed) == nil,
          "No single Netflix player tab is not playing; a failed read cannot tell")
    check(NotchWebPages.videoPlays(.read(page(playing: true))) == true
          && NotchWebPages.videoPlays(.read(page(playing: false))) == false,
          "Another site's video says whether it plays")
    check(NotchWebPages.videoPlays(.read(page(playing: nil))) == nil && NotchWebPages.videoPlays(.unavailable) == nil
          && NotchWebPages.videoPlays(.empty(content: watch)) == nil && NotchWebPages.videoPlays(.failed) == nil,
          "Without the video's state, as when Safari refuses JavaScript, nothing is told")
}

/// When the players heard beside the system's are read to confirm they play their last report (`NotchConfirmations`).
private func checkConfirmations(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let start = ContinuousClock.now
    func at(_ seconds: Double) -> ContinuousClock.Instant { start + .seconds(seconds) }
    let safari = "com.apple.Safari", spotify = "com.spotify.client"
    var reads = NotchConfirmations()
    check(reads.want([safari]).isEmpty && reads.start(at: at(0), paused: true) == ([], nil),
          "Nothing is read while the Mac is locked")
    check(reads.start(at: at(1), paused: false) == ([safari], nil) && reads.start(at: at(1), paused: false) == ([], nil),
          "A newly wanted player is read once, at once")
    reads.settle(safari, plays: true, at: at(2))
    check(reads.confirmed == [safari] && reads.denied.isEmpty && reads.start(at: at(3), paused: false) == ([], nil),
          "A read that finds it playing confirms it, and nothing more is read without a reason")
    reads.stir([safari, spotify])
    check(reads.start(at: at(3), paused: false) == ([], at(12)) && reads.start(at: at(12), paused: false) == ([safari], nil),
          "Its audio starting or stopping reads it again, at most once per interval")
    reads.settle(safari, plays: nil, at: at(13))
    check(reads.confirmed == [safari] && reads.start(at: at(23), paused: false) == ([safari], nil),
          "A read that cannot tell keeps the verdict and is tried again an interval later")
    reads.settle(safari, plays: nil, at: at(24))
    check(reads.start(at: at(34), paused: false) == ([safari], nil), "And once more")
    reads.settle(safari, plays: nil, at: at(35))
    check(reads.start(at: at(50), paused: false) == ([], nil),
          "Three in a row that cannot tell, and it waits for its audio to change")
    reads.stir([safari])
    _ = reads.start(at: at(50), paused: false)
    reads.settle(safari, plays: false, at: at(51))
    check(reads.denied == [safari] && reads.confirmed.isEmpty, "A read that finds it paused takes the confirmation back")
    reads.stir([safari])
    _ = reads.start(at: at(61), paused: false)
    reads.interrupt()
    check(reads.start(at: at(62), paused: true) == ([], nil) && reads.start(at: at(70), paused: false) == ([safari], nil)
          && reads.denied == [safari],
          "A read stopped by the lock runs again after unlock, the last verdict standing meanwhile")
    check(reads.want([spotify]) == [safari] && reads.denied.isEmpty && reads.start(at: at(71), paused: false) == ([spotify], nil),
          "A player no longer wanted is forgotten, so it is read afresh when heard again")

    // Netflix in Safari followed beside a call: pausing or resuming it changes no audio, so it is read on a timer.
    var followed = NotchConfirmations()
    _ = followed.want([safari])
    _ = followed.start(at: at(0), paused: false, following: safari)
    followed.settle(safari, plays: true, at: at(1))
    check(followed.start(at: at(2), paused: false) == ([], nil)
          && followed.start(at: at(2), paused: false, following: safari) == ([], at(13)),
          "Only the followed player is read again, `refresh` after its last read")
    check(followed.start(at: at(13), paused: false, following: safari) == ([safari], nil), "And read when that comes")
    followed.settle(safari, plays: false, at: at(14))
    check(followed.denied == [safari] && followed.start(at: at(26), paused: false, following: safari) == ([safari], nil),
          "A paused verdict is read again too, so a resume during the call shows")
    followed.settle(safari, plays: nil, at: at(27))
    _ = followed.start(at: at(37), paused: false, following: safari)
    followed.settle(safari, plays: nil, at: at(38))
    _ = followed.start(at: at(48), paused: false, following: safari)
    followed.settle(safari, plays: nil, at: at(49))
    check(followed.denied == [safari] && followed.start(at: at(200), paused: false, following: safari) == ([], nil),
          "Reads that cannot tell stop after `attempts`, followed or not")
    check(followed.start(at: at(200), paused: true, following: safari) == ([], nil), "Nor is it read while locked")

    // A verdict settled before the lock is read again after unlock, within the rate limit.
    var locked = NotchConfirmations()
    _ = locked.want([safari])
    _ = locked.start(at: at(0), paused: false)
    locked.settle(safari, plays: true, at: at(1))
    locked.interrupt()
    check(locked.start(at: at(5), paused: true) == ([], nil) && locked.confirmed == [safari]
          && locked.start(at: at(5), paused: false) == ([], at(11)) && locked.start(at: at(11), paused: false) == ([safari], nil),
          "A confirmation from before the lock is read again after unlock, at most once per interval")

    // Netflix confirmed while Spotify was followed, then paused during a Safari call: no audio change reads it again.
    var aging = NotchConfirmations()
    _ = aging.want([safari, spotify])
    _ = aging.start(at: at(0), paused: false)
    aging.settle(safari, plays: true, at: at(1))
    aging.settle(spotify, plays: true, at: at(1))
    check(aging.fresh(at: at(13)) == [safari, spotify] && aging.fresh(at: at(13.5)).isEmpty
          && aging.confirmed == [safari, spotify],
          "A confirmation counts as fresh for `lasts`, then only as stale")
    aging.renew([safari], at: at(14))
    check(aging.start(at: at(14), paused: false) == ([safari], nil), "A stale one asked for is read again at once")
    aging.settle(safari, plays: nil, at: at(15))
    check(aging.fresh(at: at(15)).isEmpty && aging.confirmed.contains(safari)
          && aging.start(at: at(16), paused: false) == ([], at(25)),
          "A read that cannot tell leaves it stale, tried again an interval later")
    _ = aging.start(at: at(25), paused: false)
    aging.settle(safari, plays: true, at: at(26))
    aging.renew([safari], at: at(30))
    check(aging.fresh(at: at(30)) == [safari] && aging.start(at: at(30), paused: false) == ([], nil),
          "A fresh read makes it count again, and a fresh one asked for is not read")

    // Codex round 5: the same with Safari refusing JavaScript. Netflix's tab still shows the video it paused on, and the
    // call keeps Safari sounding, so its text alone must not renew the confirmation once Spotify stops.
    let zen = "app.zen-browser.zen", watch = "https://www.netflix.com/watch/81"
    var call = NotchConfirmations(), pick = NotchSourcePick()
    func follow(heard: Set<String>, at seconds: Double) -> NotchSourcePick.Followed {
        let fresh = call.fresh(at: at(seconds))
        return pick.update(.init(system: zen, systemPlaying: false, heard: heard, voiced: [safari, zen, spotify],
                                 known: [safari, zen, spotify], confirmed: fresh,
                                 stale: call.confirmed.subtracting(fresh), denied: call.denied), at: at(seconds))
    }
    _ = call.want([safari, spotify])
    _ = call.start(at: at(0), paused: false)
    call.settle(safari, plays: true, at: at(1))
    call.settle(spotify, plays: true, at: at(14))
    _ = follow(heard: [spotify, safari], at: 15)
    check(follow(heard: [spotify, safari], at: 20) == .other(spotify, playing: true),
          "Spotify, read after Netflix, is followed during the call")
    _ = follow(heard: [safari], at: 100)
    call.renew(pick.renew, at: at(100))
    let renewal = NotchWebPages.netflixPlays(.unchanged(content: watch), watched: watch, sounding: true, capturing: true)
    check(call.start(at: at(100), paused: false).apps == [safari] && renewal == nil,
          "When Spotify stops, the stale Netflix is read again, and its unchanged tab during the call cannot tell")
    call.settle(safari, plays: renewal, at: at(101))
    check(call.fresh(at: at(101)).isEmpty && follow(heard: [safari], at: 102) != .other(safari, playing: true),
          "So its age is not renewed and the paused Netflix never shows as playing")
}

/// The player the notch follows beside MediaRemote's (`NotchSourcePick`), on the 7 October case: Netflix playing in
/// Safari while a YouTube hover preview in Zen takes MediaRemote and keeps it, paused.
private func checkSourcePick(_ check: (@autoclosure () -> Bool, String) -> Void) {
    typealias Report = NotchSourcePick.Report
    let start = ContinuousClock.now
    func at(_ seconds: Double) -> ContinuousClock.Instant { start + .seconds(seconds) }
    let safari = "com.apple.Safari", zen = "app.zen-browser.zen", spotify = "com.spotify.client"
    let voiced: Set = [safari, zen, spotify]
    func report(_ system: String?, playing: Bool, heard: Set<String>?, known: Set<String> = [safari, zen, spotify],
                confirmed: Set<String>? = nil, stale: Set<String> = [], denied: Set<String> = []) -> Report {
        Report(system: system, systemPlaying: playing, heard: heard, voiced: voiced, known: known,
               confirmed: confirmed ?? known.subtracting(denied).subtracting(stale), stale: stale, denied: denied)
    }

    var pick = NotchSourcePick()
    check(pick.update(report(safari, playing: true, heard: [safari]), at: at(0)) == .system,
          "The system's player is followed while it plays")
    check(pick.update(report(zen, playing: true, heard: [safari]), at: at(10)) == .other(safari, playing: true)
          && pick.recheck == at(10 + 6),
          "A browser preview playing unheard does not replace the player heard before it")
    check(pick.update(report(zen, playing: false, heard: [safari]), at: at(12)) == .other(safari, playing: true)
          && pick.recheck == nil,
          "Once the preview pauses, the notch stays on the player still heard, with nothing left to wait for")
    check(pick.update(report(zen, playing: true, heard: [safari, zen]), at: at(20)) == .other(safari, playing: true)
          && pick.update(report(zen, playing: false, heard: [safari]), at: at(25)) == .other(safari, playing: true),
          "A preview heard beside the playing player does not take the notch within the hold")
    check(pick.update(report(zen, playing: true, heard: [safari, zen]), at: at(30)) == .other(safari, playing: true)
          && pick.update(report(zen, playing: true, heard: [safari, zen]), at: at(36)) == .system,
          "A browser heard beside another player takes the notch once it played for the hold")
    check(pick.update(report(zen, playing: false, heard: [safari]), at: at(40)) == .system
          && pick.recheck == at(41.5)
          && pick.update(report(zen, playing: false, heard: [safari]), at: at(41.5)) == .other(safari, playing: true),
          "When the system's player pauses, another player heard is followed only after it was quiet for the steady wait")
    check(pick.update(report(zen, playing: true, heard: [zen]), at: at(42)) == .system,
          "It switches back as soon as the system's player plays and counts, here heard alone")

    var flaps = NotchSourcePick()
    _ = flaps.update(report(spotify, playing: true, heard: [spotify, safari]), at: at(0))
    check(flaps.update(report(spotify, playing: false, heard: [spotify, safari]), at: at(10)) == .system
          && flaps.update(report(spotify, playing: true, heard: [spotify, safari]), at: at(10.2)) == .system
          && flaps.update(report(spotify, playing: false, heard: [safari]), at: at(20)) == .system,
          "An app pausing between tracks never hands the notch to another player for a moment")
    check(flaps.update(report(spotify, playing: false, heard: []), at: at(21)) == .system,
          "A player heard only briefly is not followed")
    _ = flaps.update(report(spotify, playing: false, heard: [safari]), at: at(30))
    check(flaps.update(report(spotify, playing: false, heard: [safari]), at: at(31.5)) == .other(safari, playing: true)
          && flaps.update(report(spotify, playing: false, heard: []), at: at(32)) == .other(safari, playing: true)
          && flaps.recheck == at(33.5)
          && flaps.update(report(spotify, playing: false, heard: [safari]), at: at(33)) == .other(safari, playing: true)
          && flaps.update(report(spotify, playing: false, heard: []), at: at(34)) == .other(safari, playing: true),
          "A followed player silent for less than the steady wait, as when buffering, still shows as playing")
    check(flaps.update(report(spotify, playing: false, heard: []), at: at(35.5)) == .other(safari, playing: false)
          && flaps.update(report(spotify, playing: false, heard: []), at: at(500)) == .other(safari, playing: false),
          "Silent for longer, it shows as paused, and stays shown while the system's player is paused")
    check(flaps.update(report(spotify, playing: true, heard: [spotify]), at: at(501)) == .system,
          "An app playing again takes the notch back at once")

    var pressed = NotchSourcePick()
    _ = pressed.update(report(zen, playing: false, heard: [spotify]), at: at(0))
    _ = pressed.update(report(zen, playing: false, heard: [spotify]), at: at(2))
    pressed.paused()
    check(pressed.update(report(zen, playing: false, heard: []), at: at(3)) == .other(spotify, playing: false),
          "A pause pressed in the notch shows as soon as the followed player falls silent")

    var hover = NotchSourcePick()
    _ = hover.update(report(spotify, playing: false, heard: []), at: at(0))
    check(hover.update(report(zen, playing: true, heard: []), at: at(5)) == .other(spotify, playing: false)
          && hover.update(report(zen, playing: false, heard: []), at: at(8)) == .other(spotify, playing: false),
          "A hover preview over a paused player leaves the paused player shown")
    check(hover.update(report(zen, playing: true, heard: []), at: at(10)) == .other(spotify, playing: false)
          && hover.update(report(zen, playing: true, heard: []), at: at(16)) == .system,
          "A browser playing unheard, such as a muted video, takes the notch after the hold")
    var youtube = NotchSourcePick()
    _ = youtube.update(report(spotify, playing: false, heard: []), at: at(0))
    check(youtube.update(report(zen, playing: true, heard: []), at: at(5)) == .other(spotify, playing: false)
          && youtube.update(report(zen, playing: true, heard: [zen]), at: at(5.05)) == .system,
          "A browser video with sound and nothing else playing takes the notch as soon as it is heard")
    var unvoiced = NotchSourcePick()
    check(unvoiced.update(Report(system: zen, systemPlaying: true, heard: [], voiced: [], known: []), at: at(0)) == .system,
          "A browser Core Audio has no process for is taken at MediaRemote's word")
    var quit = NotchSourcePick()
    _ = quit.update(report(zen, playing: false, heard: [safari]), at: at(0))
    _ = quit.update(report(zen, playing: false, heard: [safari]), at: at(2))
    check(quit.update(report(zen, playing: false, heard: [], known: [zen]), at: at(3)) == .system,
          "A followed player that quit hands the notch back")
    var call = NotchSourcePick()
    _ = call.update(report(zen, playing: false, heard: [safari], confirmed: []), at: at(0))
    check(call.update(report(zen, playing: false, heard: [safari], confirmed: []), at: at(5)) == .system
          && call.wanted == [safari] && call.recheck == nil,
          "A player heard beside the paused system's is not followed until its last report is confirmed to play")
    check(call.update(report(zen, playing: false, heard: [safari], confirmed: [safari]), at: at(5.3))
          == .other(safari, playing: true),
          "Once confirmed, it is followed")
    _ = call.update(report(zen, playing: false, heard: [], confirmed: []), at: at(10))
    check(call.update(report(zen, playing: false, heard: [], confirmed: []), at: at(11.5)) == .other(safari, playing: false)
          && call.wanted.isEmpty,
          "Silent past the steady wait, it shows as paused and is no longer wanted")
    check(call.update(report(zen, playing: false, heard: [safari], confirmed: []), at: at(20)) == .other(safari, playing: false)
          && call.wanted == [safari],
          "Heard again, as on a call after Netflix paused, it stays paused until confirmed again")
    var carried = NotchSourcePick()
    _ = carried.update(report(safari, playing: true, heard: [safari], confirmed: []), at: at(0))
    check(carried.update(report(zen, playing: true, heard: [safari], confirmed: []), at: at(10)) == .other(safari, playing: true),
          "The system's player shown playing stays playing without a read when a preview takes MediaRemote")
    check(carried.update(report(zen, playing: false, heard: [safari], confirmed: []), at: at(12)) == .other(safari, playing: true)
          && carried.update(report(zen, playing: false, heard: [safari], denied: [safari]), at: at(13))
          == .other(safari, playing: false),
          "A read that cannot tell keeps it playing; one finding it paused, as on a Safari call, shows it paused at once")
    check(carried.update(report(zen, playing: false, heard: [safari], denied: [safari]), at: at(30))
          == .other(safari, playing: false)
          && carried.update(report(zen, playing: false, heard: [safari], confirmed: [safari]), at: at(31))
          == .other(safari, playing: true),
          "It stays paused while heard until a later read finds it playing again")
    check(carried.watched == [safari, zen, spotify]
          && carried.update(report(zen, playing: true, heard: [zen]), at: at(10.1)) == .system && carried.watched.isEmpty,
          "Core Audio is polled for known players only while the system's player does not count")
    // Spotify followed beside a paused preview while a Safari call keeps Safari heard; Netflix paused long ago.
    var aged = NotchSourcePick()
    _ = aged.update(report(zen, playing: false, heard: [spotify, safari], stale: [safari]), at: at(0))
    check(aged.update(report(zen, playing: false, heard: [spotify, safari], stale: [safari]), at: at(2))
          == .other(spotify, playing: true) && aged.renew.isEmpty,
          "A stale confirmation is not read again while the followed player plays")
    check(aged.update(report(zen, playing: false, heard: [safari], stale: [safari]), at: at(100))
          == .other(spotify, playing: true) && aged.renew == [safari]
          && aged.update(report(zen, playing: false, heard: [safari], stale: [safari]), at: at(101.5))
          == .other(spotify, playing: false),
          "When it stops, a player confirmed too long ago is not followed as playing but read again")
    check(aged.update(report(zen, playing: false, heard: [safari], denied: [safari]), at: at(102))
          == .other(spotify, playing: false) && aged.renew.isEmpty,
          "A fresh read finding it paused leaves the paused player shown")
    var renewed = aged
    check(renewed.update(report(zen, playing: false, heard: [safari], confirmed: [safari]), at: at(102))
          == .other(safari, playing: true) && renewed.renew.isEmpty,
          "A fresh read finding it playing follows it")
    var blind = NotchSourcePick()
    check(blind.update(report(zen, playing: false, heard: nil), at: at(0)) == .system
          && blind.update(report(zen, playing: true, heard: nil), at: at(1)) == .system,
          "Without Core Audio the system's player is always followed")
}

extension NotchTripPlan {
    /// An empty plan that only wakes, for comparing.
    func with(wake: Date?) -> NotchTripPlan { var plan = self; plan.wake = wake; return plan }
}

/// Carries a value out of a detached task to a check waiting on a semaphore.
private final class CheckBox<T>: @unchecked Sendable {
    var value: T?
}
