import Foundation

/// Decides when what plays deserves a peek. It peeks when playback starts (from paused, stopped or no player) on a
/// track other than the one that last played, when a different track or player plays while one already did, and
/// when the same track resumes after a pause of `reminder` or longer. A resume after a shorter pause, repeat-one
/// replaying the same track, a track picked while paused and whatever already plays when the watch first hears from
/// the system do not count. A track that played counts as the last one even when no peek showed it (locked, open,
/// switched off), so a resume never announces what was just heard; playing counts only once it lasts `steady`, so a
/// flicker of playing neither becomes the last track nor uses up the reminder. Players often report a new track
/// paused before it plays, so it is compared with the last track that played, not the last reported. A report that
/// leaves out the artist or album of that track borrows them, so a detail arriving later that contradicts still
/// counts as another track. Playback found at launch stays quiet when its title arrives later, unless it stopped
/// or another player played first. It also remembers what was last reported of the playing track, so only news
/// reaches the peek.
struct NotchTrackWatch {
    /// A pause at least this long makes resuming the same track peek again, a reminder of what plays and where.
    static let reminder: Duration = .seconds(10 * 60)
    /// How long playback must last to count as played: the peek's own settle wait.
    static let steady: Duration = .seconds(NotchTrackPeek.settle)

    /// A track as one player reports it: the same title in Safari and in Spotify are different things playing. Tabs
    /// share their browser's identity, so a new tab counts as another track only when what it reports differs.
    private struct Played {
        let source: String?
        let title: String
        var artist: String?
        var album: String?

        /// Nil without a title: a report that names nothing is not a track.
        init?(source: String?, title: String?, artist: String?, album: String?) {
            func clean(_ text: String?) -> String? { text?.isEmpty == false ? text : nil }
            guard let title = clean(title) else { return nil }
            self.source = source
            self.title = title
            self.artist = clean(artist)
            self.album = clean(album)
        }

        /// Whether `other` is this track reported more or less fully: the same player and title, and no detail that
        /// contradicts. Players report the title first and the artist and album a moment later.
        func matches(_ other: Played) -> Bool {
            func agree(_ one: String?, _ two: String?) -> Bool { one == nil || two == nil || one == two }
            return source == other.source && title == other.title && agree(artist, other.artist)
                && agree(album, other.album)
        }

        /// This track with the artist and album it lacks taken from `other`, a report of the same track.
        func filled(from other: Played) -> Played {
            var filled = self
            filled.artist = artist ?? other.artist
            filled.album = album ?? other.album
            return filled
        }
    }

    /// The playback under way, filled in as its details arrive, and since when it plays.
    private var current: (played: Played, since: ContinuousClock.Instant)?
    private var last: Played?
    private var stoppedAt: ContinuousClock.Instant?
    /// Where the watch stands with what already played at launch: nothing heard yet, playback heard from a player
    /// that has not named its track, or over. Only that player naming its track stays quiet.
    private enum Launch: Equatable {
        case unheard
        case untitled(source: String?)
        case over

        /// Whether a titled report from `source` is the launch playback naming itself.
        func quiet(for source: String?) -> Bool {
            switch self {
            case .unheard: true
            case .untitled(let launchSource): launchSource == source
            case .over: false
            }
        }
    }
    private var launch = Launch.unheard

    /// Takes each report of the system's player; true when it deserves a peek. `source` names the player, the rest
    /// the track within it.
    mutating func update(source: String?, title: String?, artist: String? = nil, album: String? = nil,
                         playing nowPlaying: Bool, at now: ContinuousClock.Instant = .now) -> Bool {
        guard var report = nowPlaying ? Played(source: source, title: title, artist: artist, album: album) : nil else {
            // Untitled playback keeps the launch quiet only while it is the launch player's.
            launch = nowPlaying && launch.quiet(for: source) ? .untitled(source: source) : .over
            settle(at: now)
            return false
        }
        if let playing = current, playing.played.matches(report) {
            current = (playing.played.filled(from: report), playing.since)
            return false
        }
        settle(at: now)
        if let last, last.matches(report) { report = report.filled(from: last) }
        // What already plays at launch counts as played at once.
        let quiet = launch.quiet(for: source)
        launch = .over
        current = (report, quiet ? now - Self.steady : now)
        return !quiet && (last?.matches(report) != true || stoppedAt.map { now - $0 >= Self.reminder } == true)
    }

    /// Ends the playback under way, making it the last track if it lasted `steady`.
    private mutating func settle(at now: ContinuousClock.Instant) {
        if let playing = current, now - playing.since >= Self.steady {
            last = playing.played
            stoppedAt = now
        }
        current = nil
    }

    private var known: NotchTrackPeek?
    private var knownArtwork: String?

    /// Whether the playing track's row or artwork differs from what was last reported. The artwork is compared by its
    /// data, so a replaced image counts, not only one arriving; equal strings sharing storage compare at once.
    mutating func learn(_ peek: NotchTrackPeek?, artwork: String?) -> Bool {
        guard peek != known || artwork != knownArtwork else { return false }
        known = peek
        knownArtwork = artwork
        return true
    }
}

/// What the mini peek shows of a new track: the title, and under it the artist, or for web video the website
/// the browser plays it on, falling back to the player's name.
struct NotchTrackPeek: Hashable {
    let title: String
    let detail: String?
    /// The artwork is only the website's logo, so a small site tile shows instead, as in the open player.
    var siteTile = false

    /// Seconds a track's metadata must stay still before the peek shows it: players report the title first and the
    /// artist, artwork and website a moment later, and Safari retitles a tab as its page loads.
    static let settle: Double = 0.35
    /// Seconds the peek stays once the pointer leaves it.
    static let linger: Double = 1
    /// The longest a long title's marquee may keep the peek open, in seconds from when it starts gliding.
    static let longestRead: Double = 9

    /// Nil without a title, so a half-reported track never shows as an empty row.
    init?(title: String?, artist: String?, site: String?, player: String?, browser: Bool, siteTile: Bool = false) {
        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        guard let title = clean(title) else { return nil }
        self.title = title
        detail = browser ? clean(site) ?? clean(artist) ?? clean(player) : clean(artist) ?? clean(player)
        self.siteTile = siteTile
    }
}

extension String {
    /// Whether the text reads right to left, judged by its first letter: Hebrew, Arabic and the scripts beside them.
    /// The marquee then starts from the right edge and glides the other way.
    var readsRightToLeft: Bool {
        guard let letter = unicodeScalars.first(where: \.properties.isAlphabetic) else { return false }
        switch letter.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }
}
