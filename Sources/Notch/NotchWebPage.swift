import Foundation

/// What the playing page says about its video beyond what Safari reports to MediaRemote. Netflix reports only
/// "Netflix", an empty artist, its logo as artwork and no times, so its page is read for the show, the episode and
/// the position. Read with `do JavaScript` when Safari allows it, else, for Netflix only, from the tab's visible text,
/// which needs no more than the Automation permission the website lookup already uses.
struct NotchWebPage: Equatable {
    /// The show or video, and the episode with its name, such as "E17 · Cheap Burgundy".
    var title: String?
    var subtitle: String?
    var progress: Progress?
    /// The video the tab showed when read, see `NotchWebPageRequest.content(of:)`. Netflix's track is "Netflix" for
    /// every episode, so this, not the track, says which video the page belongs to.
    var content = ""

    /// The page's video position at the moment it was read, run on locally between reads.
    struct Progress: Equatable {
        let elapsed: TimeInterval
        let duration: TimeInterval
        let playing: Bool
        let at: Date

        func elapsed(at now: Date) -> TimeInterval {
            min(duration, max(0, elapsed + (playing ? max(0, now.timeIntervalSince(at)) : 0)))
        }
    }

    /// What the page script reads: the media session, Netflix's title heading and the page's main video.
    private struct Script: Decodable {
        var sessionTitle: String?
        var sessionArtist: String?
        var documentTitle: String?
        var heading: [String]?
        var time: Double?
        var duration: Double?
        var paused: Bool?
    }

    /// Parses the page script's JSON. `expected` is the title MediaRemote reports when it names the video: a page now
    /// playing another one, or a reply that is not the script's, is nil. Without `session` only the heading names the
    /// video, as on Netflix, whose media session names only the site. A page that named nothing has no title and no
    /// progress.
    static func parse(script json: String, expected: String?, session: Bool = true, now: Date = .now) -> NotchWebPage? {
        guard let script = try? JSONDecoder().decode(Script.self, from: Data(json.utf8)) else { return nil }
        // A named track must still be what the page plays, by its media session title or else its own title.
        if let expected = nonEmpty(NotchWebSites.plainTitle(expected ?? "")) {
            let playing = NotchWebSites.plainTitle(nonEmpty(script.sessionTitle) ?? script.documentTitle ?? "")
            guard playing.localizedCaseInsensitiveContains(expected) else { return nil }
        }
        var page = NotchWebPage()
        let heading = (script.heading ?? []).compactMap(nonEmpty)
        if heading.count > 1 {
            page.title = heading[0]
            page.subtitle = heading.dropFirst().joined(separator: " · ")
        } else if let line = heading.first {
            // One part is the heading's text run together, as in the tab's text.
            if let parts = split(line) { (page.title, page.subtitle) = (parts.title, parts.subtitle) }
        } else if session, let title = nonEmpty(script.sessionTitle) {
            page.title = title
            page.subtitle = nonEmpty(script.sessionArtist)
        }
        if let time = script.time, let duration = script.duration, time.isFinite, time >= 0, duration.isFinite, duration > 0 {
            page.progress = Progress(elapsed: min(time, duration), duration: duration, playing: script.paused == false, at: now)
        }
        return page
    }

    /// Netflix's player text as Safari gave it on 7 October 2026: the subtitles on screen, five blank lines, the time
    /// left, eight blank lines, then the title heading with its parts run together, "The MentalistE17Cheap Burgundy",
    /// as the last line. The heading is taken only from that place: the last line, right after a time line, the two
    /// and whatever precedes them set apart by more than `gap` blank lines, which a subtitle cue's lines are not. Text
    /// without that shape, such as subtitles alone while the controls are hidden, or a heading `split` cannot tell
    /// apart, names nothing.
    static func parse(netflixText text: String) -> NotchWebPage? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let filled = lines.indices.filter { !lines[$0].isEmpty }
        guard filled.count >= 2 else { return nil }
        let heading = filled[filled.count - 1], time = filled[filled.count - 2]
        let before = filled.count > 2 ? filled[filled.count - 3] : nil
        guard lines[time].wholeMatch(of: #/\d{1,2}(:\d{2}){1,2}/#) != nil, lines[heading].count <= 200,
              heading - time > gap, before.map({ time - $0 > gap }) ?? true,
              let parts = split(lines[heading]) else { return nil }
        return NotchWebPage(title: parts.title, subtitle: parts.subtitle)
    }

    /// Blank lines the time and the heading must at least be set apart by; Netflix leaves five and eight.
    private static let gap = 2

    /// Splits a heading into the show and the episode: "The MentalistE17Cheap Burgundy" into "The Mentalist" and
    /// "E17 · Cheap Burgundy", "ShowT5:E17Episode" into "Show" and "T5:E17 · Episode". A season and episode marker
    /// splits wherever it stands. An episode marker alone splits only where it can be nothing else: after the show's
    /// lowercase letter, digit or punctuation and before a name that starts as one does. A heading without a marker,
    /// as a film's, stays whole. One with a marker run into a word, as "SE7EN", cannot be told apart and is nil, so
    /// the plain site shows rather than a wrong split.
    static func split(_ line: String) -> (title: String, subtitle: String?)? {
        guard let line = nonEmpty(line) else { return nil }
        let season = #/^(?<show>.+?)\s*(?<episode>\p{Lu}\d{1,2}:\s?\p{Lu}\d{1,3})(?<name>[^\p{N}].*)?$/#
        let episode = #/^(?<show>.*?[\p{Ll}\p{N}\p{P}])\s?(?<episode>\p{Lu}\d{1,3})(?<name>[^\p{Ll}\p{N}].*)?$/#
        if let match = line.wholeMatch(of: season) ?? line.wholeMatch(of: episode), let show = nonEmpty(String(match.show)) {
            let marker = String(match.episode), name = match.name.flatMap { nonEmpty(String($0)) }
            return (show, name.map { "\(marker) · \($0)" } ?? marker)
        }
        guard line.firstMatch(of: #/\p{L}\p{Lu}\d/#) == nil else { return nil }
        return (line, nil)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Which tab a page read targets and how. Netflix keeps one tab across episodes while its address changes, so its
/// reads take the one Netflix player tab; any other site's take the tab the website lookup matched, by address. More
/// than one tab matching is ambiguous and reads nothing.
struct NotchWebPageRequest: Equatable {
    /// The tab's address, or its start for `prefix`.
    let address: String
    let prefix: Bool
    /// Falls back to the tab's visible text when Safari refuses JavaScript; only Netflix's text is understood.
    let text: Bool
    /// The title MediaRemote reports when it names the video, which the page must still be playing.
    let expected: String?

    /// The read the open player wants for this track, or nil when MediaRemote already says enough. Netflix is always
    /// read, since it names neither the show nor the time; another site only when its title is just the site's name
    /// or its times are unknown, and only from the tab whose title names the track.
    init?(site: NotchWebSite?, title: String?, durationKnown: Bool) {
        guard let site else { return nil }
        if site.host == "netflix.com" {
            address = "https://\(site.url.host() ?? "www.netflix.com")/watch/"
            prefix = true
            text = true
            expected = nil
            return
        }
        let generic = NotchWebPages.generic(title: title, site: site)
        guard site.matchesTrack, generic || !durationKnown else { return nil }
        address = site.url.absoluteString
        prefix = false
        text = false
        expected = generic ? nil : title
    }

    /// The video a tab at `tabAddress` shows: for Netflix its player's `/watch/<id>`, without the query that changes
    /// as it plays; for another site the address itself. Nil for a Netflix page that is not a player.
    func content(of tabAddress: String) -> String? {
        guard prefix else { return tabAddress == address ? address : nil }
        guard tabAddress.hasPrefix(address) else { return nil }
        let id = tabAddress.dropFirst(address.count).prefix { $0.isASCII && $0.isNumber }
        return id.isEmpty ? nil : address + id
    }
}

/// When the open player reads the page again. While it plays, a page with a position is read every `interval` and
/// run on locally between reads. A video named without a position, or one that named nothing `emptyBudget` times in
/// a row, is only checked every `slowInterval`: the tab's address is compared and its text is read again only once
/// it shows another video. Paused, one read suffices. An unreadable page stops the reads; a failure retries after
/// `NotchWebLookup.retryDelays` in turn and then stops, until the player is shown again.
struct NotchWebPagePoll: Equatable {
    static let interval: TimeInterval = 2
    static let slowInterval: TimeInterval = 10
    static let emptyBudget = 3
    private(set) var failures = 0
    /// The video the last answer came from, the answers in a row that named nothing in it, and whether it was named
    /// without a position.
    private(set) var content: String?
    private(set) var empties = 0
    private var named = false

    enum Outcome: Equatable {
        /// The page named its video or gave its position.
        case read(NotchWebPage)
        /// The tab answered but named nothing, as Netflix's text while its controls are hidden.
        case empty(content: String)
        /// The tab still shows the video the read was told it knows; its page was not read.
        case unchanged(content: String)
        /// No single tab matches, it plays another video, Safari refuses JavaScript for a site without a text
        /// reading, or Automation is not allowed.
        case unavailable
        /// The script failed for a reason that may pass, such as Safari being busy.
        case failed
    }

    /// Starts from a page read before, so a video already named without a position is only checked.
    init(known page: NotchWebPage? = nil) {
        guard let page, page.progress == nil else { return }
        (content, named) = (page.content, true)
    }

    /// The video the next read only checks the tab still shows, or nil to read the page.
    var known: String? { named || empties >= Self.emptyBudget ? content : nil }

    /// Reads run only while the open notch shows the Music page for a page that needs them, and never while the Mac
    /// is locked.
    static func active(_ request: NotchWebPageRequest?, onScreen: Bool, locked: Bool) -> Bool {
        request != nil && onScreen && !locked
    }

    /// The wait before the next read after `outcome`, or nil to stop.
    mutating func next(after outcome: Outcome, playing: Bool) -> TimeInterval? {
        if outcome != .failed { failures = 0 }
        switch outcome {
        case .read(let page):
            (content, empties, named) = (page.content, 0, page.progress == nil)
            return playing ? (named ? Self.slowInterval : Self.interval) : nil
        case .empty(let content):
            if content != self.content { (self.content, empties, named) = (content, 0, false) }
            empties += 1
            return playing ? Self.slowInterval : nil
        case .unchanged:
            return playing ? Self.slowInterval : nil
        case .unavailable:
            return nil
        case .failed:
            failures += 1
            let delays = NotchWebLookup.retryDelays
            return failures <= delays.count ? delays[failures - 1] : nil
        }
    }
}

/// The last page read and whether it may be shown. A page belongs to one track and tab, its `owner`, and to one
/// video, its `content`; it is dropped when the owner changes, on lock, when the tab shows another video or none,
/// and once `freshness` passed since a read last confirmed it. It shows only while confirmed: a read confirms it, and
/// a round of reads starting anew withdraws a confirmation older than `trust`, the longest the open player leaves
/// between its own checks, so the plain site shows until a read finds the tab still on the same video. Reads failing
/// for longer than `trust` withdraw it too, at its `lapse`.
struct NotchWebPageCache: Equatable {
    static let trust = NotchWebPagePoll.slowInterval
    static let freshness: TimeInterval = 3600
    private(set) var owner: String?
    private(set) var page: NotchWebPage?
    private var confirmed = false
    private var confirmedAt = Date.distantPast
    /// When the confirmation is withdrawn: `trust` after a read first failed to renew it. The media waits for it with
    /// one timer and calls `expire`, since the retries may stop before it.
    private(set) var lapse: Date?
    /// The video the last read found nothing to name in, so a closed surface's read skips its text.
    private var missed: String?

    /// The page to show, nil until confirmed.
    var shown: NotchWebPage? { confirmed ? page : nil }
    /// The video a read for a closed surface only checks the tab still shows: the one read, or one that named nothing.
    var known: String? { page?.content ?? missed }

    /// Follows the track and tab the reads are for; returns whether they changed. A change or a lock drops the page.
    mutating func follow(owner: String?, locked: Bool) -> Bool {
        let changed = owner != self.owner
        if changed || locked { self = NotchWebPageCache() }
        self.owner = owner
        return changed
    }

    /// A round of reads starts anew, as when the open player shows again or a track starts.
    mutating func begin(now: Date) {
        let age = now.timeIntervalSince(confirmedAt)
        if age > Self.freshness { (page, missed) = (nil, nil) }
        if age > Self.trust { confirmed = false }
    }

    mutating func land(_ outcome: NotchWebPagePoll.Outcome, now: Date) {
        switch outcome {
        case .read(var read):
            // A read without the heading, as Netflix's player with its controls hidden, keeps the name of the same video.
            if read.title == nil, let page, page.content == read.content { (read.title, read.subtitle) = (page.title, page.subtitle) }
            (page, missed) = (read, nil)
            confirm(now)
        case .empty(let content):
            // The page read before stays while the tab shows its video, as while Netflix's controls are hidden.
            missed = content
            if page?.content == content { confirm(now) } else { (page, confirmed) = (nil, false) }
        case .unchanged(let content):
            if page?.content == content { confirm(now) }
        case .unavailable:
            (page, confirmed, missed) = (nil, false, nil)
        case .failed:
            if confirmed, lapse == nil { lapse = now.addingTimeInterval(Self.trust) }
            expire(now: now)
        }
    }

    /// Withdraws the confirmation once its lapse passed.
    mutating func expire(now: Date) {
        guard let lapse, now >= lapse else { return }
        (confirmed, self.lapse) = (false, nil)
    }

    private mutating func confirm(_ now: Date) {
        (confirmed, confirmedAt, lapse) = (true, now, nil)
    }
}

/// How the open player presents the playing track, decided apart from the view so it can be checked.
struct NotchPlayerPresentation: Equatable {
    enum Progress: Equatable {
        /// MediaRemote's own times; the bar seeks unless the site breaks on a seek it did not start.
        case player(duration: TimeInterval, seekable: Bool)
        /// The page's video position; shown only, since a seek would bypass the site's own player.
        case page(NotchWebPage.Progress)
        /// No times known for browser video: the row is hidden rather than showing placeholders. A player app keeps
        /// its row empty instead (`.player` with no duration), so one reporting the duration a beat after the title
        /// never moves the transport.
        case hidden
    }

    let kind: NotchMediaKind
    let title: String
    let subtitle: String
    /// The artwork is the site's logo, there is none, or the media is generic web media or not known yet: a small
    /// site tile stands in for it and the source badge beside the title, which would show the same logo, is dropped.
    let siteTile: Bool
    /// The reported artwork is the site's logo, as Netflix's, so the tile may show it while the site's icon is unknown.
    let logoArtwork: Bool
    let progress: Progress

    var skips: Bool { kind.skips }

    init(title: String?, artist: String?, duration: TimeInterval?, hasArtwork: Bool, player: String, kind: NotchMediaKind,
         site: NotchWebSite?, page: NotchWebPage?) {
        self.kind = kind
        let siteNamed = site.map { NotchWebPages.generic(title: title, site: $0) } ?? false
        let shownTitle = page?.title ?? title ?? site?.name ?? player
        self.title = shownTitle
        // An empty artist, as Netflix reports, falls through to the website, unless that is already the title.
        let siteName = site.flatMap { $0.name.caseInsensitiveCompare(shownTitle) == .orderedSame ? nil : $0.name }
        subtitle = page?.subtitle ?? artist.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? siteName ?? player
        siteTile = kind == .genericWeb || kind == .pending || siteNamed || (!hasArtwork && site != nil)
        logoArtwork = siteNamed && hasArtwork
        if let duration, duration.isFinite, duration > 0 {
            progress = .player(duration: duration, seekable: !NotchWebPages.seekBreaks(host: site?.host))
        } else if let progress = page?.progress {
            self.progress = .page(progress)
        } else {
            progress = kind == .app ? .player(duration: 0, seekable: false) : .hidden
        }
    }
}

/// What plays, as far as the player's layout goes. Browser media is Netflix or YouTube by its website: Safari's tabs
/// name it, and for other browsers their titles name YouTube (`NotchBrowserTabs`). Everything else in a browser is
/// generic web media, whatever it reports, since MediaRemote, as the adapter exposes it, does not say which commands
/// a page handles.
enum NotchMediaKind: Equatable {
    /// A player app, such as Spotify or Music.
    case app
    /// Netflix: the site tile, and the show and episode its page names.
    case netflix
    /// YouTube or YouTube Music: the video's own title, channel and thumbnail, and the full transport.
    case youTube
    /// Any other browser media: the site's tile or a pictogram, the page's title, and play or pause alone, since a
    /// browser offers next and previous only to pages that handle them.
    case genericWeb
    /// Browser media whose website is still being read, see `NotchMediaKindWait`: an empty tile and play or pause
    /// alone, so neither the controls nor the tile show something the site then takes back.
    case pending

    /// The kind of browser media on the website `host`.
    init(host: String) {
        switch host {
        case "netflix.com": self = .netflix
        case "youtube.com", "music.youtube.com": self = .youTube
        default: self = .genericWeb
        }
    }

    /// Previous and next show only where they can act: not for generic web media, nor until the website is known.
    var skips: Bool { self != .genericWeb && self != .pending }
}

/// How long browser media waits for its website before taking a layout. A new track of a browser waits at most
/// `limit` while its website is read or a quick retry is due (`NotchWebLookup.quickDelays`), meanwhile keeping the
/// kind its player's previous track settled on, so YouTube's next video keeps its controls, or `.pending` for a
/// player's first track. Netflix is never kept: its tracks are all "Netflix", so a new title is another site's. A
/// website found decides at once; reads ending without one, or the limit passing, make it generic web media.
struct NotchMediaKindWait: Equatable {
    static let limit: TimeInterval = 3.5
    /// The browser track followed, as its player and title; nil for anything else.
    private(set) var track: String?
    private var player: String?
    /// The kind the player's latest track settled on.
    private var held: NotchMediaKind?
    /// While set, the track waits for its website until then.
    private(set) var deadline: Date?

    /// Follows the playing browser track, nil for anything else; a new one starts waiting.
    mutating func follow(player: String?, title: String?, now: Date) {
        if player != self.player {
            self.player = player
            held = nil
        }
        let track = player.map { "\($0)|\(title ?? "")" }
        guard track != self.track else { return }
        self.track = track
        deadline = track == nil ? nil : now + Self.limit
    }

    /// The track's kind, given the host its website was found on and whether a read for it is still under way.
    mutating func kind(host: String?, reading: Bool, now: Date) -> NotchMediaKind {
        if let deadline, host == nil, reading, now < deadline { return held == .netflix ? .pending : held ?? .pending }
        let kind = host.map(NotchMediaKind.init(host:)) ?? .genericWeb
        deadline = nil
        held = kind
        return kind
    }
}

enum NotchWebPages {
    /// The track's title says no more than the site's name, as Netflix's "Netflix", so its artwork is the site's
    /// logo too.
    static func generic(title: String?, site: NotchWebSite) -> Bool {
        let plain = NotchWebSites.plainTitle(title ?? "")
        return plain.isEmpty || plain.caseInsensitiveCompare(site.name) == .orderedSame
    }

    /// Whether a read of the Netflix player tab shows the video Safari last reported still playing, for following
    /// Safari beside the system's player, or nil when that cannot be told. With JavaScript the page's video says.
    /// Without it, as when Safari refuses JavaScript from Apple Events, the tab's text only shows which video is open:
    /// the tab still at `watched`, the video read last, plays while Safari is `sounding` (Core Audio hears it), but
    /// not while Safari is also `capturing` input, as on a call, whose sound would be heard paused or playing. One tab
    /// or none, or another video, is not playing; a failed read cannot tell.
    static func netflixPlays(_ outcome: NotchWebPagePoll.Outcome, watched: String?, sounding: Bool,
                             capturing: Bool) -> Bool? {
        let content: String
        switch outcome {
        case .read(let page):
            if let progress = page.progress { return progress.playing }
            content = page.content
        case .empty(let shown), .unchanged(let shown): content = shown
        case .unavailable: return false
        case .failed: return nil
        }
        guard watched == content else { return false }
        return capturing ? nil : sounding
    }

    /// Whether a read of another site's video tab shows it playing, for following Safari beside the system's player:
    /// only the video's own state tells, so nil when the page gave none, as when Safari refuses JavaScript.
    static func videoPlays(_ outcome: NotchWebPagePoll.Outcome) -> Bool? {
        if case .read(let page) = outcome { page.progress?.playing } else { nil }
    }

    /// Sites whose player fails on a seek that skips its own controls: Netflix stops with an error when the video
    /// element's time is set directly, which is what a MediaRemote seek does.
    static func seekBreaks(host: String?) -> Bool { host == "netflix.com" }

    /// Reads the page once. `known` is the video the caller already has: while the tab still shows it, only the
    /// address is compared. Without `javaScript` only the tab's text is read, so only for Netflix. Only runs when
    /// Eclipse may already automate Safari: a read follows the player being on screen or a track starting, not a
    /// press, so it never shows the Automation prompt itself.
    static func read(_ request: NotchWebPageRequest, known: String?, javaScript: Bool) async -> NotchWebPagePoll.Outcome {
        guard javaScript || request.text else { return .unavailable }
        let wanted = !javaScript ? "text" : request.text ? "both" : "js"
        let result = await NotchWebSites.osascript(script, arguments: [request.address, request.prefix ? "prefix" : "exact",
                                                                       pageScript, wanted, known ?? ""],
                                                   automating: NotchWebSites.safari, prompting: false)
        guard result.status == 0 else {
            let lasting = [errAEEventNotPermitted, errAEEventWouldRequireUserConsent, procNotFound].contains(Int(result.status))
            return lasting ? .unavailable : .failed
        }
        return outcome(of: result.output, for: request)
    }

    /// What `script` printed: a kind, the tab's address and what was read. `same` when the tab still shows the
    /// known video, `js` and the page script's JSON, `text` and the tab's visible text; `missing`, `ambiguous` or
    /// `off` when nothing could be read.
    static func outcome(of reply: String, for request: NotchWebPageRequest, now: Date = .now) -> NotchWebPagePoll.Outcome {
        let parts = reply.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let content = request.content(of: parts[1]) else { return .unavailable }
        let body = parts.count > 2 ? parts[2] : ""
        var page: NotchWebPage
        switch parts[0] {
        case "same": return .unchanged(content: content)
        case "js":
            // Netflix, the one site read by its text too, is named by its heading only.
            guard let read = NotchWebPage.parse(script: body, expected: request.expected, session: !request.text, now: now)
            else { return .unavailable }
            page = read
        case "text": page = NotchWebPage.parse(netflixText: body) ?? NotchWebPage()
        default: return .unavailable
        }
        guard page.title != nil || page.progress != nil else { return .empty(content: content) }
        page.content = content
        return .read(page)
    }

    /// Finds the one tab at the address, or starting with it for `prefix`, reading each window's addresses at once, and
    /// prints `same` when it still shows the known video, else `js` and `pageScript`'s reply, or, when Safari refuses
    /// JavaScript or none is wanted, `text` and the tab's visible text. Each with the tab's address, which must not
    /// change during the read. Arguments: the address, `prefix` or `exact`, the page script, `js`, `text` or `both`,
    /// and the known video or "". Two matching tabs are `ambiguous`, since which one plays is unknown. Nothing is
    /// brought forward.
    private static let script = """
        on run argv
            set {target, matching, pageScript, wanted, known} to argv
            tell application "Safari"
                set matches to 0
                repeat with w in (get windows)
                    set addresses to {}
                    try
                        set addresses to URL of every tab of w
                    end try
                    repeat with k from 1 to count of addresses
                        set tabAddress to ""
                        try
                            set tabAddress to (item k of addresses) as text
                        end try
                        if tabAddress is target or (matching is "prefix" and tabAddress starts with target) then
                            set matches to matches + 1
                            set found to tab k of w
                            set foundAddress to tabAddress
                        end if
                    end repeat
                end repeat
                if matches is 0 then return "missing"
                if matches > 1 then return "ambiguous"
                if known is not "" and (foundAddress is known or foundAddress starts with (known & "?") ¬
                    or foundAddress starts with (known & "#")) then return "same" & linefeed & foundAddress
                set reply to ""
                if wanted is not "text" then
                    try
                        set reply to "js" & linefeed & foundAddress & linefeed & (do JavaScript pageScript in found)
                    end try
                end if
                if reply is "" then
                    if wanted is "js" then return "off"
                    set reply to "text" & linefeed & foundAddress & linefeed & (text of found)
                end if
                if ((URL of found) as text) is not foundAddress then return "missing"
                return reply
            end tell
        end run
        """

    /// Reads, without changing anything: the media session's title and artist, the page's title, Netflix's title
    /// heading (`[data-uia="video-title"]`: the show in an `h4`, then a `span` each for the episode and its name),
    /// and the time of the page's main video, the playing one or else the largest.
    static let pageScript = """
        (function () {
          try {
            var out = {};
            var meta = navigator.mediaSession && navigator.mediaSession.metadata;
            if (meta) { out.sessionTitle = meta.title || ''; out.sessionArtist = meta.artist || ''; }
            out.documentTitle = document.title;
            var heading = document.querySelector('[data-uia="video-title"]');
            if (heading) {
              var parts = Array.prototype.map.call(heading.children, function (e) { return e.textContent.trim(); });
              out.heading = parts.length ? parts : [heading.textContent.trim()];
            }
            var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
            var video = videos.filter(function (v) { return !v.paused; })[0] || videos.sort(function (a, b) {
              return b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight; })[0];
            if (video) { out.time = video.currentTime; out.duration = video.duration; out.paused = video.paused; }
            return JSON.stringify(out);
          } catch (e) { return '{}'; }
        })()
        """
}
