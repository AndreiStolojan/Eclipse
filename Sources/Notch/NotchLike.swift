import AppKit
import os

/// Where the player's Like button sends a like for the current track: Apple Music's favourite, Spotify's Liked
/// Songs through its Web API (see `NotchSpotify`), the like button of the YouTube page playing in Safari, or the one
/// in Zen's selected tab, which Accessibility finds on each read since Zen names no page. Other players have none,
/// and Spotify has none until its Client ID is set.
enum NotchLikeTarget: Hashable {
    case music
    case spotify
    case youTube(URL)
    case zen
    case unsupported

    init(bundleIdentifier: String?, page: URL?) {
        if bundleIdentifier == "com.apple.Music" {
            self = .music
        } else if bundleIdentifier == "com.spotify.client", NotchSpotify.configured {
            self = .spotify
        } else if bundleIdentifier == NotchAXBrowser.zen.bundle {
            self = .zen
        } else if bundleIdentifier == "com.apple.Safari", let page,
                  let host = NotchWebSites.host(of: page), host == "youtube.com" || host == "music.youtube.com" {
            self = .youTube(page)
        } else {
            self = .unsupported
        }
    }

    /// The like is a YouTube page's, in Safari or Zen.
    var isYouTube: Bool { browser != nil }

    /// The browser showing the YouTube page.
    var browser: NotchAXBrowser? {
        switch self {
        case .youTube: .safari
        case .zen: .zen
        case .music, .spotify, .unsupported: nil
        }
    }
}

/// What a like script printed: the state after reading or toggling, or why there is none.
enum NotchLikeReply: Equatable {
    case liked(Bool)
    /// No track in Music, or no like button on the page.
    case missing
    /// Music or the YouTube page plays another track than the one asked about, so the script left it alone.
    case changed
    /// Safari refuses `do JavaScript` until "Allow JavaScript from Apple Events" is on in its Develop menu.
    case javaScriptOff
    /// Without JavaScript, the YouTube tab is not one Accessibility may press: not the selected tab of a window on
    /// this Space, in Zen not a YouTube video naming the track, or Eclipse lacks the Accessibility permission.
    case unreachable
    /// Spotify is not signed in, or signing in did not complete.
    case unauthorized
    case failed

    init(status: Int32, output: String, error: String) {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == procNotFound {
            // The player quit before the script could run, so it has no track to like.
            self = .missing
        } else if status != 0 {
            self = error.contains("JavaScript") ? .javaScriptOff : .failed
        } else if text == "true" || text == "false" {
            self = .liked(text == "true")
        } else {
            self = text == "missing" ? .missing : text == "changed" ? .changed : .failed
        }
    }

    /// The like it reports, or nil when it reports none.
    var value: Bool? {
        if case .liked(let value) = self { value } else { nil }
    }
}

/// The track a like is about: where it goes, the adapter's identity for the track (title, artist and album, as the
/// track watch uses it), and the title and artist Music checks before it reads or sets anything.
struct NotchLikeRequest: Hashable {
    let target: NotchLikeTarget
    let track: String
    let title: String
    let artist: String
}

/// The like's bookkeeping apart from the scripts, so its races can be checked. Each read and toggle takes a new
/// generation, and so does every change of what is in view; a read's reply lands only if nothing came since, and a
/// toggle's only on the track it was for. So a like read or set for one track never shows on the next. A toggle
/// still waiting for Spotify's sign in is given up once its button leaves view, so it never likes later unseen.
struct NotchLikeLedger: Equatable {
    /// The track in view, kept while the player is out of view so reopening on it does not blank the heart.
    private(set) var request: NotchLikeRequest?
    /// The like of `request`, or nil while unknown.
    private(set) var liked: Bool?
    /// Set while the open notch shows the Like button for `request`; nothing is read otherwise.
    private(set) var visible = false
    private(set) var generation = 0
    /// The track a toggle is under way for; further presses wait for it, so a burst never toggles twice.
    private(set) var toggling: NotchLikeRequest?
    /// The like the toggle under way asks for: the opposite of what showed, liked when nothing did.
    private(set) var wanted = false
    /// The toggle under way waits for Spotify's sign in and has not acted yet.
    private(set) var pending = false
    /// Counts toggles, so the reply of one given up never lands on a later one.
    private(set) var toggleSerial = 0
    private var before: Bool?

    /// The open notch shows the Like button for `request`, or no longer shows it (nil). Returns the generation of a
    /// read to start: none out of view, and none during a toggle, which reads what is in view once it ends. A pending
    /// toggle whose button leaves view, or shows another track, is given up.
    mutating func show(_ request: NotchLikeRequest?) -> Int? {
        generation += 1
        if pending, request != toggling { toggling = nil; pending = false }
        guard let request else { visible = false; return nil }
        visible = true
        if request != self.request { self.request = request; liked = nil }
        return toggling == nil ? generation : nil
    }

    /// Reads the track in view again, as once YouTube has updated its button after a click.
    mutating func reread() -> Int? {
        guard visible, toggling == nil else { return nil }
        generation += 1
        return generation
    }

    /// Reads again the track in view when its YouTube tab was `unreachable`, as on a press of the dimmed heart, or
    /// when `activated`, an app that came forward, is its browser. Returns the generation of the read, or nil.
    mutating func retry(unreachable: NotchLikeRequest?, activated: String? = nil) -> Int? {
        guard let unreachable, unreachable == request,
              activated == nil || activated == unreachable.target.browser?.bundle else { return nil }
        return reread()
    }

    /// A press flips the like at once, unless not `optimistic`, as while Spotify first signs in, which may take
    /// minutes; such a toggle stays pending until it acts. Returns the track to toggle, or nil when out of view or a
    /// toggle is under way. `toggleSerial` names the toggle.
    mutating func beginToggle(optimistic: Bool = true) -> NotchLikeRequest? {
        guard visible, let request, toggling == nil else { return nil }
        generation += 1
        toggleSerial += 1
        toggling = request
        pending = !optimistic
        before = liked
        wanted = !(liked ?? false)
        if optimistic { liked = wanted }
        return request
    }

    /// A read's reply; returns false when a later read, toggle or change of track made it stale.
    mutating func finishRead(_ reply: NotchLikeReply, generation: Int) -> Bool {
        guard generation == self.generation, toggling == nil else { return false }
        liked = reply.value
        return true
    }

    /// Whether the pending toggle `serial` may still act, after signing in and right before saving: its button has
    /// stayed in view on its track since the press.
    func mayAct(_ serial: Int) -> Bool {
        pending && serial == toggleSerial && visible && toggling == request
    }

    /// The reply of toggle `serial`, for the track it was for: the like it reports, or the like from before when it
    /// failed. Returns whether it landed, and the generation of a read for a different track now in view. A toggle
    /// given up lands nothing.
    mutating func finishToggle(_ reply: NotchLikeReply, serial: Int) -> (landed: Bool, read: Int?) {
        guard serial == toggleSerial, let toggled = toggling else { return (false, nil) }
        toggling = nil
        pending = false
        if toggled == request {
            liked = reply.value ?? before
            return (true, nil)
        }
        guard visible else { return (false, nil) }
        generation += 1
        return (false, generation)
    }
}

/// Reads and toggles the like of the current track: AppleScript for Music, the Web API for Spotify with the track
/// named by its AppleScript, and for YouTube JavaScript run in the matching Safari tab or, when Safari refuses it,
/// the like button pressed through Accessibility (`NotchBrowserLike`), which is also Zen's only way. Nothing runs
/// unless the Like button is in a slot and the open notch shows the Music page, and nothing launches a player that
/// is not running. Failures stay quiet: the heart is drawn unknown, or dimmed when no safe way reaches the YouTube
/// tab, and the Now Playing page says why.
@MainActor
final class NotchLike: ObservableObject {
    @Published private(set) var ledger = NotchLikeLedger()
    /// The YouTube track whose tab neither JavaScript nor Accessibility could reach; cleared by a reply that could.
    @Published private(set) var unreachable: NotchLikeRequest?
    let spotify: NotchSpotifyAccount
    private var reading: Task<Void, Never>?
    private var toggling: Task<Void, Never>?
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "like")

    init(spotify: NotchSpotifyAccount? = nil) {
        self.spotify = spotify ?? .shared
    }

    /// The like of `request` when it is the track in view, else nil.
    func liked(_ request: NotchLikeRequest?) -> Bool? {
        request != nil && ledger.request == request ? ledger.liked : nil
    }

    /// Follows what the open notch shows: the Like button for a track, read each time it comes into view since the
    /// like may change elsewhere, or nothing (nil), which stops any read and gives up a like waiting for sign in.
    func show(_ request: NotchLikeRequest?) {
        let pending = ledger.pending
        read(ledger.show(request))
        if pending, !ledger.pending { toggling?.cancel(); toggling = nil }
    }

    /// Checks again whether the YouTube tab is reachable, on a press of the dimmed heart or when `activated`, the
    /// bundle of an app that came forward, is the tab's browser. It only reads; a like waits for a heart that is lit.
    func retry(activated: String? = nil) {
        read(ledger.retry(unreachable: unreachable, activated: activated))
    }

    /// Flips the like at once, then settles on what the player reports; a failure puts the previous state back. A
    /// track that changed meanwhile keeps its own like and is read once the toggle ends. Spotify's first press signs
    /// in through the browser instead of flipping, and likes once that completes if the button stayed in view on the
    /// same track and it still plays.
    func toggle() {
        let optimistic = ledger.request?.target != .spotify || spotify.authorized
        guard let request = ledger.beginToggle(optimistic: optimistic) else { return }
        let wanted = ledger.wanted, serial = ledger.toggleSerial
        reading?.cancel()
        toggling = Task { [weak self] in
            guard let self else { return }
            let reply = await self.run(request, toggle: true, wanted: wanted) {
                !Task.isCancelled && self.ledger.mayAct(serial)
            }
            let result = self.ledger.finishToggle(reply, serial: serial)
            if result.landed { self.note(reply, for: request) }
            self.read(result.read)
            // YouTube updates its button after the click is handled; read it back once it has.
            if result.landed, reply.value != nil, request.target.isYouTube {
                try? await Task.sleep(for: .seconds(1))
                if self.ledger.request == request { self.read(self.ledger.reread()) }
            }
        }
    }

    /// Starts the read of `generation`, replacing any read under way.
    private func read(_ generation: Int?) {
        reading?.cancel()
        guard let generation, let request = ledger.request else { return }
        reading = Task { [weak self] in
            guard let self else { return }
            let reply = await self.run(request, toggle: false, wanted: false)
            guard !Task.isCancelled, self.ledger.finishRead(reply, generation: generation) else { return }
            self.note(reply, for: request)
        }
    }

    private func note(_ reply: NotchLikeReply, for request: NotchLikeRequest) {
        switch reply {
        case .liked, .missing: if unreachable == request { unreachable = nil }
        case .unreachable: unreachable = request
        case .changed, .failed, .javaScriptOff, .unauthorized: break
        }
        if reply == .failed || reply == .unreachable { log.notice("Like unavailable: \(String(describing: reply), privacy: .public)") }
    }

    /// Reads or toggles the like; `valid` says whether a toggle that waited for Spotify's sign in may still act.
    private func run(_ request: NotchLikeRequest, toggle: Bool, wanted: Bool,
                     valid: () -> Bool = { true }) async -> NotchLikeReply {
        switch request.target {
        case .unsupported:
            return .failed
        case .spotify:
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: NotchSpotifyLike.bundle).isEmpty else { return .missing }
            return await NotchSpotifyLike.run(toggle: toggle, wanted: wanted, account: spotify, valid: valid) {
                await NotchSpotifyLike.track(title: request.title, artist: request.artist, prompting: toggle)
            }
        case .music:
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return .missing }
            let result = await NotchWebSites.osascript(Self.musicScript, arguments: [toggle ? "toggle" : "read", request.title, request.artist],
                                                       automating: "com.apple.Music", prompting: toggle)
            return NotchLikeReply(status: result.status, output: result.output, error: result.error)
        case .youTube(let page):
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: NotchWebSites.safari).isEmpty else { return .missing }
            let result = await NotchWebSites.osascript(Self.safariScript, arguments: [page.absoluteString,
                                                                                       Self.youTubeScript(toggle: toggle, title: request.title)],
                                                       automating: NotchWebSites.safari, prompting: toggle)
            let reply = NotchLikeReply(status: result.status, output: result.output, error: result.error)
            // Without JavaScript, Accessibility may still reach the like button of the tab in front.
            guard reply == .javaScriptOff, !Task.isCancelled else { return reply }
            return await NotchBrowserLike.run(.safari, page: page, title: request.title, toggle: toggle)
        case .zen:
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: NotchAXBrowser.zen.bundle).isEmpty else { return .missing }
            return await NotchBrowserLike.run(.zen, page: nil, title: request.title, toggle: toggle)
        }
    }

    /// Music calls it `favorited` since macOS 14 and `loved` before; the second is tried when the first fails. The
    /// current track must still be the one asked about, by title and artist, or nothing is read or set.
    private static let musicScript = """
        on run argv
            tell application "Music"
                if player state is stopped then return "missing"
                set t to current track
                if (name of t) is not (item 2 of argv) or (artist of t) is not (item 3 of argv) then return "changed"
                try
                    if item 1 of argv is "toggle" then set favorited of t to not (favorited of t)
                    return favorited of t as text
                on error
                    if item 1 of argv is "toggle" then set loved of t to not (loved of t)
                    return loved of t as text
                end try
            end tell
        end run
        """

    /// Runs the JavaScript in the tab showing the page, by address, as `showSafariTab` finds it.
    private static let safariScript = """
        on run argv
            set target to item 1 of argv
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is target then return do JavaScript (item 2 of argv) in t
                    end repeat
                end repeat
            end tell
            return "missing"
        end run
        """

    /// YouTube Music's player bar first, then the like button of YouTube's watch page in its current and older
    /// markup. `aria-pressed` carries the state; a click flips it a moment later, so the toggle reports the flip. The
    /// page must name the track asked about, by its media session title or else its own title, so the next video
    /// playing in the same tab, or a page that names nothing, is left alone. Titles are compared plain, by
    /// `NotchWebSites.plainTitleScript`, as the tab was matched. The title goes in as a JSON string literal, so the
    /// page's text is never code.
    nonisolated static func youTubeScript(toggle: Bool, title: String) -> String {
        let expected = (try? JSONEncoder().encode(title)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return """
        (function () {
          \(NotchWebSites.plainTitleScript)
          var expected = plain(\(expected));
          var session = navigator.mediaSession && navigator.mediaSession.metadata;
          var playing = plain(session && session.title ? session.title : document.title);
          if (!expected || !playing) return 'missing';
          if (playing !== expected) return 'changed';
          var button = document.querySelector('ytmusic-player-bar ytmusic-like-button-renderer #button-shape-like button')
            || document.querySelector('like-button-view-model button')
            || document.querySelector('#segmented-like-button button');
          if (!button) return 'missing';
          var pressed = button.getAttribute('aria-pressed') === 'true';
          if (\(toggle)) { button.click(); return String(!pressed); }
          return String(pressed);
        })()
        """
    }
}

/// What Spotify's AppleScript says plays: a track by its URI, or something the library and playlists do not take,
/// such as an episode, an ad or a local file.
enum NotchSpotifyTrack: Equatable {
    case track(String)
    case other
    /// Spotify plays another track than the one asked about.
    case changed
    case missing
    case failed

    /// Parses the script's `id`, `name` and `artist`, separated by character 31. The name must be the title asked
    /// about; the artist may be only the first of several, as MediaRemote and AppleScript list them differently.
    static func parse(status: Int32, output: String, title: String, artist: String) -> NotchSpotifyTrack {
        guard status == 0 else { return status == procNotFound ? .missing : .failed }
        let text = output.trimmingCharacters(in: .newlines)
        if text == "missing" { return .missing }
        let parts = text.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return .failed }
        let (name, by) = (parts[1], parts[2])
        guard name == title, by == artist || (!by.isEmpty && (artist.hasPrefix(by) || by.hasPrefix(artist))) else { return .changed }
        return NotchSpotify.trackURI(parts[0]).map { .track($0) } ?? .other
    }
}

/// The Spotify like apart from Apple Events, so its flow can be checked: a read needs tokens and never signs in; a
/// press signs in first when needed and, once the browser came back, likes only if it is still `valid`, checked
/// again right before saving, and the same track still plays.
enum NotchSpotifyLike {
    static let bundle = "com.spotify.client"

    @MainActor
    static func run(toggle: Bool, wanted: Bool, account: NotchSpotifyAccount, valid: () -> Bool = { true },
                    track: () async -> NotchSpotifyTrack) async -> NotchLikeReply {
        guard toggle || account.authorized else { return .unauthorized }
        let current = await track()
        guard case .track(let uri) = current else { return current.reply }
        if !account.authorized {
            guard await account.authorize() else { return .unauthorized }
            guard valid(), await track() == current, valid() else { return .changed }
        }
        do throws(NotchSpotifyFailure) {
            if toggle {
                try await account.setSaved(uri, wanted)
                return .liked(wanted)
            }
            return .liked(try await account.saved(uri))
        } catch .unauthorized {
            return .unauthorized
        } catch {
            return .failed
        }
    }

    /// Spotify's current track, checked against the title and artist asked about. Only a press may show the
    /// Automation prompt.
    static func track(title: String, artist: String, prompting: Bool) async -> NotchSpotifyTrack {
        let result = await NotchWebSites.osascript(script, automating: bundle, prompting: prompting)
        return NotchSpotifyTrack.parse(status: result.status, output: result.output, title: title, artist: artist)
    }

    /// The separator is set outside the `tell` block, as in the Safari tab script.
    private static let script = """
        set separator to character id 31
        tell application "Spotify"
            if player state is stopped then return "missing"
            set t to current track
            return (id of t) & separator & (name of t) & separator & (artist of t)
        end tell
        """
}

private extension NotchSpotifyTrack {
    /// The like reply for anything but a track.
    var reply: NotchLikeReply {
        switch self {
        case .changed: .changed
        case .failed: .failed
        case .track, .other, .missing: .missing
        }
    }
}
