import AppKit
import ApplicationServices

/// A toggle button in a browser's web content as Accessibility reports it. WebKit and Gecko both expose a button with
/// `aria-pressed`, as YouTube's like, as `AXCheckBox` with the `AXToggle` subrole and the pressed state as `AXValue`
/// 0 or 1, and its `aria-label` as `AXDescription`. WebKit also gives the element's `class` and `id` as
/// `AXDOMClassList` and `AXDOMIdentifier`; Gecko gives only the id.
struct NotchAXToggle: Equatable {
    var description: String
    var classes: [String] = []
    var pressed: Bool?
    var enabled = true
    /// The nearest exposed ancestor's classes and id; elements without a role of their own, such as YouTube's custom
    /// elements, are skipped by Accessibility.
    var parentClasses: [String] = []
    var parentIdentifier: String?
    /// Which of the page's searches found it; each search lists its finds in document order.
    var search = 0
}

/// Which YouTube like a press without JavaScript may reach, decided apart from Accessibility so the rules can be
/// checked against the trees WebKit and Gecko build (observed 7 October 2026 for YouTube's current markup).
enum NotchYouTubeAX {
    /// Which of the browser's web areas shows the video. Safari and Zen expose only each window's selected tab, and
    /// only windows on the current Space, so a match is the selected tab of a window that can be seen.
    enum Match: Equatable {
        case found(Int)
        /// No visible selected tab has the address, or more than one has it.
        case unreachable
        /// The tab now names another video.
        case changed
    }

    /// The one web area at the page's address, whose title, made plain as the tab lookup does, is the track's. Zen
    /// names no page (nil): there the one web area on a YouTube video counts, and one naming another video may be a
    /// tab in front of the playing one, so it is out of reach rather than changed.
    static func match(_ areas: [(url: String?, title: String?)], page: URL?, title: String) -> Match {
        let matching = areas.indices.filter { index in
            guard let url = areas[index].url else { return false }
            return page.map { url == $0.absoluteString } ?? URL(string: url).map(supports) ?? false
        }
        guard matching.count == 1, let index = matching.first else { return .unreachable }
        let expected = NotchWebSites.plainTitle(title)
        guard !expected.isEmpty, NotchWebSites.plainTitle(areas[index].title ?? "") == expected else {
            return page == nil ? .unreachable : .changed
        }
        return .found(index)
    }

    /// How the like's label starts, plain and lowercased, in English and Romanian: YouTube's, then YouTube Music's.
    static let videoLabels = ["like this video", "apreciaza acest videoclip", "apreciaza videoclipul"]
    static let musicLabels = ["like", "imi place"]
    /// A word of each label, for Gecko's search by accessible name, which ignores case but not diacritics.
    static let searchWords = ["like", "videoclip", "place"]

    /// How any like's label starts, the video's or a comment's, plain and lowercased.
    static let anyLikeLabels = ["like", "apreciaz", "imi place"]
    /// Parts of the classes or id of a container that holds only the video's actions, lowercased.
    static let actionMarkers = ["watch-metadata", "watchmetadata", "likedislike", "top-level-buttons", "segmented-like-button"]

    /// Only a watch page has one like for one video; Shorts and feeds hold a like per video.
    static func supports(_ page: URL) -> Bool {
        guard let host = NotchWebSites.host(of: page) else { return false }
        return (host == "youtube.com" || host == "music.youtube.com") && page.path == "/watch"
    }

    /// The like toggle among the page's toggles, in document order, or nil when none or more than one could be it.
    /// YouTube: the start of the like and dislike pair, by its class, else the old `#segmented-like-button`, else by
    /// its English or Romanian label. YouTube Music: the toggle in `#button-shape-like`, else by label; its player
    /// page and player bar both show the current song's like, so several are fine while they agree.
    static func likeButton(in toggles: [NotchAXToggle], music: Bool) -> Int? {
        let usable = toggles.indices.filter { toggles[$0].enabled && toggles[$0].pressed != nil }
        func labelled(_ prefixes: [String]) -> [Int] {
            usable.filter { index in
                let label = toggles[index].description.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                return prefixes.contains { label.hasPrefix($0) }
            }
        }
        if music {
            let rules = [usable.filter { toggles[$0].parentIdentifier == "button-shape-like" }, labelled(musicLabels)
                .filter { toggles[$0].description.count <= 12 }]
            for candidates in rules where !candidates.isEmpty {
                return Set(candidates.map { toggles[$0].pressed }).count == 1 ? candidates[0] : nil
            }
            return nil
        }
        let segmented = usable.filter { toggles[$0].classes.contains("yt-spec-button-shape-next--segmented-start") }
        let paired = segmented.filter { index in
            toggles[index].parentClasses.contains { $0.localizedCaseInsensitiveContains("LikeDislike") }
        }
        let rules = [paired, segmented, usable.filter { toggles[$0].parentIdentifier == "segmented-like-button" },
                 labelled(videoLabels)]
        for candidates in rules where !candidates.isEmpty {
            return candidates.count == 1 ? candidates[0] : nil
        }
        return nil
    }

    /// Whether the like at `index` is the video's own, in the actions under the player rather than the comments, by
    /// its exposed ancestors up to the web area, nearest first: none belongs to the comments, and one holds the
    /// video's actions or no other like comes before it in document order, as comments follow the video. YouTube
    /// Music has no comments and its rule takes only copies of the playing song's like, so the comments rule is enough.
    static func inActionBar(_ index: Int, of toggles: [NotchAXToggle], ancestry: [(identifier: String?, classes: [String])],
                            music: Bool) -> Bool {
        let names = ancestry.flatMap { [$0.identifier ?? ""] + $0.classes }.map { $0.lowercased() }
        guard !names.contains(where: { $0.contains("comment") }) else { return false }
        if music || names.contains(where: { name in actionMarkers.contains { name.contains($0) } }) { return true }
        return !toggles[..<index].contains { toggle in
            let label = toggle.description.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return toggle.search == toggles[index].search && anyLikeLabels.contains { label.hasPrefix($0) }
        }
    }
}

/// A browser whose YouTube like Accessibility may press.
enum NotchAXBrowser {
    /// Pressed only when Safari refuses JavaScript from Apple Events, at the tab address the tab lookup found.
    case safari
    /// Zen (Gecko) has no AppleScript, so Accessibility is its only way, and its selected tab is found by address.
    case zen

    var bundle: String {
        switch self {
        case .safari: NotchWebSites.safari
        case .zen: "app.zen-browser.zen"
        }
    }
}

/// Reads and presses YouTube's like through Accessibility, in Safari when it refuses JavaScript from Apple Events and
/// always in Zen. Eclipse already holds the Accessibility permission for the media keys. It touches only the one
/// selected tab of a window on the current Space on a YouTube video, at the page's address in Safari, naming the
/// track, presses only a like among the video's actions, never a comment's, and presses nothing when that tab is no
/// longer the one visible match just before the press. Never brings the browser or a tab forward.
enum NotchBrowserLike {
    /// `page` is the address Safari's tab lookup found; Zen has none.
    static func run(_ browser: NotchAXBrowser, page: URL?, title: String, toggle: Bool) async -> NotchLikeReply {
        guard page.map(NotchYouTubeAX.supports) ?? true, AXIsProcessTrusted() else { return .unreachable }
        let stop = NotchStopFlag()
        return await withTaskCancellationHandler {
            await Task.detached { () -> NotchLikeReply in
                var session = NotchAXSession(stop: stop)
                let reply = perform(browser, page: page, title: title, toggle: toggle, session: &session)
                // A lookup cut short by cancellation or its allowance proves nothing, so it presses nothing either.
                return session.exhausted ? .failed : reply
            }.value
        } onCancel: {
            stop.set()
        }
    }

    private static func perform(_ browser: NotchAXBrowser, page: URL?, title: String, toggle: Bool,
                                session: inout NotchAXSession) -> NotchLikeReply {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundle).first
        else { return .missing }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        guard let areas = webAreas(of: app, &session) else { return .unreachable }
        let pages = areas.map { (url: url(of: $0, &session), title: Self.title(of: $0, &session)) }
        guard !session.exhausted else { return .failed }
        let index: Int
        switch NotchYouTubeAX.match(pages, page: page, title: title) {
        case .found(let found): index = found
        case .unreachable: return .unreachable
        case .changed: return .changed
        }
        guard let address = pages[index].url, let video = URL(string: address) else { return .unreachable }
        let area = areas[index]
        // WebKit builds a page's tree on the first request, so a page nothing asked about yet may answer empty once.
        var found = toggles(in: area, browser, &session)
        if found.isEmpty, !session.exhausted {
            usleep(400_000)
            found = toggles(in: area, browser, &session)
        }
        let music = NotchWebSites.host(of: video) == "music.youtube.com"
        guard !session.exhausted else { return .failed }
        guard let like = NotchYouTubeAX.likeButton(in: found.map(\.toggle), music: music),
              let pressed = found[like].toggle.pressed else { return .missing }
        guard toggle else { return .liked(pressed) }
        // The button must still sit in this web area, among the video's actions rather than the comments.
        guard let ancestry = ancestry(of: found[like].element, in: area, &session), !session.exhausted,
              NotchYouTubeAX.inActionBar(like, of: found.map(\.toggle), ancestry: ancestry, music: music)
        else { return session.exhausted ? .failed : .missing }
        // The tab may have moved on, another may be selected, or its window may have left this Space since it was
        // matched: the same web area must again be the one match among the visible ones. Accessibility reads and the
        // press are separate calls to the browser, so nothing makes them atomic; this check runs last, right before
        // the press, to keep the gap to a handful of calls.
        guard let visible = webAreas(of: app, &session) else { return session.exhausted ? .failed : .changed }
        let now = visible.map { (url: url(of: $0, &session), title: Self.title(of: $0, &session)) }
        guard !session.exhausted else { return .failed }
        guard case .found(let again) = NotchYouTubeAX.match(now, page: page, title: title), CFEqual(visible[again], area),
              now[again].url == address
        else { return .changed }
        guard session.allow(found[like].element),
              AXUIElementPerformAction(found[like].element, kAXPressAction as CFString) == .success else { return .failed }
        return .liked(!pressed)
    }

    /// Every top web area of each window, found through the groups and scroll areas that hold them; Zen's split view
    /// shows several tabs at once. Nil when a window holds more than the walk looks through, so no area goes unseen,
    /// or when the session ran out.
    private static func webAreas(of app: AXUIElement, _ session: inout NotchAXSession) -> [AXUIElement]? {
        let containers: Set<String> = ["AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXTabGroup", "AXLayoutArea"]
        var result: [AXUIElement] = []
        for window in elements(app, kAXWindowsAttribute, &session) {
            var queue = [(window, 0)], visited = 0
            while !queue.isEmpty {
                guard visited < 1000, !session.exhausted else { return nil }
                let (element, depth) = queue.removeFirst()
                visited += 1
                let role = string(element, kAXRoleAttribute, &session) ?? ""
                if role == "AXWebArea" { result.append(element); continue }
                guard containers.contains(role), depth < 10 else { continue }
                queue += elements(element, kAXChildrenAttribute, &session).map { ($0, depth + 1) }
            }
        }
        return session.exhausted ? nil : result
    }

    /// The page's toggle buttons that may be the like, in document order per search. WebKit's button search returns
    /// every button, toggles included, in one call. Gecko's leaves toggles out, so Zen searches every element by the
    /// like labels' words instead, a case-insensitive match on the accessible name.
    private static func toggles(in area: AXUIElement, _ browser: NotchAXBrowser,
                                _ session: inout NotchAXSession) -> [(element: AXUIElement, toggle: NotchAXToggle)] {
        let searches: [[String: Any]] = switch browser {
        case .safari: [["AXSearchKey": "AXButtonSearchKey"]]
        case .zen: NotchYouTubeAX.searchWords.map { ["AXSearchKey": "AXAnyTypeSearchKey", "AXSearchText": $0] }
        }
        var buttons: [(element: AXUIElement, search: Int)] = []
        for (number, search) in searches.enumerated() {
            let parameters = search.merging(["AXResultsLimit": 500, "AXDirection": "AXDirectionNext", "AXVisibleOnly": false,
                                             "AXImmediateDescendantsOnly": false]) { $1 }
            var value: AnyObject?
            guard session.allow(area),
                  session.accept(AXUIElementCopyParameterizedAttributeValue(area, "AXUIElementsForSearchPredicate" as CFString,
                                                                            parameters as CFDictionary, &value)),
                  let found = value as? [AXUIElement] else { continue }
            buttons += found.filter { element in !buttons.contains { CFEqual($0.element, element) } }.map { ($0, number) }
        }
        var result: [(element: AXUIElement, toggle: NotchAXToggle)] = []
        for (button, search) in buttons {
            let values = attributes(button, [kAXSubroleAttribute, kAXDescriptionAttribute, "AXDOMClassList", kAXValueAttribute,
                                             kAXEnabledAttribute, kAXParentAttribute], &session)
            guard !session.exhausted else { return [] }
            guard values[0] as? String == "AXToggle" else { continue }
            var toggle = NotchAXToggle(description: values[1] as? String ?? "", search: search)
            toggle.classes = values[2] as? [String] ?? []
            toggle.pressed = (values[3] as? Int).flatMap { $0 == 0 ? false : $0 == 1 ? true : nil }
            toggle.enabled = values[4] as? Bool ?? true
            if let parent = values[5], CFGetTypeID(parent) == AXUIElementGetTypeID() {
                let ancestry = attributes(parent as! AXUIElement, ["AXDOMClassList", "AXDOMIdentifier"], &session)
                toggle.parentClasses = ancestry[0] as? [String] ?? []
                toggle.parentIdentifier = ancestry[1] as? String
            }
            result.append((button, toggle))
        }
        return result
    }

    /// The classes and id of each exposed ancestor of `element` below `area`, nearest first, or nil when it does not
    /// descend from `area` or the session ran out.
    private static func ancestry(of element: AXUIElement, in area: AXUIElement,
                                 _ session: inout NotchAXSession) -> [(identifier: String?, classes: [String])]? {
        var ancestry: [(identifier: String?, classes: [String])] = []
        var parent = attributes(element, [kAXParentAttribute], &session)[0]
        for _ in 0..<64 {
            guard !session.exhausted, let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { return nil }
            let node = next as! AXUIElement
            if CFEqual(node, area) { return ancestry }
            let values = attributes(node, ["AXDOMIdentifier", "AXDOMClassList", kAXParentAttribute], &session)
            ancestry.append((values[0] as? String, values[1] as? [String] ?? []))
            parent = values[2]
        }
        return nil
    }

    private static func attributes(_ element: AXUIElement, _ names: [String],
                                   _ session: inout NotchAXSession) -> [AnyObject?] {
        var values: CFArray?
        guard session.allow(element),
              session.accept(AXUIElementCopyMultipleAttributeValues(element, names as CFArray,
                                                                    AXCopyMultipleAttributeOptions(rawValue: 0), &values)),
              let array = values as? [AnyObject], array.count == names.count else { return names.map { _ in nil } }
        return decode(array, &session)
    }

    /// A batch read's values with each embedded error, an AXValue holding an AXError, read as the request it stands
    /// for: an absent value is nil, any other failure is nil and spends the session.
    static func decode(_ array: [AnyObject], _ session: inout NotchAXSession) -> [AnyObject?] {
        array.map { value in
            guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else { return value }
            var error = AXError.failure
            _ = AXValueGetValue(value as! AXValue, .axError, &error)
            _ = session.accept(error)
            return nil
        }
    }

    private static func string(_ element: AXUIElement, _ name: String, _ session: inout NotchAXSession) -> String? {
        var value: AnyObject?
        guard session.allow(element) else { return nil }
        return session.accept(AXUIElementCopyAttributeValue(element, name as CFString, &value)) ? value as? String : nil
    }

    /// The page's title: WebKit and Gecko put it in the web area's description, and `AXTitle` is read in case a
    /// version does not.
    private static func title(of area: AXUIElement, _ session: inout NotchAXSession) -> String? {
        let description = string(area, kAXDescriptionAttribute, &session) ?? ""
        return description.isEmpty ? string(area, kAXTitleAttribute, &session) : description
    }

    private static func url(of element: AXUIElement, _ session: inout NotchAXSession) -> String? {
        var value: AnyObject?
        guard session.allow(element),
              session.accept(AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value)) else { return nil }
        return (value as? URL)?.absoluteString
    }

    private static func elements(_ element: AXUIElement, _ name: String,
                                 _ session: inout NotchAXSession) -> [AXUIElement] {
        var value: AnyObject?
        guard session.allow(element) else { return [] }
        return session.accept(AXUIElementCopyAttributeValue(element, name as CFString, &value)) ? value as? [AXUIElement] ?? [] : []
    }
}

/// What one like read or press may spend across all its Accessibility requests: the shared allowance from the tab
/// reads, with a longer deadline since a page search and WebKit's first-build pause take a moment, and the
/// task's cancellation, checked before every request. Once it runs out, or a request fails rather than finding no
/// value, the lookup stops and counts as failed, so a timeout never reads as a page without a like.
struct NotchAXSession {
    let stop: NotchStopFlag
    var allowance = NotchAXAllowance(seconds: 3, requests: 4_000)
    private(set) var exhausted = false

    init(stop: NotchStopFlag) { self.stop = stop }

    /// Whether a request's answer can be used: true on success; false when the element has no such value, which is
    /// an answer; false and the session spent on any other error, such as a timeout or a browser that did not reply.
    mutating func accept(_ result: AXError) -> Bool {
        switch result {
        case .success: return true
        case .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported: return false
        default:
            exhausted = true
            return false
        }
    }

    /// Whether one more request to `element` may go out, setting its timeout to at most 1 s and the time left.
    mutating func allow(_ element: AXUIElement) -> Bool {
        guard !exhausted, let left = allowance.spend(cancelled: stop.isSet) else {
            exhausted = true
            return false
        }
        AXUIElementSetMessagingTimeout(element, min(left, 1))
        return true
    }
}

/// Set once a task is cancelled, for work running on a detached thread that checks it between steps.
final class NotchStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}
