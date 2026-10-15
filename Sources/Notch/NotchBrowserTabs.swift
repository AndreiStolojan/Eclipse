import AppKit
import ApplicationServices

/// Recognises YouTube playing in a browser other than Safari, whose tabs are otherwise never read. MediaRemote names
/// only the browser, and what YouTube reports does not tell it apart from another page, so the browser's titles are
/// compared with the track's: YouTube titles a watching tab "<video> - YouTube". Chrome and the browsers built on it
/// list every tab's address and title through AppleScript, once Eclipse may automate them; this read never asks.
/// Any other browser, such as Firefox or Zen, and a scriptable one not yet allowed, is read through Accessibility:
/// the Window menu, which lists every window by its front tab even on another Space, the titles of windows on the
/// current Space, and last their tab strips. Exactly one tab or window must carry the track's title.
enum NotchBrowserTabs {
    /// Browsers whose AppleScript dictionary lists tabs with `URL` and `title`.
    static let scriptable: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi"
    ]
    static let youTubeHosts: Set<String> = ["youtube.com", "music.youtube.com"]

    /// The YouTube host a tab or window title names the track on: "youtube.com" for "<track> - YouTube",
    /// "music.youtube.com" for "<track> - YouTube Music". An unread count before it and a window's " — <browser>"
    /// after it are allowed. The rest must equal the track case-insensitively, as it stands: those decorations are
    /// parsed once, so "Intro" never matches "Introduction - YouTube" and a video titled "A - YouTube" never matches
    /// track "A". Nil for anything else.
    static func youTubeHost(title: String, track: String) -> String? {
        func spaced(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
        }
        // The track is what the player reports, taken as it stands: a video may itself be titled "A - YouTube".
        let track = spaced(track), text = spaced(title)
        guard !track.isEmpty, let match = text.wholeMatch(of: #/(?:\(\d+\) )?(.+) - YouTube( Music)?(?: [—–-] .+)?/#),
              String(match.1).localizedCaseInsensitiveCompare(track) == .orderedSame
        else { return nil }
        return match.2 == nil ? "youtube.com" : "music.youtube.com"
    }

    /// The YouTube hosts of the tabs whose address is on YouTube and whose title names the track, parsed as a window
    /// title is, so the two paths agree.
    static func matches(tabs: [NotchWebSites.Tab], track: String) -> [String] {
        tabs.compactMap { tab in
            NotchWebSites.host(of: tab.url).flatMap {
                youTubeHosts.contains($0) && youTubeHost(title: tab.title, track: track) != nil ? $0 : nil
            }
        }
    }

    /// The YouTube hosts of the titles naming the track, one per title.
    static func matches(titles: [String], track: String) -> [String] {
        titles.compactMap { youTubeHost(title: $0, track: track) }
    }

    /// The one host found, nil when nothing names the track. Throws when more than one tab or window does, as the
    /// playing one is unknown: like a failed read it is not remembered.
    static func host(of matches: [String]) throws -> String? {
        guard matches.count <= 1 else { throw NotchScriptFailure(message: "\(matches.count) tabs name the track") }
        return matches.first
    }

    /// Reads the running browser `bundle` and returns the YouTube host playing `track`, nil when nothing names it or
    /// the browser is not running. Throws when nothing could be read this time or the answer is ambiguous. Only ever
    /// reads: no tab is selected, no window raised and no permission prompt shown. One Accessibility read runs at a
    /// time; a new one cancels and waits for the last.
    @MainActor
    static func youTubeHost(bundle: String, track: String) async throws -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        if scriptable.contains(bundle) {
            let result = await NotchWebSites.osascript(script(bundle), automating: bundle, prompting: false)
            if result.status == procNotFound { return nil }
            if result.status == 0 { return try host(of: matches(tabs: NotchWebSites.parse(result.output), track: track)) }
            // Denied, undecided or failed: Accessibility may still see it.
        }
        guard AXIsProcessTrusted() else { throw NotchScriptFailure(message: "No Accessibility access") }
        let pid = app.processIdentifier
        let previous = accessibilityRead
        previous?.cancel()
        let read = Task.detached(priority: .utility) { () -> [String]? in
            _ = await previous?.value
            var reader = NotchAXReader(allowance: NotchAXAllowance())
            return reader.matches(pid: pid, track: track)
        }
        accessibilityRead = read
        let found = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
        if accessibilityRead == read { accessibilityRead = nil }
        guard let found, !Task.isCancelled else { throw NotchScriptFailure(message: "Reading \(bundle) failed") }
        return try host(of: found)
    }

    /// The Accessibility read under way, which the next one waits for.
    @MainActor private static var accessibilityRead: Task<[String]?, Never>?

    /// Lists every tab as `URL<tab>title` lines, as Safari's read does. The identifier comes from `scriptable`, never
    /// from what a player reported.
    private static func script(_ bundle: String) -> String {
        """
        set separator to character id 9
        tell application id "\(bundle)"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set output to output & (URL of t) & separator & (title of t) & linefeed
                    end try
                end repeat
            end repeat
            return output
        end tell
        """
    }
}

/// What one Accessibility lookup may spend across all its requests: one deadline and one request count. Each request
/// waits at most the time left.
struct NotchAXAllowance {
    let deadline: Date
    private(set) var requests: Int

    init(now: Date = .now, seconds: TimeInterval = 0.75, requests: Int = 3_000) {
        deadline = now.addingTimeInterval(seconds)
        self.requests = requests
    }

    /// The timeout for one more request, nil once the lookup is cancelled, out of time or out of requests.
    mutating func spend(now: Date = .now, cancelled: Bool) -> Float? {
        let left = deadline.timeIntervalSince(now)
        guard !cancelled, requests > 0, left > 0 else { return nil }
        requests -= 1
        return Float(left)
    }
}

/// Reads a browser's titles through Accessibility within one allowance, checking cancellation before every request.
/// Web content is never entered.
private struct NotchAXReader {
    var allowance: NotchAXAllowance
    /// Set once a request was refused or failed, or the tree went deeper than read, so the read is incomplete.
    private(set) var stopped = false
    private static let maxDepth = 14

    /// The YouTube hosts the first source naming the track gives, cheapest first: the Window menu, then window
    /// titles, then, only if neither named it and the browser shows a window on this Space, its windows' tab strips.
    /// Nil when the browser could not be read, or the read was cut short.
    ///
    /// The menu and window titles are AppKit's own. A tab strip is the browser's: in Firefox and Zen, asking for it
    /// starts Gecko's accessibility engine, which then stays on in that browser until it quits, costing memory and
    /// some CPU. That cost is paid only for a YouTube-like track no front tab names.
    mutating func matches(pid: pid_t, track: String) -> [String]? {
        let app = AXUIElementCreateApplication(pid)
        let bar: AXUIElement? = value(app, kAXMenuBarAttribute)
        if let bar {
            let menus: [AXUIElement] = value(bar, kAXChildrenAttribute) ?? []
            // The Window menu by name, else where macOS puts it, before Help.
            var window: AXUIElement?
            for menu in menus where (value(menu, kAXTitleAttribute) as String?) == "Window" {
                window = menu
                break
            }
            window = window ?? (menus.count > 2 ? menus[menus.count - 2] : nil)
            let list = window.flatMap { (value($0, kAXChildrenAttribute) as [AXUIElement]?)?.first }
            let items: [AXUIElement] = list.flatMap { value($0, kAXChildrenAttribute) } ?? []
            let found = NotchBrowserTabs.matches(titles: items.compactMap { value($0, kAXTitleAttribute) }, track: track)
            guard !stopped else { return nil }
            if !found.isEmpty { return found }
        }
        let windows: [AXUIElement]? = value(app, kAXWindowsAttribute)
        guard !stopped, bar != nil || windows != nil else { return nil }
        let found = NotchBrowserTabs.matches(titles: (windows ?? []).compactMap { value($0, kAXTitleAttribute) }, track: track)
        guard !stopped else { return nil }
        guard found.isEmpty, let windows, !windows.isEmpty, Self.showsWindow(pid: pid) else { return found }
        var titles: [String] = []
        for window in windows { tabTitles(in: window, depth: 0, into: &titles) }
        guard !stopped else { return nil }
        return NotchBrowserTabs.matches(titles: titles, track: track)
    }

    /// Collects a window's tab titles, which Firefox and Chrome both show as radio buttons of the tab button subrole.
    private mutating func tabTitles(in element: AXUIElement, depth: Int, into titles: inout [String]) {
        guard !stopped else { return }
        // A tree deeper than expected was not read to the end, so the read is incomplete.
        guard depth <= Self.maxDepth else {
            stopped = true
            return
        }
        let role: String? = value(element, kAXRoleAttribute)
        if role == "AXWebArea" { return }
        if role == kAXRadioButtonRole, (value(element, kAXSubroleAttribute) as String?) == "AXTabButton" {
            if let title: String = value(element, kAXTitleAttribute) ?? value(element, kAXDescriptionAttribute) {
                titles.append(title)
            }
            return
        }
        for child in (value(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            tabTitles(in: child, depth: depth + 1, into: &titles)
        }
    }

    /// One attribute, if the allowance still covers a request and the lookup is not cancelled.
    private mutating func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        guard !stopped, let timeout = allowance.spend(cancelled: Task.isCancelled) else {
            stopped = true
            return nil
        }
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .success: return value as? T
        // The element simply has no such value.
        case .noValue, .attributeUnsupported: return nil
        // A timeout or a browser that did not answer: the read is incomplete, so it is not remembered.
        default:
            stopped = true
            return nil
        }
    }

    /// Whether the browser shows a window on the current Space, asked of the window server rather than the browser.
    private static func showsWindow(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
        }
    }
}

/// Which track another browser's titles are read for, and what they named. Each player and title is read once and
/// remembered, so a track coming back costs nothing; a read that failed or found more than one match is not
/// remembered, and is tried again only when asked, as on unlock. While paused, as when the Mac is locked, nothing
/// is read; the track waiting is read after.
struct NotchTabLookup: Equatable {
    static let rememberLimit = 64
    /// The playing track as its player and title, nil for Safari and apps.
    private(set) var key: String?
    /// The read under way.
    private(set) var asked: String?
    private var failed: String?
    /// The YouTube host each track was found on, nil where nothing named it.
    private var found: [String: String?] = [:]
    var paused = false

    /// The YouTube host the playing track was found on.
    var host: String? { key.flatMap { found[$0] ?? nil } }

    /// Follows the playing track. Returns the key to read now, if any. `explicit` retries a read that failed.
    mutating func follow(_ key: String?, explicit: Bool = false) -> String? {
        if key != self.key {
            self.key = key
            asked = nil
        }
        guard let key, !paused, asked == nil, found.index(forKey: key) == nil, explicit || failed != key else { return nil }
        asked = key
        return key
    }

    /// A read's result; one for a track no longer playing is dropped.
    mutating func finish(_ host: String?, for key: String) {
        guard key == asked else { return }
        asked = nil
        if found.count >= Self.rememberLimit { found.removeAll() }
        found[key] = .some(host)
    }

    /// The read for `key` failed for a reason that may pass.
    mutating func fail(for key: String) {
        guard key == asked else { return }
        asked = nil
        failed = key
    }

    /// The read under way stopped without a result, so the track is read again on the next `follow`.
    mutating func abandon() { asked = nil }
}
