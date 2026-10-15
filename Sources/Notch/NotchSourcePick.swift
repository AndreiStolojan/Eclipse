import Foundation

/// Picks the player the notch follows. MediaRemote reports one player, the last one to start playing, and keeps it
/// after it pauses even while another plays on: hovering a YouTube thumbnail in a browser plays a muted preview that
/// takes it from Netflix in Safari, and it stays with the paused preview once the pointer leaves. Core Audio tells
/// which apps make sound, so the pick goes:
/// - The system's player is followed while it plays: an app at once, a browser at once when it is heard and nothing
///   else is, otherwise after playing for `hold`. A hover preview is unheard, or heard beside what already plays.
/// - Otherwise another player MediaRemote reported earlier is followed as playing, once it has been heard for
///   `steady`, the system's player has been quiet that long and a recent read confirms its last report is what it
///   plays, so a Safari call after Netflix paused does not show Netflix playing. A confirmation older than
///   `NotchConfirmations.lasts` is read again first (`renew`), since a pause during a call changes no audio. One
///   already shown playing stays while heard, unless a read finds it does not play (`denied`).
/// - A player followed this way that falls silent shows as playing for `steady`, then as paused, until the system's
///   player counts again; a denied one at once. When the system's player changes, the one shown until then stays shown the same way, so a
///   preview does not replace it before it counts.
/// Without Core Audio the system's player is always followed, as before.
struct NotchSourcePick {
    /// How long another player must be heard, and the system's player quiet, before the notch follows it; and how long
    /// a followed player may fall silent, as while buffering or skipping, before it shows as paused.
    static let steady: Duration = .seconds(1.5)
    /// How long a browser must play before it takes the notch when unheard or heard beside another player. YouTube's
    /// hover previews in Zen played 0.2 to 5.3 s each on 7 October (mediaremoted's log).
    static let hold: Duration = .seconds(6)
    /// Browsers by bundle identifier: their hover previews and muted autoplay report playing like anything else.
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.chromium.Chromium", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.kagi.kagimacOS", "com.duckduckgo.macos.browser"
    ]

    enum Followed: Equatable {
        /// The system's now playing player, as MediaRemote reports it.
        case system
        /// Another player by bundle identifier, shown from its last report as playing or paused.
        case other(String, playing: Bool)
    }

    /// What MediaRemote and Core Audio say at one moment. Players are named by bundle identifier.
    struct Report {
        var system: String?
        var systemPlaying = false
        /// Players with a process running output now; nil when Core Audio cannot list processes.
        var heard: Set<String>?
        /// Players Core Audio has a process for at all. One it knows nothing about plays elsewhere, such as over
        /// AirPlay, so it counts as heard when MediaRemote says it plays.
        var voiced: Set<String> = []
        /// Players that may be followed beside the system's: those MediaRemote reported earlier that still run.
        var known: Set<String> = []
        /// Players whose last report a recent read confirms is what they play now, read for those in `wanted`. Only
        /// these start showing as playing beside the system's.
        var confirmed: Set<String> = []
        /// Players confirmed by a read too old to count, which `renew` asks to read again.
        var stale: Set<String> = []
        /// Players a read found not playing their last report; one shown playing shows as paused at once.
        var denied: Set<String> = []
    }

    private(set) var followed = Followed.system
    /// When the pick may change without a new report: a hold or a steady wait ending.
    private(set) var recheck: ContinuousClock.Instant?
    /// Players heard beside the system's while it does not count, which would be followed once `confirmed`.
    private(set) var wanted: Set<String> = []
    /// Players in `wanted` whose confirmation went stale, read again so one may be followed; empty while the followed
    /// player is heard playing.
    private(set) var renew: Set<String> = []
    /// Players whose sound decides the pick while the system's player does not count; empty while it does, or while
    /// no other player is known. Core Audio is read again for these, see `NotchAudibleApps.polled`.
    private(set) var watched: Set<String> = []
    private var system: String?
    private var systemPlayingSince: ContinuousClock.Instant?
    private var systemCounted = false
    /// When the system's player stopped counting; nil when it never did since it became the system's player.
    private var systemQuietSince: ContinuousClock.Instant?
    private var heardSince: [String: ContinuousClock.Instant] = [:]
    /// When the followed player fell silent while shown as playing.
    private var silentSince: ContinuousClock.Instant?
    /// A followed player whose pause was pressed in the notch, which shows as paused as soon as it falls silent.
    private var pausing: String?

    /// Notes that the shown player was paused, by a press in the notch or by the player itself, so it shows as paused as
    /// soon as it falls silent.
    mutating func paused() {
        if case .other(let app, true) = followed { pausing = app }
    }

    /// Takes each report, and a recheck with the last one, and returns the player to follow.
    mutating func update(_ report: Report, at now: ContinuousClock.Instant = .now) -> Followed {
        let heard = report.heard ?? []
        heardSince = heardSince.filter { heard.contains($0.key) }
        for app in heard where heardSince[app] == nil { heardSince[app] = now }
        if report.system != system {
            // The player shown until now carries on as it was, so one heard playing stays playing without a read.
            if followed == .system, let system { followed = .other(system, playing: systemCounted) }
            system = report.system
            systemPlayingSince = nil
            systemCounted = false
            systemQuietSince = nil
        }
        systemPlayingSince = report.systemPlaying ? systemPlayingSince ?? now : nil
        var waits: [ContinuousClock.Instant] = []
        let others = heard.intersection(report.known).subtracting(report.system.map { [$0] } ?? [])

        let counts: Bool
        if let system = report.system, let since = systemPlayingSince, report.heard != nil, Self.browsers.contains(system) {
            let heardAlone = (heard.contains(system) || !report.voiced.contains(system)) && others.isEmpty
            counts = heardAlone || now >= since + Self.hold
            if !counts { waits.append(since + Self.hold) }
        } else {
            counts = report.systemPlaying
        }
        if counts {
            systemQuietSince = nil
        } else if systemCounted {
            systemQuietSince = now
        }
        systemCounted = counts

        var next = Followed.system
        if !counts, report.heard != nil {
            var current: (app: String, playing: Bool)?
            if case .other(let app, let playing) = followed, app != report.system, report.known.contains(app) {
                current = (app, playing)
            }
            let quiet = systemQuietSince.map { now >= $0 + Self.steady } ?? true
            if !quiet, let since = systemQuietSince { waits.append(since + Self.steady) }
            let followable = others.intersection(report.confirmed)
            let ready = followable.filter { now >= heardSince[$0, default: now] + Self.steady }
            waits += followable.subtracting(ready).compactMap { heardSince[$0].map { $0 + Self.steady } }
            if let current, heard.contains(current.app), !report.denied.contains(current.app),
               current.playing || report.confirmed.contains(current.app) {
                next = .other(current.app, playing: true)
            } else if quiet, let app = ready.min() {
                next = .other(app, playing: true)
            } else if let current {
                // A followed player falling silent may be buffering or skipping; it shows as paused only after `steady`.
                let since = current.playing ? silentSince ?? now : now
                let grace = pausing == current.app || report.denied.contains(current.app) ? .zero : Self.steady
                let playing = current.playing && now < since + grace
                if playing { waits.append(since + grace) }
                silentSince = playing ? since : nil
                next = .other(current.app, playing: playing)
            }
        }
        if case .other(let app, _) = next, heard.contains(app) { silentSince = nil }
        if next == .system { silentSince = nil }
        if case .other(let app, true) = next, app == pausing {} else { pausing = nil }
        followed = next
        wanted = !counts && report.heard != nil ? others : []
        if case .other(let app, true) = next, heard.contains(app) { renew = [] } else { renew = wanted.intersection(report.stale) }
        let candidates = report.known.subtracting(report.system.map { [$0] } ?? [])
        watched = counts || candidates.isEmpty ? [] : report.known.union(report.system.map { [$0] } ?? [])
        recheck = waits.filter { $0 > now }.min()
        return next
    }
}

/// Whether each player the pick wants plays what its last report says, for `NotchSourcePick.Report.confirmed` and
/// `denied`: read once each time it starts being heard, again after its audio starts or stops (`stir`) or the Mac
/// locks (`interrupt`), after a read that could not tell, at most twice, and every `refresh` while it is the player
/// followed, since a pause or a resume during a call changes no audio, and on request once a confirmation is older
/// than `lasts` (`renew`). Reads of one player start at least `interval` apart and never while `paused`; a read that
/// cannot tell keeps the last verdict, so only a read that says so takes one back. The caller runs the reads.
struct NotchConfirmations {
    static let interval: Duration = .seconds(10)
    /// How often the followed player is read again while the last read could tell.
    static let refresh: Duration = .seconds(12)
    /// How long a read finding a player plays lets the pick switch to it, see `fresh`.
    static let lasts: Duration = .seconds(12)
    static let attempts = 3

    private struct Entry {
        /// What the last read that could tell found.
        var plays: Bool?
        /// When the last read ended.
        var read: ContinuousClock.Instant?
        /// When the last read that could tell ended.
        var told: ContinuousClock.Instant?
        var due = true
        var reading = false
        /// Reads in a row that could not tell.
        var misses = 0
    }

    private var entries: [String: Entry] = [:]
    var confirmed: Set<String> { Set(entries.filter { $0.value.plays == true }.keys) }
    var denied: Set<String> { Set(entries.filter { $0.value.plays == false }.keys) }

    /// The confirmed players whose confirmation is at most `lasts` old at `now`; the rest are stale.
    func fresh(at now: ContinuousClock.Instant) -> Set<String> {
        Set(entries.filter { $0.value.plays == true && $0.value.told.map { now <= $0 + Self.lasts } == true }.keys)
    }

    /// Keeps the players in `wanted`, each new one due at once, and returns those dropped, whose reads should stop.
    mutating func want(_ wanted: Set<String>) -> Set<String> {
        let dropped = Set(entries.keys).subtracting(wanted)
        for app in dropped { entries[app] = nil }
        for app in wanted where entries[app] == nil { entries[app] = Entry() }
        return dropped
    }

    /// Marks players whose audio started or stopped as due again, since what they play may have changed.
    mutating func stir(_ apps: Set<String>) {
        for app in apps where entries[app] != nil {
            entries[app]?.due = true
            entries[app]?.misses = 0
        }
    }

    /// Marks stale confirmations of `apps` as due, so a player is read afresh before the pick switches to it. One whose
    /// reads could not tell `attempts` times waits for its audio to change.
    mutating func renew(_ apps: Set<String>, at now: ContinuousClock.Instant) {
        for app in apps {
            guard let entry = entries[app], entry.plays == true, !entry.reading, entry.misses < Self.attempts,
                  entry.told.map({ now > $0 + Self.lasts }) ?? true else { continue }
            entries[app]?.due = true
        }
    }

    /// Returns the reads to start now, marked under way, and when the next one may start. `following` is the player
    /// followed beside the system's, read again every `refresh`.
    mutating func start(at now: ContinuousClock.Instant, paused: Bool,
                        following: String? = nil) -> (apps: Set<String>, wake: ContinuousClock.Instant?) {
        guard !paused else { return ([], nil) }
        var apps = Set<String>(), wake: ContinuousClock.Instant?
        for (app, entry) in entries where !entry.reading {
            let from: ContinuousClock.Instant
            if entry.due {
                from = entry.read.map { $0 + Self.interval } ?? now
            } else if app == following, entry.misses == 0, let read = entry.read {
                from = read + Self.refresh
            } else {
                continue
            }
            if from <= now {
                apps.insert(app)
                entries[app]?.due = false
                entries[app]?.reading = true
            } else {
                wake = min(wake ?? from, from)
            }
        }
        return (apps, wake)
    }

    /// Takes a read's result, nil when it could not tell, which is tried again up to `attempts` in all.
    mutating func settle(_ app: String, plays: Bool?, at now: ContinuousClock.Instant) {
        guard var entry = entries[app] else { return }
        entry.reading = false
        entry.read = now
        if let plays {
            entry.plays = plays
            entry.told = now
            entry.misses = 0
        } else {
            entry.misses += 1
            if entry.misses < Self.attempts { entry.due = true }
        }
        entries[app] = entry
    }

    /// Stops the reads under way, as when the Mac locks, and marks every player due, since what each plays may change
    /// while locked; they are read once reads may start, each at most `interval` after its last.
    mutating func interrupt() {
        for app in entries.keys {
            entries[app]?.reading = false
            entries[app]?.due = true
            entries[app]?.misses = 0
        }
    }
}

/// What Spotify or Music says about its current track through AppleScript, for one followed beside the system's
/// player: MediaRemote no longer reports it, so its title, position and state are read here, after it is heard and
/// after each of its own notifications.
struct NotchScriptedPlayer: Equatable {
    var playing = false
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    var position: TimeInterval?
    /// Spotify's cover; Music's artwork is not read.
    var artworkURL: URL?

    /// The distributed notification each player posts when its state or track changes, by bundle identifier. Both
    /// names are in the players' binaries on macOS 27 (checked 7 October).
    static let notifications = [
        "com.spotify.client": "com.spotify.client.PlaybackStateChanged", "com.apple.Music": "com.apple.Music.playerInfo"
    ]

    /// The read for `app`, or nil for a player without one. The app is named literally so its terms compile, and the
    /// caller makes sure it runs, since `tell` would launch it. Prints the state, then for a track its name, artist,
    /// album, duration, position and, for Spotify, cover address, one per line.
    static func script(for app: String) -> String? {
        guard notifications[app] != nil else { return nil }
        let cover = app == "com.spotify.client" ? " & linefeed & (artwork url of t)" : ""
        return """
            tell application id "\(app)"
                set s to player state as text
                if s is "stopped" then return s
                set t to current track
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) ¬
                    & linefeed & (duration of t) & linefeed & player position\(cover)
            end tell
            """
    }

    /// Parses `script`'s output. Spotify gives the duration in milliseconds and Music in seconds; numbers use the
    /// locale's decimal separator, a comma in many European locales. Nil for output that is not the script's.
    static func parse(_ output: String, app: String) -> NotchScriptedPlayer? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let state = lines.first, ["playing", "paused", "stopped"].contains(state) else { return nil }
        var player = NotchScriptedPlayer(playing: state == "playing")
        guard lines.count >= 6 else { return state == "stopped" ? player : nil }
        func text(_ line: String) -> String? { line.isEmpty || line == "missing value" ? nil : line }
        func number(_ line: String) -> Double? {
            Double(line.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        (player.title, player.artist, player.album) = (text(lines[1]), text(lines[2]), text(lines[3]))
        player.duration = number(lines[4]).map { app == "com.spotify.client" ? $0 / 1000 : $0 }.flatMap { $0 > 0 ? $0 : nil }
        player.position = number(lines[5])
        player.artworkURL = lines.count > 6 ? text(lines[6]).flatMap { URL(string: $0) } : nil
        return player
    }
}
