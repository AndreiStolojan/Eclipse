import AppKit
import Quartz
import CoreAudio
import MediaRemoteAdapter
import SwiftUI

/// Standalone notch app entry point, including fixture rendering and read-only diagnostics.
@main
struct NotchLabApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--render") {
            renderStudies()
            return
        }
        if CommandLine.arguments.contains("--probe") {
            probe()
            return
        }
        if CommandLine.arguments.contains("--hit-probe") {
            exit(hitProbe() ? 0 : 1)
        }
        let delegate = NotchLabDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    @MainActor
    private static func renderStudies() {
        let experience = NotchExperience()
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        experience.geometry = screen.map { NotchGeometry(screen: $0) }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, expanded) in [("native-idle", false), ("native-expanded-empty", true)] {
            experience.state.expanded = expanded
            render(experience, name: name, in: directory)
        }
        let fixtures: [(name: String, title: String, playing: Bool, app: String, bundle: String,
                        shuffle: TrackInfo.ShuffleMode?, repeat: TrackInfo.RepeatMode?)] = [
            ("native-expanded-playing", "Weightless", true, "Preview fixture", "preview.fixture", nil, nil),
            ("native-expanded-paused", "Weightless", false, "Preview fixture", "preview.fixture", nil, nil),
            ("native-expanded-long-title", "A long video title that must truncate before it reaches the music controls", true, "Safari Graphics and Media", "com.apple.Safari", nil, nil),
            ("native-expanded-safari", "A video in Safari", true, "Safari Graphics and Media", "com.apple.Safari", nil, nil),
            ("native-expanded-spotify", "Weightless", true, "Spotify", "com.spotify.client", nil, nil),
            ("native-expanded-shuffle-repeat-one", "Weightless", true, "Music", "com.apple.Music", .songs, .one),
            ("native-expanded-repeat-all", "Weightless", true, "Music", "com.apple.Music", .off, .all)
        ]
        for fixture in fixtures {
            let (name, title, playing) = (fixture.name, fixture.title, fixture.playing)
            let media = NotchMedia(previewTrack: TrackInfo.Payload(title: title, artist: "Marconi Union",
                isPlaying: playing, durationMicros: 240_000_000, elapsedTimeMicros: 90_000_000,
                applicationName: fixture.app, bundleIdentifier: fixture.bundle, timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000,
                shuffleMode: fixture.shuffle, repeatMode: fixture.repeat, playbackRate: playing ? 1 : 0))
            let preview = NotchExperience(media: media)
            preview.geometry = experience.geometry
            preview.state.expanded = true
            render(preview, name: name, in: directory)
        }
        renderPlayerButtons(geometry: experience.geometry, in: directory)
        renderWebVideo(geometry: experience.geometry, in: directory)
        // The closed notch shows the artwork only while something plays; `native-idle` above shows it empty.
        let playing = NotchExperience(media: NotchMedia(previewTrack: TrackInfo.Payload(title: "Weightless", artist: "Marconi Union",
            isPlaying: true, applicationName: "Spotify", bundleIdentifier: "com.spotify.client", playbackRate: 1)))
        playing.geometry = experience.geometry
        render(playing, name: "native-compact-playing", in: directory)
        renderWaves(geometry: experience.geometry, in: directory)
        renderTrackPeeks(geometry: experience.geometry, in: directory)
        renderShelf(geometry: experience.geometry, in: directory)
        renderIndicators(geometry: experience.geometry, in: directory)
        renderDictation(geometry: experience.geometry, in: directory)
        renderCalendar(geometry: experience.geometry, in: directory)
        renderAgents(geometry: experience.geometry, in: directory)
        renderNotices(geometry: experience.geometry, in: directory)
        renderLockScreen(geometry: experience.geometry ?? .fallback, in: directory)
        renderTimer(geometry: experience.geometry, in: directory)
        renderHero(in: directory)
        print("Native views rendered to \(directory.path)")
    }

    /// Script notices from fixed data, including duplicate IDs, progress, the list and an empty history.
    @MainActor
    private static func renderNotices(geometry: NotchGeometry?, in directory: URL) {
        let suite = "ro.andrei.NotchLab.RenderNotices"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = NotchSettings()
        settings.scriptNotices = true
        settings.save(to: defaults)
        let date = Date(timeIntervalSince1970: 1_791_572_460)
        var notices = NotchNotices()
        let failure = NotchNotice(title: "Pi backup failed", detail: "Repository unavailable",
                                  symbol: "exclamationmark.triangle.fill", tint: .red, id: "pi.backup.daily", progress: nil)
        notices.receive(NotchNotice(title: "Build finished", detail: "42 s", symbol: "hammer.fill",
                                    tint: .green, id: "build", progress: nil), date: date - 300, alert: false)
        notices.receive(NotchNotice(title: "Pi service recovered", detail: "Health check passed",
                                    symbol: "checkmark.circle.fill", tint: .green, id: "pi.service.app", progress: nil),
                        date: date - 120, alert: false)
        notices.receive(failure, date: date)
        notices.receive(failure, date: date)
        let preview = NotchExperience(notices: notices, defaults: defaults)
        preview.geometry = geometry
        render(preview, name: "native-notice-alert", in: directory)
        renderScene(preview, name: "notice-alert-scene", in: directory)
        preview.state.expanded = true
        render(preview, name: "native-notifications", in: directory)
        renderScene(preview, name: "notifications-scene", in: directory)
        preview.clearNotices()
        render(preview, name: "native-notifications-empty", in: directory)
        preview.state.expanded = false
        var progress = NotchNotices()
        progress.receive(NotchNotice(title: "Upload", detail: "42%", symbol: "arrow.up",
                                    tint: .white, id: "upload", progress: 0.42), date: date)
        let upload = NotchExperience(notices: progress, defaults: defaults)
        upload.geometry = geometry
        render(upload, name: "native-notice-progress", in: directory)
        renderWindow(NotchAppView(experience: upload, page: .scripts), name: "native-settings-scripts", in: directory)
    }

    /// Web video in the open player and the closed wings: Netflix as MediaRemote reports it (only "Netflix", its
    /// logo and no times), then with its page read from the tab's text (show and episode) and with JavaScript allowed
    /// (the position too), and YouTube, whose own metadata is kept. Drawn stand-ins replace the sites' logos.
    @MainActor
    private static func renderWebVideo(geometry: NotchGeometry?, in directory: URL) {
        let red = NSColor(srgbRed: 0.9, green: 0.04, blue: 0.08, alpha: 1)
        let logo = image(300, background: .black, draw: letter("N", color: red))
        let favicon = image(64, background: nil, draw: letter("N", color: red))
        let thumbnail = image(300, background: nil) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.1, green: 0.3, blue: 0.7, alpha: 1),
                       ending: NSColor(srgbRed: 0.9, green: 0.5, blue: 0.1, alpha: 1))?.draw(in: rect, angle: -30)
        }
        let youTubeIcon = image(64, background: nil) { rect in
            red.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 14), xRadius: 12, yRadius: 12).fill()
            letter("▶", color: .white)(rect.insetBy(dx: 18, dy: 18))
        }
        let netflix = NotchWebSite(name: "Netflix", host: "netflix.com", url: URL(string: "https://www.netflix.com/watch/80014505")!,
                                   icon: favicon, matchesTrack: true)
        let youTube = NotchWebSite(name: "YouTube", host: "youtube.com", url: URL(string: "https://www.youtube.com/watch?v=Q4u5NKi5mOk")!,
                                   icon: youTubeIcon, matchesTrack: true)
        let episode = NotchWebPage(title: "The Mentalist", subtitle: "E17 · Cheap Burgundy")
        var timed = episode
        timed.progress = NotchWebPage.Progress(elapsed: 302, duration: 2_700, playing: true, at: .now)
        let fixtures: [(name: String, title: String, artist: String, duration: Double?, art: NSImage, site: NotchWebSite,
                        page: NotchWebPage?, expanded: Bool)] = [
            ("native-web-netflix-bare", "Netflix", "", nil, logo, netflix, nil, true),
            ("native-web-netflix-text", "Netflix", "", nil, logo, netflix, episode, true),
            ("native-web-netflix-page", "Netflix", "", nil, logo, netflix, timed, true),
            ("native-web-netflix-wings", "Netflix", "", nil, logo, netflix, episode, false),
            ("native-web-youtube", "NBA's Top 10 Plays of the Night | October 5, 2026", "NBA", 129, thumbnail, youTube, nil, true)
        ]
        for fixture in fixtures {
            let media = NotchMedia(previewTrack: TrackInfo.Payload(title: fixture.title, artist: fixture.artist, isPlaying: true,
                durationMicros: fixture.duration.map { $0 * 1_000_000 }, elapsedTimeMicros: fixture.duration == nil ? nil : 5_000_000,
                applicationName: "Safari Graphics and Media", bundleIdentifier: "com.apple.Safari", artworkDataBase64: base64(fixture.art),
                artworkMimeType: "image/png", timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000, playbackRate: 1, artwork: fixture.art),
                previewSite: fixture.site, previewPage: fixture.page)
            let preview = NotchExperience(media: media)
            preview.geometry = geometry
            preview.state.expanded = fixture.expanded
            render(preview, name: fixture.name, in: directory)
        }
        renderGenericWeb(geometry: geometry, in: directory)
    }

    /// A square stand-in image for the web renders, drawn on `background` when given.
    private static func image(_ size: CGFloat, background: NSColor?, draw: @escaping (CGRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            background?.setFill()
            if background != nil { rect.fill() }
            draw(rect)
            return true
        }
    }

    /// Draws `text` large and centred, as a stand-in logo.
    private static func letter(_ text: String, color: NSColor) -> (CGRect) -> Void {
        { rect in
            let font = NSFont.systemFont(ofSize: rect.height * 0.7, weight: .black)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let size = string.size()
            string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    /// The image as base64 PNG, as MediaRemote reports artwork.
    private static func base64(_ image: NSImage) -> String? {
        image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }?
            .base64EncodedString()
    }

    /// Generic web media: a page in Safari naming only its title, on its site's tile, without and with times, the same
    /// in Chrome, whose website is not known, so on the glyph, then the closed wings, the mini peek and the lock
    /// screen widget. SoundCloud reporting artwork and an artist is generic too. Last, YouTube recognised in Zen, which
    /// keeps the full player, and a Safari track whose website is still being read.
    @MainActor
    private static func renderGenericWeb(geometry: NotchGeometry?, in directory: URL) {
        let favicon = image(64, background: nil) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 6, yRadius: 6).fill()
            letter("B", color: .black)(rect.insetBy(dx: 10, dy: 10))
        }
        let cover = image(300, background: nil) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.95, green: 0.35, blue: 0.1, alpha: 1),
                       ending: NSColor(srgbRed: 0.35, green: 0.1, blue: 0.5, alpha: 1))?.draw(in: rect, angle: -60)
        }
        let bbc = NotchWebSite(name: "bbc.co.uk", host: "bbc.co.uk", url: URL(string: "https://www.bbc.co.uk/news/videos/1")!,
                               icon: favicon, matchesTrack: true)
        let soundCloud = NotchWebSite(name: "SoundCloud", host: "soundcloud.com", url: URL(string: "https://soundcloud.com/m83/midnight-city")!,
                                      matchesTrack: true)
        let title = "Inside the Large Hadron Collider"
        func media(_ title: String, artist: String?, duration: Double?, art: NSImage? = nil, app: String = "Safari Graphics and Media",
                   bundle: String = "com.apple.Safari", site: NotchWebSite?, kind: NotchMediaKind? = nil) -> NotchMedia {
            let track = TrackInfo.Payload(title: title, artist: artist, isPlaying: true, durationMicros: duration.map { $0 * 1_000_000 },
                elapsedTimeMicros: duration == nil ? nil : 125_000_000, applicationName: app, bundleIdentifier: bundle,
                artworkDataBase64: art.flatMap(base64), artworkMimeType: art == nil ? nil : "image/png",
                timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000, playbackRate: 1, artwork: art)
            return NotchMedia(previewTrack: track, previewSite: site, previewKind: kind)
        }
        let thumbnail = image(300, background: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.45, alpha: 1)) { rect in
            letter("▶", color: .white)(rect.insetBy(dx: 90, dy: 90))
        }
        let fixtures: [(name: String, media: NotchMedia, expanded: Bool)] = [
            ("native-web-generic", media(title, artist: "", duration: nil, site: bbc), true),
            ("native-web-generic-timed", media(title, artist: "", duration: 754, site: bbc), true),
            ("native-web-generic-chrome", media(title, artist: nil, duration: nil, app: "Google Chrome", bundle: "com.google.Chrome", site: nil), true),
            ("native-web-generic-wings", media(title, artist: "", duration: nil, site: bbc), false),
            ("native-web-generic-soundcloud", media("Midnight City", artist: "M83", duration: 243, art: cover, site: soundCloud), true),
            ("native-web-youtube-zen", media("NBA's Top 10 Plays of the Night | October 5, 2026", artist: "NBA", duration: 129, art: thumbnail,
                                             app: "Zen", bundle: "app.zen-browser.zen", site: nil, kind: .youTube), true),
            ("native-web-pending", media("Netflix", artist: "", duration: nil, art: cover, site: nil, kind: .pending), true)
        ]
        for fixture in fixtures {
            let preview = NotchExperience(media: fixture.media)
            preview.geometry = geometry
            preview.state.expanded = fixture.expanded
            render(preview, name: fixture.name, in: directory)
        }
        // The peek as the media works it out when the track starts.
        for (name, source) in [("native-web-generic-peek", media(title, artist: "", duration: nil, site: bbc)),
                               ("native-web-generic-peek-chrome", media(title, artist: nil, duration: nil, app: "Google Chrome",
                                                                        bundle: "com.google.Chrome", site: nil))] {
            let preview = NotchExperience(media: source)
            preview.geometry = geometry
            preview.state.trackPeek = source.nowPlaying
            preview.trackPeekArtwork = source.peekArtwork
            render(preview, name: name, in: directory)
        }
    }

    /// The open player with Like and Volume in its slots, then grown by the volume and brightness rows, and the
    /// Now Playing page with its slot pickers. The rows read the live levels; nothing is changed. A throwaway suite
    /// keeps the slots out of the user's settings.
    @MainActor
    private static func renderPlayerButtons(geometry: NotchGeometry?, in directory: URL) {
        let suite = "ro.andrei.NotchLab.RenderButtons"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let media = NotchMedia(previewTrack: TrackInfo.Payload(title: "Weightless", artist: "Marconi Union", isPlaying: true,
            durationMicros: 240_000_000, elapsedTimeMicros: 90_000_000, applicationName: "Music", bundleIdentifier: "com.apple.Music",
            timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000, playbackRate: 1))
        let preview = NotchExperience(media: media, defaults: defaults)
        preview.geometry = geometry
        preview.settings.playerLeftButton = .like
        preview.settings.playerRightButton = .volume
        preview.volume.start()
        preview.brightness.start()
        preview.state.expanded = true
        render(preview, name: "native-expanded-like-volume", in: directory)
        preview.settings.playerRightButton = .playlist
        render(preview, name: "native-expanded-like-playlist", in: directory)
        preview.settings.playerRightButton = .volume
        for (name, level) in [("native-expanded-level-volume", NotchLevel.volume), ("native-expanded-level-brightness", .brightness)] {
            _ = preview.state.show(level: level)
            render(preview, name: name, in: directory)
        }
        renderWindow(NotchAppView(experience: preview, page: .nowPlaying), name: "native-settings-now-playing", in: directory)
        // The Spotify card with a Client ID; the render above shows it without one. The ID is only set in memory.
        NotchSpotify.clientID = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
        renderWindow(NotchAppView(experience: preview, page: .nowPlaying), name: "native-settings-spotify-set", in: directory)
        NotchSpotify.clientID = nil
        // Without a Client ID Spotify has no like or playlists, so the heart is dimmed; Output shows the current device.
        let spotify = NotchExperience(media: NotchMedia(previewTrack: TrackInfo.Payload(title: "Weightless", artist: "Marconi Union",
            isPlaying: true, durationMicros: 240_000_000, elapsedTimeMicros: 90_000_000, applicationName: "Spotify",
            bundleIdentifier: "com.spotify.client", timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000, playbackRate: 1)),
            defaults: defaults)
        spotify.geometry = geometry
        spotify.settings.playerRightButton = .output
        spotify.audioDevices.start()
        spotify.state.expanded = true
        render(spotify, name: "native-expanded-spotify-like-output", in: directory)
        spotify.audioDevices.stop()
        preview.volume.stop()
        preview.brightness.stop()
    }

    /// The Timer page and the timer in the closed notch on a pinned clock: setting 25 min, running with 12:34 left,
    /// the wings, a phase alert, paused, the last ten seconds, Done and the Done row, one missed while away, and the
    /// window's Timers page. A throwaway suite keeps the user's timer untouched; no sound plays.
    @MainActor
    private static func renderTimer(geometry: NotchGeometry?, in directory: URL) {
        let suite = "ro.andrei.NotchLab.RenderTimer"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSinceReferenceDate: 813_000_000)
        let timer = NotchTimer(defaults: defaults, now: { now })
        let preview = NotchExperience(timer: timer, defaults: defaults, playSound: { _ in })
        preview.geometry = geometry
        timer.start()
        timer.dial = 25
        preview.state.expanded = true
        preview.show(.timer)
        render(preview, name: "native-timer-set", in: directory)
        timer.begin(minutes: 25)
        now += 25 * 60 - 754
        timer.update()
        render(preview, name: "native-timer-running", in: directory)
        renderScene(preview, name: "readme-timer", in: directory)
        preview.state.expanded = false
        render(preview, name: "native-timer-wings", in: directory)
        preview.state.hud = .timer(minutes: 10)
        render(preview, name: "native-timer-alert", in: directory)
        preview.state.hud = nil
        preview.state.expanded = true
        timer.pause()
        render(preview, name: "native-timer-paused", in: directory)
        timer.resume()
        now += 754 - 8
        timer.update()
        render(preview, name: "native-timer-final", in: directory)
        now += 8.01
        timer.update()
        render(preview, name: "native-timer-done", in: directory)
        preview.state.expanded = false
        render(preview, name: "native-timer-done-row", in: directory)
        timer.begin(minutes: 45)
        timer.stop()
        now += 3 * 3600
        timer.start()
        render(preview, name: "native-timer-done-missed", in: directory)
        renderWindow(NotchAppView(experience: preview, page: .timers), name: "native-settings-timer", in: directory)
    }

    /// Closed-notch indicators. Volume and brightness read the live levels; Focus uses a Work fixture, the
    /// battery a charging 82 %, an unplugged 64 % and a low 20 %, Caps Lock both states and AirPods Pro connecting
    /// and going away.
    @MainActor
    private static func renderIndicators(geometry: NotchGeometry?, in directory: URL) {
        let work = NotchFocusMode(identifier: "com.apple.focus.work", name: "Work", symbol: "briefcase.fill", tintName: "systemIndigo")
        let preview = NotchExperience(focus: NotchFocus(previewMode: work), battery: NotchBattery(previewLevel: 0.82, plugged: true))
        preview.geometry = geometry
        preview.volume.start()
        preview.brightness.start()
        for (name, hud) in [("native-hud-volume", NotchHUD.volume), ("native-hud-brightness", .brightness),
                            ("native-hud-focus", .focus), ("native-hud-battery-charging", .battery),
                            ("native-hud-capslock-on", .capsLock(on: true)), ("native-hud-capslock-off", .capsLock(on: false))] {
            preview.state.hud = hud
            render(preview, name: name, in: directory)
        }
        preview.state.hud = .battery
        renderScene(preview, name: "readme-indicators", in: directory)
        preview.volume.stop()
        preview.brightness.stop()
        let low = NotchExperience(battery: NotchBattery(previewLevel: 0.2, plugged: false))
        low.geometry = geometry
        low.state.hud = .battery
        render(low, name: "native-hud-battery-low", in: directory)
        let unplugged = NotchExperience(battery: NotchBattery(previewLevel: 0.64, plugged: false))
        unplugged.geometry = geometry
        unplugged.state.hud = .battery
        render(unplugged, name: "native-hud-battery-unplugged", in: directory)
        let airPods = NotchAudioDevice(uid: "fixture", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        for (name, connected) in [("native-hud-audio-connected", true), ("native-hud-audio-disconnected", false)] {
            unplugged.state.hud = .audioDevice(NotchAudioChange(device: airPods, connected: connected))
            render(unplugged, name: name, in: directory)
        }
    }

    /// The closed notch while a track plays, with the wave in each style as a still (the Reduce Motion frame), in
    /// white and in the colour of a fixture artwork.
    @MainActor
    private static func renderWaves(geometry: NotchGeometry?, in directory: URL) {
        let suite = "ro.andrei.NotchLab.Render"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let artwork = NSImage(size: CGSize(width: 64, height: 64), flipped: false) { rect in
            NSGradient(colors: [.systemOrange, .systemPink])?.draw(in: rect, angle: 45)
            return true
        }
        let data = artwork.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        let preview = NotchExperience(media: NotchMedia(previewTrack: TrackInfo.Payload(title: "Weightless", artist: "Marconi Union",
            isPlaying: true, applicationName: "Spotify", bundleIdentifier: "com.spotify.client",
            artworkDataBase64: data?.base64EncodedString(), playbackRate: 1, artwork: artwork)), defaults: defaults)
        preview.geometry = geometry
        for style in NotchWaveStyle.allCases {
            preview.settings.waveStyle = style
            for tinted in [false, true] {
                preview.settings.waveArtworkColor = tinted
                // The tint is computed off the main actor; let it arrive before the still is taken.
                let deadline = Date().addingTimeInterval(2)
                while tinted, preview.media.artworkTint == nil, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                render(preview, name: "native-wave-\(style.rawValue)\(tinted ? "-tinted" : "")", in: directory)
            }
        }
        // The Now Playing page, for the Wave and Artwork cards with their Preview buttons.
        renderWindow(NotchAppView(experience: preview, page: .nowPlaying), name: "native-settings-now-playing-wave", in: directory,
                     height: 1700)
    }

    /// The mini track peek with a short title, titles too long for the row (their marquee at rest), web video naming
    /// its website, right-to-left and Japanese text, and the row without artwork.
    @MainActor
    private static func renderTrackPeeks(geometry: NotchGeometry?, in directory: URL) {
        let preview = NotchExperience()
        preview.geometry = geometry
        let artwork = NSImage(size: CGSize(width: 48, height: 48), flipped: false) { rect in
            NSGradient(colors: [.systemIndigo, .systemTeal])?.draw(in: rect, angle: 45)
            return true
        }
        let peeks: [(name: String, title: String, artist: String?, site: String?, browser: Bool)] = [
            ("native-track-peek", "Weightless", "Marconi Union", nil, false),
            ("native-track-peek-long", "Bohemian Rhapsody - Remastered 2011", "Queen", nil, false),
            ("native-track-peek-web", "How the M5 chip was designed, a long look inside", "Channel", "YouTube", true),
            ("native-track-peek-rtl", "أغنية طويلة جدا عن البحر والليل والقمر", "فيروز", nil, false),
            ("native-track-peek-cjk", "夜に駆ける (Racing Into The Night)", "YOASOBI", nil, false),
        ]
        for peek in peeks {
            preview.state.trackPeek = NotchTrackPeek(title: peek.title, artist: peek.artist, site: peek.site, player: "Music",
                                                     browser: peek.browser)
            preview.trackPeekArtwork = artwork
            render(preview, name: peek.name, in: directory)
            if peek.name == "native-track-peek" { renderScene(preview, name: "readme-now-playing", in: directory) }
        }
        preview.trackPeekArtwork = nil
        render(preview, name: "native-track-peek-no-artwork", in: directory)
    }

    /// The dictation pill fed as Sotto would feed it: recording at a speaking level, the same hovered with its
    /// controls, then transcribing. The socket stays closed.
    @MainActor
    private static func renderDictation(geometry: NotchGeometry?, in directory: URL) {
        let preview = NotchExperience()
        preview.geometry = geometry
        preview.socket.dictation.update(NotchDictationUpdate(state: .recording, level: 0.45))
        preview.state.beginDictation()
        render(preview, name: "native-dictation-recording", in: directory)
        preview.state.hover(true)
        render(preview, name: "native-dictation-controls", in: directory)
        // The experience is not running, so each update ends the pill; begin it again as a running notch would.
        preview.socket.dictation.update(NotchDictationUpdate(state: .processing, level: 0))
        preview.state.beginDictation()
        render(preview, name: "native-dictation-processing", in: directory)
    }

    /// The Calendar page and the countdown in each state worth seeing, on a pinned clock (Friday 2 October 2026,
    /// 10:48, and Wednesday 4 November for a six-week month), days picked in the month, plus the window's Calendar page.
    @MainActor
    private static func renderCalendar(geometry: NotchGeometry?, in directory: URL) {
        let clock = Calendar.current
        let day = { (month: Int, day: Int) in clock.date(from: DateComponents(year: 2026, month: month, day: day))! }
        let friday = day(10, 2), saturday = day(10, 3)
        let at = { (base: Date, hour: Double) in base.addingTimeInterval(hour * 3600) }
        let now = at(friday, 10.8)
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")
        let event = { (id: String, title: String, start: Date, hours: Double, color: NSColor) in
            NotchEvent(id: id, title: title, start: start, end: start.addingTimeInterval(hours * 3600), color: color)
        }
        var standup = event("standup", "Stand-up", at(friday, 11), 0.25, .systemPurple)
        standup.meeting = meet
        var review = event("review", "Thesis review", at(friday, 15.5), 1, .systemBlue)
        review.location = "Faculty"
        let gym = event("gym", "Gym", at(friday, 18), 1, .systemGreen)
        let dayOff = NotchEvent(id: "off", title: "Day off", start: friday, end: saturday, allDay: true, color: .systemOrange)
        let birthday = NotchEvent(id: "birthday", title: "Birthday", start: friday, end: saturday, allDay: true, color: .systemPink)
        let cook = event("cook", "Cooking", at(saturday, 12), 1, .systemYellow)
        let run = event("run", "Run", at(saturday, 9), 1, .systemGreen)
        var current = event("planning", "Sprint planning", at(friday, 10.5), 1, .systemPurple)
        current.meeting = URL(string: "https://us02web.zoom.us/j/123456")
        var long = event("long", "Quarterly architecture review with the platform and security teams", at(friday, 11), 1, .systemTeal)
        long.location = "Building C, room 4.12, Engineering Faculty"
        long.meeting = meet
        let wednesday = day(11, 4)
        let november = [event("lab", "Lab report", at(wednesday, 14), 2, .systemBlue)]
        let pages: [(name: String, calendar: NotchCalendar)] = [
            ("native-calendar-busy", NotchCalendar(preview: [standup, review, gym, dayOff, cook, run], now: now)),
            ("native-calendar-in-progress", NotchCalendar(preview: [current, review, cook], now: now)),
            ("native-calendar-later", NotchCalendar(preview: [review, gym], now: now)),
            ("native-calendar-all-day", NotchCalendar(preview: [dayOff, birthday], now: now)),
            ("native-calendar-clear-tomorrow", NotchCalendar(preview: [cook, run], now: now)),
            ("native-calendar-empty", NotchCalendar(preview: [], now: now)),
            ("native-calendar-long-text", NotchCalendar(preview: [long, review, event("tmrw", "A very long title for tomorrow's first event", at(saturday, 8), 1, .systemRed)], now: now)),
            ("native-calendar-six-weeks", NotchCalendar(preview: november, now: at(wednesday, 9))),
            ("native-calendar-access-needed", NotchCalendar(preview: [], access: .undetermined, now: now)),
            ("native-calendar-access-denied", NotchCalendar(preview: [], access: .denied, now: now))
        ]
        // A day picked in the month, with dots under the days holding events.
        var thesis = event("thesis", "Thesis meeting", at(day(10, 7), 10), 1, .systemPurple)
        thesis.meeting = meet
        var dentist = event("dentist", "Dentist", at(day(10, 7), 16.5), 0.75, .systemBlue)
        dentist.location = "12 Main Street"
        var retro = event("retro", "Retro", at(day(9, 29), 14), 1, .systemPurple)
        retro.meeting = meet
        let month = [standup, review, gym, cook, run, thesis, dentist, retro, event("lab", "Lab", at(day(10, 7), 18), 2, .systemGreen),
                     event("exam", "Exam", at(day(10, 14), 9), 2, .systemRed),
                     NotchEvent(id: "trip", title: "Trip", start: day(10, 22), end: day(10, 24), allDay: true, color: .systemOrange),
                     event("lab-report", "Lab report", at(wednesday, 14), 2, .systemBlue)]
        let picked: [(name: String, calendar: NotchCalendar, months: Int, day: Date)] = [
            ("native-calendar-picked", NotchCalendar(preview: month, now: now), 0, day(10, 7)),
            ("native-calendar-picked-empty", NotchCalendar(preview: month, now: now), 0, day(10, 9)),
            ("native-calendar-picked-past", NotchCalendar(preview: month, now: now), 0, day(9, 29)),
            ("native-calendar-picked-next-month", NotchCalendar(preview: month, now: now), 1, wednesday),
            ("native-calendar-picked-no-access", NotchCalendar(preview: [], access: .undetermined, now: now), 0, day(10, 7))
        ]
        for page in picked {
            page.calendar.selection.page(by: page.months, today: now)
            page.calendar.selection.select(page.day, today: now)
        }
        for page in pages + picked.map({ ($0.name, $0.calendar) }) {
            let preview = NotchExperience(calendar: page.calendar)
            preview.geometry = geometry
            preview.state.expanded = true
            preview.show(.calendar)
            render(preview, name: page.name, in: directory)
            if page.name == "native-calendar-busy" { renderScene(preview, name: "readme-calendar", in: directory) }
        }
        let countdowns: [(name: String, events: [NotchEvent], now: Date, hud: NotchHUD?)] = [
            ("native-countdown-12m", [standup], now, nil),
            ("native-countdown-1m", [standup], at(friday, 10.99), nil),
            ("native-countdown-1h", [review], at(friday, 14.5), nil),
            ("native-countdown-long-title", [long], now, nil),
            ("native-countdown-volume-over", [standup], now, .volume)
        ]
        for countdown in countdowns {
            let closed = NotchExperience(calendar: NotchCalendar(preview: countdown.events, now: countdown.now, lead: 60 * 60))
            closed.geometry = geometry
            closed.state.countdown = true
            closed.state.hud = countdown.hud
            // The volume indicator reads the live level, as in `renderIndicators`.
            closed.volume.start()
            render(closed, name: countdown.name, in: directory)
            closed.volume.stop()
        }
        // Quick Peeks: when the countdown begins, at the start with a call, without a place and with long text.
        var planning = event("planning", "Sprint planning", at(friday, 10.8), 0.5, .systemPurple)
        planning.location = "Room 2.14, Faculty"
        planning.meeting = meet
        let peeks: [(name: String, peek: NotchEventPeek, now: Date)] = [
            ("native-peek-before", NotchEventPeek(event: planning, starting: false), at(friday, 10.55)),
            ("native-peek-start", NotchEventPeek(event: planning, starting: true), at(friday, 10.8)),
            ("native-peek-no-place", NotchEventPeek(event: gym, starting: false), at(friday, 17.8)),
            ("native-peek-long-text", NotchEventPeek(event: long, starting: false), now)
        ]
        for peek in peeks {
            let closed = NotchExperience(calendar: NotchCalendar(preview: [peek.peek.event], now: peek.now))
            closed.geometry = geometry
            closed.state.eventPeek = peek.peek
            render(closed, name: peek.name, in: directory)
        }
        // Time to leave, in each travel mode; a throwaway suite, since the mode is a saved setting.
        let leaveSuite = "ro.andrei.NotchLab.RenderLeave"
        for mode in NotchTravelMode.allCases {
            guard let defaults = UserDefaults(suiteName: leaveSuite) else { continue }
            defer { defaults.removePersistentDomain(forName: leaveSuite) }
            let closed = NotchExperience(calendar: NotchCalendar(preview: [review], now: at(friday, 15)), defaults: defaults)
            closed.geometry = geometry
            closed.settings.travelMode = mode
            closed.state.hud = .leave(review)
            render(closed, name: "native-leave-\(mode.rawValue)", in: directory)
        }
        let sources = [NotchCalendarSource(id: "home", title: "Home", account: "iCloud", color: .systemBlue),
                       NotchCalendarSource(id: "uni", title: "University", account: "iCloud", color: .systemPurple),
                       NotchCalendarSource(id: "work", title: "Work", account: "work@example.com", color: .systemGreen),
                       NotchCalendarSource(id: "holidays", title: "Holidays", account: "Subscribed", color: .systemRed)]
        for (name, calendar) in [("native-settings-calendar", NotchCalendar(preview: [], calendars: sources, now: now)),
                                 ("native-settings-calendar-access", NotchCalendar(preview: [], access: .undetermined, now: now))] {
            // A throwaway suite: the hidden calendar would otherwise be saved to the user's settings.
            let suite = "ro.andrei.NotchLab.RenderCalendar"
            guard let defaults = UserDefaults(suiteName: suite) else { continue }
            defer { defaults.removePersistentDomain(forName: suite) }
            let preview = NotchExperience(calendar: calendar, defaults: defaults)
            preview.settings.hiddenCalendars = ["holidays"]
            renderWindow(NotchAppView(experience: preview, page: .calendar), name: name, in: directory, height: 1500)
        }
        // The General page at its defaults, for the Gestures card; a throwaway suite again.
        let generalSuite = "ro.andrei.NotchLab.RenderGeneral"
        if let defaults = UserDefaults(suiteName: generalSuite) {
            defer { defaults.removePersistentDomain(forName: generalSuite) }
            // Tall enough to reach the Gestures card.
            renderWindow(NotchAppView(experience: NotchExperience(defaults: defaults), page: .general),
                         name: "native-settings-general", in: directory, height: 1560)
            // The Sotto page with the link on and off. It only opens while Sotto runs, so render with it running.
            let experience = NotchExperience(defaults: defaults)
            renderWindow(NotchAppView(experience: experience, page: .sotto), name: "native-settings-sotto", in: directory)
            experience.settings.sottoLinked = false
            renderWindow(NotchAppView(experience: experience, page: .sotto), name: "native-settings-sotto-off", in: directory)
        }
    }

    /// Lock screen: the lock wing locked and as the shackle opens, the media widget in each style over a
    /// stand-in wallpaper, and the settings page. Offscreen renders cannot sample what is behind a window, so the
    /// glass shows only its dark layer here; the real material needs the lock screen itself.
    @MainActor
    private static func renderLockScreen(geometry: NotchGeometry, in directory: URL) {
        let suite = "ro.andrei.NotchLab.RenderLock"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let track = TrackInfo.Payload(title: "Weightless", artist: "Marconi Union", isPlaying: true,
                                      durationMicros: 480_000_000, elapsedTimeMicros: 170_000_000,
                                      applicationName: "Spotify", bundleIdentifier: "com.spotify.client",
                                      timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000, playbackRate: 1)
        let experience = NotchExperience(media: NotchMedia(previewTrack: track), defaults: defaults)
        let wallpaper = LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.42), Color(red: 0.45, green: 0.25, blue: 0.4)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
        func save(_ view: some View, size: CGSize, name: String) {
            let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(wallpaper)
                .transaction { $0.disablesAnimations = true })
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            // Lets the wing's first-frame state settle before the capture.
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let wingSize = CGSize(width: geometry.frame(.indicator).width + 40, height: geometry.topHeight + 12)
        for (phase, name) in [(NotchLockPhase.locked, "native-lock-wing-locked"), (.opening, "native-lock-wing-opening")] {
            let controller = NotchLockScreenController(experience: experience)
            controller.preview(phase, track: track, geometry: geometry)
            save(controller.wingView, size: wingSize, name: name)
        }
        let widgetSize = CGSize(width: NotchLockScreenLayout.widgetSize.width + 60, height: NotchLockScreenLayout.widgetSize.height + 60)
        for style in NotchLockGlass.allCases {
            experience.settings.lockScreenGlass = style
            let controller = NotchLockScreenController(experience: experience)
            controller.preview(.locked, track: track, geometry: geometry)
            save(controller.widgetView, size: widgetSize, name: "native-lock-media-\(style.rawValue)")
        }
        // Generic web media: play or pause alone, no line without times, the site's tile.
        experience.settings.lockScreenGlass = NotchSettings().lockScreenGlass
        let favicon = image(64, background: nil) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 6, yRadius: 6).fill()
            letter("B", color: .black)(rect.insetBy(dx: 10, dy: 10))
        }
        let page = TrackInfo.Payload(title: "Inside the Large Hadron Collider", artist: "", isPlaying: true,
                                     applicationName: "Safari Graphics and Media", bundleIdentifier: "com.apple.Safari", playbackRate: 1)
        let site = NotchWebSite(name: "bbc.co.uk", host: "bbc.co.uk", url: URL(string: "https://www.bbc.co.uk/news/videos/1")!,
                                icon: favicon, matchesTrack: true)
        let web = NotchExperience(media: NotchMedia(previewTrack: page, previewSite: site), defaults: defaults)
        let webController = NotchLockScreenController(experience: web)
        webController.preview(.locked, track: page, geometry: geometry)
        save(webController.widgetView, size: widgetSize, name: "native-lock-media-web-generic")
        renderLockScene(geometry: geometry, in: directory)
        experience.settings = NotchSettings()
        renderWindow(NotchAppView(experience: experience, page: .lockScreen), name: "native-settings-lock-screen", in: directory)
    }

    /// The whole 1470 × 956 lock screen of this Mac with the clock and the login block drawn as dashed reference boxes
    /// where macOS 27 puts them (measured from a screenshot of the real lock screen), and the widget at its place;
    /// then the artwork enlarged over its wash, and halfway through the flight. Fixture artwork, no live media.
    @MainActor
    private static func renderLockScene(geometry: NotchGeometry, in directory: URL) {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        // A black wallpaper with a few coloured shapes behind the widget, like this Mac's.
        let shapes: [(x: CGFloat, y: CGFloat, size: CGFloat, color: Color)] = [
            (520, 360, 90, .pink), (640, 330, 70, .orange), (820, 380, 110, .purple), (930, 470, 80, .gray),
            (480, 560, 70, .teal), (900, 600, 60, .blue), (560, 600, 50, .brown)
        ]
        let wallpaper = ZStack(alignment: .topLeading) {
            Color.black
            ForEach(shapes.indices, id: \.self) { index in
                let shape = shapes[index]
                Circle().fill(shape.color.opacity(0.8)).frame(width: shape.size, height: shape.size)
                    .offset(x: shape.x, y: shape.y)
            }
        }
        guard let track = lockSceneTrack() else { return }
        let suite = "ro.andrei.NotchLab.RenderLockScene"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let experience = NotchExperience(media: NotchMedia(previewTrack: track), defaults: defaults)
        // Measured on the real lock screen: the date and clock from 8.5 % to 24.5 % down, the picture, name and
        // prompt from 82.6 % to 95 %.
        let reference = { (label: String, top: CGFloat, bottom: CGFloat, width: CGFloat) in
            RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .overlay(alignment: .topLeading) {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).padding(6)
                }
                .frame(width: width, height: (bottom - top) * screen.height)
                .offset(x: (screen.width - width) / 2, y: top * screen.height)
        }
        for (name, enlarged, progress) in [("native-lock-scene", false, nil), ("native-lock-scene-art-mid", true, 0.5),
                                           ("native-lock-scene-art", true, 1.0)] as [(String, Bool, Double?)] {
            let controller = NotchLockScreenController(experience: experience)
            controller.preview(.locked, track: track, geometry: geometry, screen: screen, enlarged: enlarged)
            guard let stage = controller.stage else { continue }
            let frame = stage.local(stage.frame, in: screen)
            let view = ZStack(alignment: .topLeading) {
                wallpaper
                reference("Clock", 0.085, 0.245, 400)
                reference("Picture, name, password", 0.826, 0.95, 260)
                if enlarged { controller.washView(progress: progress) }
                controller.stageView(progress: progress).frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
            }
            .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            .transaction { $0.disablesAnimations = true }
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: screen.size)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    /// A playing fixture track with drawn artwork, for the lock scene renders and the hit probe.
    @MainActor
    private static func lockSceneTrack() -> TrackInfo.Payload? {
        let side = 600.0
        let art = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.95, green: 0.55, blue: 0.25, alpha: 1),
                                NSColor(srgbRed: 0.75, green: 0.2, blue: 0.35, alpha: 1),
                                NSColor(srgbRed: 0.1, green: 0.3, blue: 0.45, alpha: 1)])?.draw(in: rect, angle: -60)
            NSColor(srgbRed: 1, green: 0.85, blue: 0.55, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: CGRect(x: side * 0.3, y: side * 0.42, width: side * 0.36, height: side * 0.36)).fill()
            return true
        }
        guard let tiff = art.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        return TrackInfo.Payload(title: "Weightless", artist: "Marconi Union", isPlaying: true,
                                 durationMicros: 480_000_000, elapsedTimeMicros: 170_000_000,
                                 applicationName: "Spotify", bundleIdentifier: "com.spotify.client",
                                 artworkDataBase64: png.base64EncodedString(),
                                 timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000, playbackRate: 1,
                                 artwork: art)
    }

    /// Shows the lock screen stage in a real lock panel at its place on the main display for about a second each,
    /// enlarged and then with the widget hidden, and asks the window server which window a click at chosen points would
    /// reach. Only the widget's shape and the artwork may take one; the padding, shadow, gaps and clipped corners must
    /// pass it on. Runs on the desktop, not the lock screen, with no lock signals, media or settings involved.
    @MainActor
    private static func hitProbe() -> Bool {
        guard let screen = NSScreen.screens.first?.frame, let track = lockSceneTrack(),
              let defaults = UserDefaults(suiteName: "ro.andrei.NotchLab.HitProbe") else { return false }
        defer { defaults.removePersistentDomain(forName: "ro.andrei.NotchLab.HitProbe") }
        let experience = NotchExperience(media: NotchMedia(previewTrack: track), defaults: defaults)
        var passed = true
        for enlarged in [true, false] {
            let controller = NotchLockScreenController(experience: experience)
            controller.preview(.locked, track: enlarged ? track : nil, geometry: .fallback, screen: screen, enlarged: enlarged)
            guard let stage = controller.stage else { return false }
            let (art, widget) = (stage.art, stage.widget)
            let points: [(name: String, point: CGPoint, takes: Bool)] = enlarged ? [
                ("artwork centre", CGPoint(x: art.midX, y: art.midY), true),
                ("artwork, 4 pt inside its left edge", CGPoint(x: art.minX + 4, y: art.midY), true),
                ("widget centre", CGPoint(x: widget.midX, y: widget.midY), true),
                ("widget title", CGPoint(x: widget.midX, y: widget.maxY - 30), true),
                ("widget, 3 pt inside its bottom edge", CGPoint(x: widget.midX, y: widget.minY + 3), true),
                ("widget corner outside its curve", CGPoint(x: widget.minX + 2, y: widget.maxY - 2), false),
                ("artwork corner outside its curve", CGPoint(x: art.minX + 2, y: art.maxY - 2), false),
                ("shadow 6 pt below the artwork", CGPoint(x: art.midX, y: art.minY - 6), false),
                ("padding left of the artwork", CGPoint(x: art.minX - 16, y: art.midY), false),
                ("padding above the artwork", CGPoint(x: art.midX, y: art.maxY + 16), false),
                ("gap between the artwork and the widget", CGPoint(x: widget.minX + 6, y: widget.maxY + 12), false)
            ] : [
                ("hidden widget centre", CGPoint(x: widget.midX, y: widget.midY), false),
                ("hidden widget title", CGPoint(x: widget.midX, y: widget.maxY - 30), false)
            ]
            let panel = NotchLockPanel(frame: enlarged ? stage.frame : widget, level: .statusBar + 2,
                                       content: controller.stageView(progress: enlarged ? 1 : nil)
                                           .transaction { $0.disablesAnimations = true })
            panel.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            for (name, point, takes) in points {
                let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == panel.windowNumber
                if hit != takes { passed = false }
                print("\(hit == takes ? "ok  " : "FAIL") \(name): \(hit ? "taken" : "passed through")")
            }
            panel.orderOut(nil)
            panel.close()
        }
        return passed
    }

    /// T3 Code: alerts in the closed notch, the list page, a thread's page running, asking and waiting for
    /// approval, and the settings page, from fixed threads on a throwaway suite.
    @MainActor
    private static func renderAgents(geometry: NotchGeometry?, in directory: URL) {
        let suite = "ro.andrei.NotchLab.RenderAgents"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date.now
        let thread = { (id: String, title: String, project: String, branch: String, phase: NotchAgentPhase, minutes: Double) in
            NotchAgentThread(id: id, title: title, projectID: project, project: project, branch: branch, model: "claude-opus-5-5",
                             phase: phase, runID: "run:\(id)", runStarted: now.addingTimeInterval(-minutes * 60),
                             runCompleted: phase == .running || phase.needsYou ? nil : now.addingTimeInterval(-minutes * 20),
                             updated: now.addingTimeInterval(-minutes * 20), requestID: phase.needsYou ? "request:\(id)" : nil,
                             pullRequest: nil)
        }
        var quickPeek = thread("peek", "Implement Calendar Quick Peek", "Eclipse", "feat/9-quick-peek", .done, 6.2)
        quickPeek.pullRequest = NotchAgentPullRequest(number: 82, url: URL(string: "https://github.com/example/notch/pull/82")!)
        // Back from a snooze an hour ago and not opened since: Woke.
        var woke = thread("leave", "Say when it is time to leave", "Eclipse", "feat/9-leave", .done, 40)
        woke.snoozedAt = now.addingTimeInterval(-5 * 3600)
        woke.snoozedUntil = now.addingTimeInterval(-3600)
        let threads = [
            thread("input", "T3 Code Activity in Eclipse", "Eclipse", "feat/50-t3-code", .input, 18),
            thread("approve", "Fix the dictation typos", "Dictation", "fix/typos", .approval, 1),
            thread("battery", "Add Notch Battery Status Indicator", "Eclipse", "feat/7-battery", .running, 4.2),
            thread("ideas", "Brainstorm new features", "Eclipse", "main", .running, 12),
            quickPeek,
            woke,
            thread("rename", "Rename the app to Eclipse", "Eclipse", "rename-eclipse", .failed, 70),
        ]
        let question = NotchAgentQuestion(id: "layout", header: "Layout", question: "Which pop-up layout should Eclipse use?",
            options: [.init(label: "Title only", description: "Smallest; the word says the rest", value: nil),
                      .init(label: "Title and project", description: "Adds project, branch and run time", value: nil),
                      .init(label: "Title and last message", description: "Two lines of the final reply", value: nil)],
            multiSelect: false)
        // Images rendered earlier in this run stand in for the thread's own; their thumbnails are decoded up front.
        let images = ["native-calendar-busy", "native-expanded-playing", "native-peek-before", "native-hud-volume",
                      "native-compact-playing", "native-calendar-in-progress"].map {
            NotchAgentImage.file(path: directory.appending(path: "\($0).png").path, name: $0)
        }
        let details: [String: NotchAgentDetail] = [
            "input": NotchAgentDetail(message: nil, lastMessage: nil, files: 0,
                                      request: .questions(id: "request:input", [question]), runID: "run:input"),
            "approve": NotchAgentDetail(message: nil, lastMessage: nil, files: 0,
                                        request: .approval(id: "request:approve", kind: "command",
                                                           prompt: "xcodebuild -scheme Sotto -configuration Debug build",
                                                           decisions: NotchAgentDecision.fallback), runID: "run:approve"),
            "battery": NotchAgentDetail(message: "Moving the thresholds into `NotchSettings` so the window can change them. Next I add two checks for the edges.",
                                        lastMessage: nil, files: 4, request: nil, runID: "run:battery"),
            "leave": NotchAgentDetail(images: images, message: "Here are the **calendar** renders from this run; the first one is the busy day.",
                                      lastMessage: nil, files: 2, request: nil, runID: "run:leave"),
            "peek": NotchAgentDetail(images: images, message: """
                ## Quick Peek

                Opened **PR #82**. `scripts/check.sh` passes; the peek shows before and at the start:

                | Moment | Shows | Duration |
                |---|---|---|
                | 15 min before | title, time, place | 4 s |
                | At start | Now, Join in green | 4 s |

                - Hover holds it, a click opens the event.
                - Physical check of the hover hold is still pending.
                """, lastMessage: nil, files: 4, request: nil, runID: "run:peek"),
        ]
        let make = { (t3: NotchT3) -> NotchExperience in
            let preview = NotchExperience(t3: t3, defaults: defaults)
            preview.geometry = geometry
            preview.settings.t3Linked = true
            return preview
        }
        for (name, alert) in [("native-t3-alert-done", NotchAgentAlert(thread: quickPeek)),
                              ("native-t3-alert-input", NotchAgentAlert(thread: threads[0])),
                              ("native-t3-alert-approve", NotchAgentAlert(thread: threads[1])),
                              ("native-t3-alert-3-done", NotchAgentAlert(thread: quickPeek, count: 3)),
                              ("native-t3-alert-woke", NotchAgentAlert(thread: { var shown = woke; shown.phase = .woke; return shown }()))] {
            let closed = make(NotchT3(preview: threads))
            closed.state.agentPeek = alert
            render(closed, name: name, in: directory)
        }
        let larger = make(NotchT3(preview: threads))
        larger.settings.agentAlertScale = 1.2
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main {
            larger.geometry = NotchGeometry(screen: screen, settings: larger.settings)
        }
        larger.state.agentPeek = NotchAgentAlert(thread: quickPeek)
        render(larger, name: "native-t3-alert-done-120", in: directory)
        larger.settings.agentAlertScale = 1
        // The client finds the images on disk when it reads a snapshot; the fixtures do it here.
        let found = details.mapValues { detail in
            var detail = detail
            detail.imageFiles = NotchT3.files(for: detail.images)
            return detail
        }
        found.values.flatMap(\.imageFiles).forEach { NotchThumbnails.loadNow($0.url) }
        let list = make(NotchT3(preview: threads, details: found))
        list.state.expanded = true
        list.show(.agents)
        render(list, name: "native-t3-list", in: directory)
        for (name, id) in [("native-t3-thread-running", "battery"), ("native-t3-thread-input", "input"),
                           ("native-t3-thread-approve", "approve"), ("native-t3-thread-done", "peek"),
                           ("native-t3-thread-images", "leave")] {
            list.state.agentThread = id
            render(list, name: name, in: directory)
        }
        // The window controller rebuilds the geometry from the settings in the app; here it is done by hand.
        list.settings.agentPageScale = 1.2
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main {
            list.geometry = NotchGeometry(screen: screen, settings: list.settings)
        }
        list.state.agentThread = "battery"
        render(list, name: "native-t3-thread-running-120", in: directory)
        list.settings.agentPageScale = 1
        let offline = make(NotchT3(preview: [], status: .notRunning))
        offline.state.expanded = true
        offline.show(.agents)
        render(offline, name: "native-t3-list-not-running", in: directory)
        renderWindow(NotchAppView(experience: make(NotchT3(preview: threads)), page: .t3), name: "native-settings-t3", in: directory)
    }

    /// The app window at its default size on black, since the window's material does not draw off screen; a
    /// taller height shows more of a long page.
    @MainActor
    private static func renderWindow(_ view: NotchAppView, name: String, in directory: URL, height: CGFloat = 720) {
        let size = CGSize(width: 640, height: height)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(.black))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// Shelf, drop-target and screenshot fixtures use a throwaway preferences suite, so the user's shelf is untouched.
    @MainActor
    private static func renderShelf(geometry: NotchGeometry?, in directory: URL) {
        let suite = "ro.andrei.NotchLab.Render"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let preview = NotchExperience(media: NotchMedia(previewTrack: TrackInfo.Payload(title: "Weightless", artist: "Marconi Union",
            isPlaying: true, durationMicros: 240_000_000, elapsedTimeMicros: 90_000_000, applicationName: "Spotify",
            bundleIdentifier: "com.spotify.client", timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000,
            shuffleMode: nil, repeatMode: nil, playbackRate: 1)), defaults: defaults)
        preview.geometry = geometry
        let screenshot = fixtureScreenshot()
        defer { try? FileManager.default.removeItem(at: screenshot) }
        NotchImagePreview.make(screenshot)
        preview.shelf.add([Bundle.main.bundleURL, URL(fileURLWithPath: "/etc/hosts"),
                           URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), screenshot])
        preview.state.expanded = true
        render(preview, name: "native-expanded-shelf-switch", in: directory)
        preview.show(.shelf)
        render(preview, name: "native-expanded-shelf", in: directory)
        // The README's shelf: a screenshot and a note, nothing from this Mac.
        let notes = FileManager.default.temporaryDirectory.appending(path: "notes.md")
        try? Data("# Notes\n".utf8).write(to: notes)
        defer { try? FileManager.default.removeItem(at: notes) }
        preview.shelf.removeAll()
        preview.shelf.add([screenshot, notes])
        renderScene(preview, name: "readme-shelf", in: directory)
        renderClipboard(geometry: geometry, defaults: defaults, screenshot: screenshot, in: directory)
        preview.state.dragEnter()
        preview.dropZone = .airDrop
        render(preview, name: "native-drop-targets", in: directory)
        let peek = NotchExperience(defaults: defaults)
        peek.geometry = geometry
        _ = peek.state.show(screenshot: screenshot)
        render(peek, name: "native-screenshot-peek", in: directory)
        // A finished download, from GitHub and quarantined, then a long name with no source and no quarantine.
        let fetched = NotchExperience(defaults: defaults)
        fetched.geometry = geometry
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads")
        _ = fetched.state.show(download: NotchDownload(url: downloads.appending(path: "eclipse-1.4.zip"), host: "github.com", quarantined: true))
        render(fetched, name: "native-download-peek", in: directory)
        renderScene(fetched, name: "readme-downloads", in: directory)
        _ = fetched.state.show(download: NotchDownload(url: downloads.appending(path: "Quarterly report, final version 3 (signed).pdf"),
                                                      host: nil, quarantined: false))
        render(fetched, name: "native-download-peek-long", in: directory)
        fetched.settings.downloadAlerts = true
        renderWindow(NotchAppView(experience: fetched, page: .downloads), name: "native-settings-downloads", in: directory, height: 900)
    }

    /// The Shelf page's Clipboard list with an image, a link and a command, then with a secret on top, and its
    /// settings page. Copies go through a private pasteboard, so the user's clipboard is never read or written.
    @MainActor
    private static func renderClipboard(geometry: NotchGeometry?, defaults: UserDefaults, screenshot: URL, in directory: URL) {
        let board = NSPasteboard(name: NSPasteboard.Name("ro.andrei.NotchLab.Render.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let preview = NotchExperience(clipboard: NotchClipboard(pasteboard: board, access: { .allowed }), defaults: defaults)
        preview.geometry = geometry
        preview.settings.clipboardHistory = true
        preview.clipboard.start()
        defer { preview.clipboard.stop() }
        func copy(_ object: NSPasteboardWriting) {
            board.clearContents()
            board.writeObjects([object])
            preview.clipboard.poll()
        }
        if let image = NSImage(contentsOf: screenshot) { copy(image) }
        copy("https://github.com/AndreiStolojan/Eclipse/pull/115" as NSString)
        copy("brew install --cask zen" as NSString)
        preview.state.expanded = true
        preview.show(.shelf)
        preview.shelfShowsClipboard = true
        render(preview, name: "native-expanded-clipboard", in: directory)
        copy(("ghp_" + String(repeating: "aB3", count: 12)) as NSString)
        render(preview, name: "native-expanded-clipboard-secret", in: directory)
        preview.clipboard.clear()
        render(preview, name: "native-expanded-clipboard-empty", in: directory)
        renderWindow(NotchAppView(experience: preview, page: .shelf), name: "native-settings-shelf", in: directory)
    }

    /// A stand-in screenshot, 1512 × 982 pixels: a desktop gradient with a light document window and a dark one.
    private static func fixtureScreenshot() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Screenshot 2026-10-03 at 11.08.14.png")
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1512, pixelsHigh: 982, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return url }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGradient(colors: [NSColor(red: 0.23, green: 0.43, blue: 0.65, alpha: 1), NSColor(red: 0.42, green: 0.30, blue: 0.58, alpha: 1),
                            NSColor(red: 0.75, green: 0.34, blue: 0.48, alpha: 1)])?.draw(in: NSRect(x: 0, y: 0, width: 1512, height: 982), angle: -30)
        NSColor(white: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 106, y: 128, width: 877, height: 727), xRadius: 24, yRadius: 24).fill()
        NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 862, y: 98, width: 544, height: 511), xRadius: 22, yRadius: 22).fill()
        NSColor(red: 0.64, green: 0.85, blue: 0.87, alpha: 1).setFill()
        for (x, height) in [(938.0, 150.0), (1085.0, 290.0), (1232.0, 210.0)] { NSRect(x: x, y: 170, width: 98, height: height).fill() }
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        return url
    }

    /// Read-only diagnostics run hidden, without touching the user's playback or keyboard focus.
    @MainActor
    private static func probe() {
        let experience = NotchExperience()
        let controller = NotchWindowController(experience: experience)
        experience.hidden = true
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        controller.start()
        // Process only the service callbacks. NSApplication.run() would complete launch and may activate a CLI test process.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let panel = NotchMusicPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let report: [String: Any] = [
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "trackAvailable": experience.media.track != nil,
            "source": experience.media.source?.name ?? "none",
            "sourceBundle": experience.media.source?.bundleIdentifier ?? "none",
            "mediaUnavailable": experience.media.unavailable,
            "volumeAvailable": experience.volume.available,
            "brightnessAvailable": experience.brightness.available,
            "keysIntercepted": experience.keys.available,
            "focusAccessible": experience.focus.accessible,
            "focusActive": experience.focus.active.isEmpty ? "none" : experience.focus.active.map(\.name).joined(separator: ", "),
            "screenshotFolder": NotchScreenshots.currentFolder().path,
            "screenshotWatching": experience.screenshots.folder != nil,
            "calendarAccess": "\(experience.calendar.access)",
            "calendarEvents": experience.calendar.agenda.events.count,
            "calendarCountdown": experience.calendar.countdown?.label ?? "none",
            "focusPreserved": frontmost == NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            "panelCanBecomeKey": panel.canBecomeKey,
            "panelCanBecomeMain": panel.canBecomeMain,
            "microphoneUsed": false,
            "speechEngineLoaded": false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        controller.stop()
    }

    /// The README's hero: the open player under the notch, with drawn artwork and Apple Music as the player.
    @MainActor
    private static func renderHero(in directory: URL) {
        guard let art = lockSceneTrack() else { return }
        let track = TrackInfo.Payload(title: "Weightless", artist: "Marconi Union", isPlaying: true, durationMicros: 240_000_000,
            elapsedTimeMicros: 90_000_000, applicationName: "Music", bundleIdentifier: "com.apple.Music",
            artworkDataBase64: art.artworkDataBase64, timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000,
            shuffleMode: .off, repeatMode: .off, playbackRate: 1, artwork: art.artwork)
        let preview = NotchExperience(media: NotchMedia(previewTrack: track))
        preview.state.expanded = true
        renderScene(preview, name: "readme-hero", in: directory)
    }

    /// A README image: the notch as it sits on a 13-inch MacBook Air, at the top of a black desktop under a plain menu
    /// bar drawn here, cropped to the middle 900 pt with a hairline edge. Only the notch is the app's own view.
    @MainActor
    private static func renderScene(_ experience: NotchExperience, name: String, in directory: URL) {
        let live = experience.geometry
        experience.geometry = .fallback
        defer { experience.geometry = live }
        let geometry = NotchGeometry.fallback
        let notch = geometry.frame(experience.state.shape)
        let size = CGSize(width: 900, height: max(notch.height + 72, 150).rounded())
        let menuBar = HStack(spacing: 18) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold)
            ForEach(["File", "Edit", "View", "Go"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Fri 2 Oct  10:48")
        }
        .font(.system(size: 13)).foregroundStyle(.white)
        .padding(.horizontal, 18).frame(height: geometry.topHeight).background(Color(white: 0.08))
        let scene = ZStack(alignment: .top) {
            Color.black
            menuBar
            NotchView(experience: experience, animateTransitions: false).frame(width: notch.width, height: notch.height)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .transaction { $0.disablesAnimations = true }
        let hosting = NSHostingView(rootView: scene)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @MainActor
    private static func render(_ experience: NotchExperience, name: String, in directory: URL) {
        guard let geometry = experience.geometry else { return }
        let frame = geometry.frame(experience.state.shape)
        // A hosting view, unlike ImageRenderer, also draws AppKit-backed content such as the shelf's scroll view.
        let hosting = NSHostingView(rootView: NotchView(experience: experience, animateTransitions: false)
            .frame(width: frame.width, height: frame.height)
            .transaction { $0.disablesAnimations = true })
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

@MainActor
final class NotchLabDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let controller = NotchWindowController()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = Self.eclipseGlyph
        let menu = NSMenu()
        add("Open Eclipse", action: #selector(showWindow), to: menu, key: ",")
        menu.addItem(.separator())
        add("Show / hide notch", action: #selector(toggleHidden), to: menu)
        add("Expand / collapse", action: #selector(toggleExpanded), to: menu)
        add("Refresh player", action: #selector(refresh), to: menu)
        menu.addItem(.separator())
        add("Quit Eclipse", action: #selector(quit), to: menu, key: "q")
        statusItem?.menu = menu
        NotchSpotify.clientID = NotchSpotifyClientID.load()
        controller.start()
        if controller.experience.settings.openWindowAtLaunch { showWindow() }
    }

    /// Menu bar version of the app icon: the eclipse ring and its bright bead, as a template image macOS tints.
    private static let eclipseGlyph: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 3, y: 3.8, width: 11.2, height: 11.2))
            ring.lineWidth = 1.6
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: 11.3, y: 2.9, width: 3.8, height: 3.8)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Eclipse"
        return image
    }()

    /// Opening the app again from Finder or the Dock shows the window, like other menu bar apps.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { controller.stop() }

    /// The app lives in the Dock only while its window is open, then returns to a menu bar item.
    func windowWillClose(_ notification: Notification) {
        controller.experience.windowVisible = false
        DispatchQueue.main.async { NSApplication.shared.setActivationPolicy(.accessory) }
    }

    /// Minimised, covered, hidden or on sleeping displays, the window stops its previews.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        controller.experience.windowVisible = window?.occlusionState.contains(.visible) == true
    }

    /// A menu bar app has no visible main menu, but one is still needed for ⌘, ⌘W and ⌘Q in the window.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        add("Settings…", action: #selector(showWindow), to: appMenu, key: ",")
        appMenu.addItem(.separator())
        add("Quit Eclipse", action: #selector(quit), to: appMenu, key: "q")
        mainMenu.addItem(withTitle: "Eclipse", action: nil, keyEquivalent: "").submenu = appMenu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        mainMenu.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
    @objc private func toggleHidden() { controller.experience.hidden.toggle() }
    @objc private func toggleExpanded() { controller.experience.toggleExpanded() }
    @objc private func refresh() { controller.experience.media.refresh() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    /// One app window, created on first use and hidden rather than destroyed on close.
    @objc private func showWindow() {
        if window == nil {
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            newWindow.contentView = NSHostingView(rootView: NotchAppView(experience: controller.experience))
            newWindow.title = "Eclipse"
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.appearance = NSAppearance(named: .darkAqua)
            newWindow.isReleasedWhenClosed = false
            newWindow.minSize = NSSize(width: 620, height: 640)
            newWindow.isMovableByWindowBackground = true
            newWindow.collectionBehavior = [.moveToActiveSpace]
            newWindow.delegate = self
            newWindow.center()
            newWindow.setFrameAutosaveName("NotchLabWindow")
            window = newWindow
        }
        // The policy switch needs one run loop pass before a window can be ordered in and shown.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { [window] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Quick Look finds its controller through the key window's responder chain, which ends at the app delegate; the
/// notch's panel never becomes key, so the delegate hands control to `NotchQuickLook`.
extension NotchLabDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { NotchQuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { NotchQuickLook.shared.end(panel) }
}
