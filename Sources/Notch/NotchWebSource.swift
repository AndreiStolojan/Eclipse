import AppKit
import os

/// The website behind browser media, such as YouTube or Netflix.
struct NotchWebSite: Equatable {
    let name: String
    let host: String
    /// The playing tab's address, used to bring that tab forward.
    let url: URL
    var icon: NSImage?
    /// The tab's title names the track, so the tab is known to be the one playing it. A site found only as the one
    /// media site open is shown, but never liked.
    var matchesTrack = false
}

/// Which Safari track the website belongs to. A new title drops the previous site at once, so nothing, such as a
/// like, ever pairs the new track with the old tab; the site comes back only from a lookup for that title. While
/// paused, as when the Mac is locked, no lookup starts; the title waiting is looked up once it resumes. A lookup that
/// failed for a reason that may pass leaves the title unresolved. The media asks again at `retryAt`, after each of
/// `quickDelays` and then `retryDelays` in turn, and then stops, so a lasting failure does not run scripts all through
/// playback; an explicit ask, such as opening the Music page or unlocking, still tries once more, at most
/// `retryDelays[0]` after the last failure.
struct NotchWebLookup: Equatable {
    /// YouTube retitles its tab within about a second of playing the next video in place, so a track no tab names
    /// yet is asked again about 0.5, 1.5 and 3 s on before the slower `retryDelays`.
    static let quickDelays: [TimeInterval] = [0.5, 1, 1.5]
    static let retryDelays: [TimeInterval] = [5, 15, 45]
    private static let delays = quickDelays + retryDelays
    /// The Safari track's title, or nil for any other source.
    private(set) var title: String?
    private(set) var site: NotchWebSite?
    /// The title a lookup is under way for.
    private(set) var asked: String?
    private var resolved = false
    /// Lookups for the title that failed or found only an unmatched tab, and when the last one did.
    private var failures = 0
    private var failedAt: Date?
    var paused = false

    /// Follows the playing track's title, nil outside Safari. Returns the title to look up now, if any. `explicit`
    /// marks an ask the user caused rather than a metadata update, which may retry past the automatic budget.
    mutating func follow(_ title: String?, explicit: Bool = false, now: Date = .now) -> String? {
        if title != self.title {
            self.title = title
            site = nil
            asked = nil
            resolved = false
            failures = 0
            failedAt = nil
        }
        guard let title, !resolved, !paused, asked == nil else { return nil }
        if let failedAt {
            // Each automatic retry waits longer, and past the budget none comes; an explicit one waits the least.
            let automatic = automaticDelay
            let wait = explicit ? min(automatic ?? Self.retryDelays[0], Self.retryDelays[0]) : automatic
            guard let wait, now >= failedAt + wait else { return nil }
        }
        asked = title
        return title
    }

    /// When `follow` next allows an automatic retry, nil when none is due: resolved, under way, paused or past the
    /// budget.
    var retryAt: Date? {
        guard title != nil, !resolved, !paused, asked == nil, let failedAt, let wait = automaticDelay else { return nil }
        return failedAt + wait
    }

    private var automaticDelay: TimeInterval? {
        failures >= 1 && failures <= Self.delays.count ? Self.delays[failures - 1] : nil
    }

    /// A lookup's result; one for a title no longer playing is dropped. Returns whether it landed. A site found only
    /// as the one media site open is kept for display and asked again like a failure, since the tab's title may name
    /// the track once the page catches up, as when the next video plays in the same tab.
    mutating func finish(_ site: NotchWebSite?, for title: String, now: Date = .now) -> Bool {
        guard title == self.title, title == asked else { return false }
        self.site = site
        asked = nil
        resolved = site?.matchesTrack != false
        if !resolved { failed(at: now) }
        return true
    }

    /// The lookup for `title` failed for a reason that may pass, such as running out of time while Safari was busy.
    /// The title stays unresolved and is asked again as `follow` allows.
    mutating func fail(for title: String, now: Date = .now) {
        guard title == self.title, title == asked else { return }
        asked = nil
        failed(at: now)
    }

    private mutating func failed(at now: Date) {
        failures += 1
        failedAt = now
    }

    /// The lookup under way stopped without a result, so the title is looked up again on the next `follow`.
    mutating func abandon() { asked = nil }

    /// Gives the found site its icon, fetched after the site was shown. Returns whether the site is still the one
    /// on `host`.
    mutating func attach(_ icon: NSImage, host: String) -> Bool {
        guard site?.url.host() == host else { return false }
        site?.icon = icon
        return true
    }
}

extension NotchWebSites.NetflixHeading {
    /// The heading a Netflix page read named, nil for a page without one or read off a player.
    init?(_ page: NotchWebPage) {
        guard let title = page.title, let path = URL(string: page.content)?.path(), path.hasPrefix("/watch/") else { return nil }
        self.init(title: title, path: path)
    }
}

/// A script stopped without an answer for a reason that may pass: cancelled, out of time, or failed in the app; or
/// its answer did not settle the question yet, as several media tabs and none titled like the track.
struct NotchScriptFailure: Error {
    let message: String
}

/// MediaRemote names only the browser, so Safari's tabs are read through Apple Events. macOS asks once for the
/// Automation permission. The tab whose title contains the track title wins; otherwise the one known media site
/// open, shown but not trusted for a like. See `pick`.
enum NotchWebSites {
    struct Tab: Equatable {
        let url: URL
        let title: String
    }

    /// Which tab plays the track, as `pick` finds it.
    enum Pick: Equatable {
        /// The tab's title names the track, or for Netflix, the track is "Netflix" or the show its player names.
        case named(Tab)
        /// No title names the track and this is the only known media site open, so it is shown but never liked.
        case only(Tab)
        /// No title names the track yet and several media sites are open, or the evidence competes: the site is
        /// unknown, never guessed.
        case ambiguous
        /// No title names the track and the one Netflix player's heading is not known: read it, then pick again.
        case readNetflix(Tab)
    }

    /// The show Netflix's page named (`NotchWebPage`), bound to the player address it was read on, `/watch/<id>`.
    /// Evidence only while the one Netflix player tab still shows that video.
    struct NetflixHeading: Equatable {
        let title: String
        let path: String
    }

    /// Hosts without `www.`; anything else is shown by its host name.
    private static let names = [
        "youtube.com": "YouTube", "music.youtube.com": "YouTube Music", "netflix.com": "Netflix",
        "open.spotify.com": "Spotify", "music.apple.com": "Apple Music", "tv.apple.com": "Apple TV",
        "twitch.tv": "Twitch", "primevideo.com": "Prime Video", "disneyplus.com": "Disney+", "max.com": "Max",
        "soundcloud.com": "SoundCloud", "vimeo.com": "Vimeo"
    ]

    static func host(of url: URL) -> String? {
        guard var host = url.host()?.lowercased() else { return nil }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        return host
    }

    static func name(forHost host: String) -> String { names[host] ?? host }

    /// A title as plain text, for comparing a track with a page: Unicode composed, spaces collapsed and trimmed,
    /// without YouTube's unread count or " - YouTube" suffix. `plainTitleScript` is the same rule for the page.
    static func plainTitle(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
            .replacing(#/^\(\d+\) /#, with: "").replacing(#/ - YouTube( Music)?$/#, with: "")
    }

    /// `plainTitle` as a JavaScript function named `plain`, for scripts run in the page. Keep the two in step.
    static let plainTitleScript = """
        function plain(text) {
          return String(text || '').normalize('NFC').replace(/\\s+/g, ' ').trim()
            .replace(/^\\(\\d+\\) /, '').replace(/ - YouTube( Music)?$/, '');
        }
        """

    /// The tab playing the track, nil when no tab could be: none is titled like it, no Netflix player is open and no
    /// known media site is. Both titles are compared plain, as the like script compares them. A tab titled exactly
    /// like the track wins. Netflix names every video "Netflix" in its tab and its media session, so a Netflix tab is
    /// taken only on evidence: the track being "Netflix", or `netflixHeading` naming it while bound to the one player
    /// tab's video and no other tab's title naming it too; both naming it is `.ambiguous`. A Netflix player whose
    /// heading is unknown, and no tab titled like the track, is `.readNetflix`; one whose heading names another show
    /// is still `.ambiguous`, never a fallback. Without a Netflix player and a tab titled like the track, as for the
    /// moment YouTube plays the next video before retitling its tab, a fallback is shown only when all other known
    /// media tabs are on one site; with several sites open the answer is `.ambiguous`.
    static func pick(_ tabs: [Tab], trackTitle: String?, netflixHeading: NetflixHeading? = nil) -> Pick? {
        let title = plainTitle(trackTitle ?? "")
        let isNetflix = { (tab: Tab) in host(of: tab.url) == "netflix.com" }
        let players = tabs.filter { isNetflix($0) && $0.url.path().hasPrefix("/watch/") }
        if !title.isEmpty, title.caseInsensitiveCompare("Netflix") == .orderedSame,
           let tab = players.first ?? tabs.first(where: isNetflix) {
            return .named(tab)
        }
        let others = tabs.filter { !isNetflix($0) }
        let matching = title.isEmpty ? [] : others.filter { plainTitle($0.title).localizedCaseInsensitiveContains(title) }
        if let exact = matching.first(where: { plainTitle($0.title).localizedCaseInsensitiveCompare(title) == .orderedSame }) {
            return .named(exact)
        }
        if let player = players.first {
            let single = players.count == 1
            let heading = netflixHeading.flatMap { single && $0.path == player.url.path() ? plainTitle($0.title) : nil }
            let named = heading.map { !title.isEmpty && $0.caseInsensitiveCompare(title) == .orderedSame }
            if named == true { return matching.isEmpty ? .named(player) : .ambiguous }
            if matching.isEmpty { return named == nil && single ? .readNetflix(player) : .ambiguous }
        }
        if let match = matching.first { return .named(match) }
        let media = others.filter { host(of: $0.url).map { names[$0] != nil } ?? false }
        guard let first = media.first else { return nil }
        return Set(media.compactMap { host(of: $0.url) }).count == 1 ? .only(first) : .ambiguous
    }

    /// Parses the AppleScript output: one `URL<tab>title` line per tab.
    static func parse(_ output: String) -> [Tab] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, let url = URL(string: String(first)), url.host() != nil else { return nil }
            return Tab(url: url, title: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// The separator is set outside the `tell` block: inside it, `tab` means Safari's tab class, not a tab character.
    private static let script = """
        set separator to character id 9
        tell application "Safari"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set output to output & (URL of t) & separator & (name of t) & linefeed
                    end try
                end repeat
            end repeat
            return output
        end tell
        """
    private static let log = Logger(subsystem: "ro.andrei.NotchLab", category: "web-source")
    @MainActor private static var icons: [String: NSImage] = [:]

    /// Finds the site playing in Safari, or nil when Safari is closed, permission is denied or nothing matches.
    /// Throws when the tabs could not be read this time, or several sites could be playing the track, as when a Netflix
    /// player's heading cannot be read or names another show, so the title is asked again later. The site comes with
    /// its icon only when that is already known; otherwise `icon(for:)` fetches it after the site is shown.
    @MainActor
    static func resolveSafari(trackTitle: String?, netflixHeading: NetflixHeading?) async throws -> NotchWebSite? {
        // A background lookup: it never asks for Automation, so an undecided permission reads no tabs.
        guard let tabs = await safariTabs(prompting: false) else { throw NotchScriptFailure(message: "Safari's tabs could not be read") }
        var picked = pick(tabs, trackTitle: trackTitle, netflixHeading: netflixHeading)
        if case .readNetflix(let player) = picked {
            // The player's heading, read once from its text without a prompt, bootstraps the Netflix evidence.
            let heading = await readNetflixHeading(player)
            picked = heading.map { pick(tabs, trackTitle: trackTitle, netflixHeading: $0) } ?? .ambiguous
        }
        let tab: Tab, matchesTrack: Bool
        switch picked {
        case nil: return nil
        case .named(let named): (tab, matchesTrack) = (named, true)
        case .only(let only): (tab, matchesTrack) = (only, false)
        case .ambiguous, .readNetflix: throw NotchScriptFailure(message: "No tab is titled like the track yet")
        }
        guard let host = host(of: tab.url), let fullHost = tab.url.host() else { return nil }
        return NotchWebSite(name: name(forHost: host), host: host, url: tab.url, icon: icons[fullHost],
                            matchesTrack: matchesTrack)
    }

    /// The show the Netflix player tab names in its text (at most 5 s, never prompting), bound to the
    /// video it was read on; nil when its controls are hidden, so no heading shows, or the read failed.
    @MainActor
    private static func readNetflixHeading(_ player: Tab) async -> NetflixHeading? {
        let site = NotchWebSite(name: "Netflix", host: "netflix.com", url: player.url)
        guard let request = NotchWebPageRequest(site: site, title: nil, durationKnown: false),
              case .read(let page) = await NotchWebPages.read(request, known: nil, javaScript: false) else { return nil }
        return NetflixHeading(page)
    }

    /// Safari's tabs; none when Safari is closed or automating it is denied, or, without `prompting` (the default, as
    /// every caller reads in the background), not decided yet. Nil when they could not be read this time.
    static func safariTabs(prompting: Bool = false) async -> [Tab]? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: safari).isEmpty else { return [] }
        let result = await osascript(script, automating: safari, prompting: prompting)
        // Denied, or Safari quit since it was seen running: no tabs, as when it is closed.
        let lasting = [errAEEventNotPermitted, errAEEventWouldRequireUserConsent, procNotFound].contains(Int(result.status))
        guard result.status == 0 || lasting else {
            log.error("Reading Safari tabs failed: \(result.error, privacy: .public)")
            return nil
        }
        return lasting ? [] : parse(result.output)
    }

    /// Selects the tab showing `url` in its window, raises that window and brings Safari forward.
    /// The address is passed as an argument, never spliced into the script.
    private static let showTabScript = """
        on run argv
            set target to item 1 of argv
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is target then
                            set current tab of w to t
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
                activate
            end tell
        end run
        """

    static func showSafariTab(_ url: URL) {
        Task {
            let result = await osascript(showTabScript, arguments: [url.absoluteString], automating: safari)
            if result.status != 0 { log.error("Showing the Safari tab failed: \(result.error, privacy: .public)") }
        }
    }

    static let safari = "com.apple.Safari"
    /// Browsers besides Safari, by bundle identifier, whose media is web media too. Their tabs are only read for
    /// YouTube (`NotchBrowserTabs`), so their media never names another website.
    static let browsers: Set<String> = [
        "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "org.chromium.Chromium", "company.thebrowser.Browser", "company.thebrowser.dia", "com.microsoft.edgemac",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen", "com.kagi.kagimacOS"
    ]
    /// How long a script may wait while macOS shows the Automation prompt, so the answer is not cut off.
    static let promptTimeout: TimeInterval = 60

    /// Runs a script that sends Apple Events to the app `target`. macOS is first asked, without prompting, whether
    /// Eclipse may automate it. The script runs only when allowed, or when not yet decided, in which case this run
    /// shows the prompt and gets `promptTimeout` instead of the usual 5 s. Otherwise nothing runs and the status is
    /// macOS's answer: `errAEEventNotPermitted` when denied, `procNotFound` when the app quit since the caller saw it
    /// running, since `tell application` would launch it again. Without `prompting`, an undecided permission is
    /// answered `errAEEventWouldRequireUserConsent` and nothing runs, for reads no press asked for.
    static func osascript(_ source: String, arguments: [String] = [], automating target: String,
                          prompting: Bool = true) async -> (status: Int32, output: String, error: String) {
        let permission = automation(of: target)
        if let timeout = scriptTimeout(permission: permission, prompting: prompting) {
            return await osascript(source, arguments: arguments, timeout: timeout)
        }
        let reason = switch Int(permission) {
        case errAEEventWouldRequireUserConsent: "Automating \(target) is not decided yet"
        case errAEEventNotPermitted: "Not permitted to automate \(target)"
        case procNotFound: "\(target) is not running"
        default: "Cannot automate \(target): \(permission)"
        }
        return (permission, "", reason)
    }

    /// How long a script may run given macOS's Automation answer, nil when it must not run: denied, the app not
    /// running, or not yet decided and `prompting` is off, so nothing shows the prompt.
    static func scriptTimeout(permission: OSStatus, prompting: Bool) -> TimeInterval? {
        switch Int(permission) {
        case Int(noErr): 5
        case errAEEventWouldRequireUserConsent: prompting ? promptTimeout : nil
        default: nil
        }
    }

    /// Whether Eclipse may automate the app `target`, asked without prompting: `noErr` when allowed, else as for
    /// `osascript(_:arguments:automating:prompting:)`.
    static func automation(of target: String) -> OSStatus {
        let address = NSAppleEventDescriptor(bundleIdentifier: target)
        return AEDeterminePermissionToAutomateTarget(address.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
    }

    /// Runs a script with `osascript` off the main thread, so a slow first permission prompt never blocks the notch.
    /// Arguments reach the script's `run` handler; nothing is spliced into its source. Nothing launches once the task
    /// is cancelled; cancelling it or `timeout` passing terminates the script, so no Apple Events outlive the read.
    static func osascript(_ source: String, arguments: [String] = [],
                          timeout: TimeInterval = 5) async -> (status: Int32, output: String, error: String) {
        let script = NotchScript(source: source, arguments: arguments)
        return await withTaskCancellationHandler {
            await Task.detached { script.run(timeout: timeout) }.value
        } onCancel: {
            script.cancel()
        }
    }

    /// The site's own favicon, fetched once per host from that site and cached for the session.
    @MainActor
    static func icon(for host: String) async -> NSImage? {
        if let cached = icons[host] { return cached }
        guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 5)
        guard let (data, _) = try? await URLSession.shared.data(for: request), let image = NSImage(data: data) else { return nil }
        icons[host] = image
        return image
    }
}

/// One `osascript` run that can be stopped from another thread: before launch it never starts, after it terminates.
private final class NotchScript: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stopped = false

    init(source: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
    }

    /// Blocks until the script exits or is stopped, at the latest `timeout` after it starts.
    func run(timeout: TimeInterval) -> (status: Int32, output: String, error: String) {
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let launched: Result<Void, Error>? = lock.withLock {
            stopped ? nil : Result { try process.run() }
        }
        switch launched {
        case nil: return (-1, "", "Cancelled")
        case .failure(let error): return (-1, "", error.localizedDescription)
        case .success: break
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.cancel() }
        // Reading to the end first keeps a long output from filling the pipe and stalling the script.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let stopped = process.terminationReason == .uncaughtSignal
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), stopped ? "Stopped" : errorText)
    }

    func cancel() {
        lock.withLock {
            stopped = true
            if process.isRunning { process.terminate() }
        }
    }
}
