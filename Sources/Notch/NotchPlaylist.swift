import AppKit
import os

/// The playlists a menu offers, the recently used first, then the rest by name.
struct NotchPlaylistMenu: Equatable {
    let request: NotchLikeRequest
    let recent: [NotchPlaylist]
    let rest: [NotchPlaylist]

    /// Splits `playlists`: up to `limit` of the `recent` IDs, most recent first, that still exist, then every other
    /// playlist sorted as Finder sorts names.
    init(request: NotchLikeRequest, playlists: [NotchPlaylist], recent ids: [String], limit: Int = 3) {
        self.request = request
        let byID = Dictionary(playlists.map { ($0.id, $0) }) { first, _ in first }
        recent = Array(ids.compactMap { byID[$0] }.prefix(limit))
        let shown = Set(recent.map(\.id))
        rest = playlists.filter { !shown.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// How adding the current track to a playlist ended.
enum NotchPlaylistResult: Equatable {
    case added
    /// Another track plays now, so nothing was added.
    case changed
    /// Spotify is not signed in, or signing in did not complete.
    case unauthorized
    case failed

    init(musicOutput output: String, status: Int32) {
        switch (status, output.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case (0, "added"): self = .added
        case (0, "changed"): self = .changed
        default: self = .failed
        }
    }
}

/// The Playlist button's bookkeeping apart from scripts and the network, as the like's ledger: it knows the track in
/// view, lets one list or add run at a time, opens a menu only for the track still on screen, and shows an add's
/// outcome only on the track it was for.
struct NotchPlaylistLedger: Equatable {
    /// An add's outcome; `serial` tells repeated outcomes apart so each one shows its full time.
    struct Outcome: Equatable {
        let request: NotchLikeRequest
        let added: Bool
        let serial: Int
    }

    private(set) var request: NotchLikeRequest?
    private(set) var visible = false
    /// The track a list or an add is under way for.
    private(set) var busy: NotchLikeRequest?
    private(set) var outcome: Outcome?
    private var serial = 0
    /// A list is under way, and its button has not left view since the press.
    private var listing = false
    private var listInView = false

    /// The open notch shows the Playlist button for `request`, or no longer shows it (nil). A list under way, which
    /// may wait for Spotify's sign in, then opens no menu even if the button comes back.
    mutating func show(_ request: NotchLikeRequest?) {
        if listing, request != self.request || !visible || request == nil { listInView = false }
        visible = request != nil
        if let request { self.request = request }
    }

    /// A press asks for the list. Returns the track, or nil when out of view or busy.
    mutating func beginList() -> NotchLikeRequest? {
        guard visible, let request, busy == nil else { return nil }
        busy = request
        listing = true
        listInView = true
        return request
    }

    /// Whether the list under way for `request` may go on, as once Spotify's sign in returns: its button has stayed in
    /// view on the same track since the press.
    func mayList(_ request: NotchLikeRequest) -> Bool {
        listing && busy == request && listInView && visible && self.request == request
    }

    /// The list arrived or failed; returns whether its menu may open: its button stayed in view on the same track.
    mutating func finishList(for request: NotchLikeRequest) -> Bool {
        guard busy == request, listing else { return false }
        busy = nil
        listing = false
        return listInView && visible && self.request == request
    }

    /// A playlist was picked for `request`, which the menu was opened for. Returns false while another add runs.
    mutating func beginAdd(for request: NotchLikeRequest) -> Bool {
        guard busy == nil else { return false }
        busy = request
        return true
    }

    /// The add ended. Its outcome shows only while its track is the one in view; a changed track shows nothing.
    /// Returns the outcome's serial when one shows.
    mutating func finishAdd(_ result: NotchPlaylistResult, for request: NotchLikeRequest) -> Int? {
        guard busy == request else { return nil }
        busy = nil
        guard result != .changed, self.request == request else { return nil }
        serial += 1
        outcome = Outcome(request: request, added: result == .added, serial: serial)
        return serial
    }

    /// The outcome's moment passed, unless a newer one replaced it.
    mutating func clearOutcome(_ serial: Int) {
        if outcome?.serial == serial { outcome = nil }
    }
}

/// Lists the playlists the current track can join and adds it to one: Apple Music's own playlists through
/// AppleScript, Spotify's through its Web API. Nothing runs unless the Playlist button is in a slot and the open
/// notch shows the Music page; the list is read once it shows, so the menu opens at once, and a press signs in to
/// Spotify first when needed. The playlists picked last come first, remembered per player in the user's defaults.
@MainActor
final class NotchPlaylists: ObservableObject {
    @Published private(set) var ledger = NotchPlaylistLedger()
    private let spotify: NotchSpotifyAccount
    private var cache: (target: NotchLikeTarget, playlists: [NotchPlaylist], at: Date)?
    private var prefetch: Task<Void, Never>?
    /// The list a press reads, cancelled once its button leaves view.
    private var list: (request: NotchLikeRequest, task: Task<[NotchPlaylist]?, Never>)?
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "playlist")
    private static let recentsKey = "playlistRecents"
    /// How long a list read on show serves presses.
    private static let freshness: TimeInterval = 120
    /// How long a checkmark or a cross stays on the button.
    static let outcomeDuration: TimeInterval = 1.6

    init(spotify: NotchSpotifyAccount? = nil) {
        self.spotify = spotify ?? .shared
    }

    /// Only Apple Music and Spotify have playlists Eclipse can add to.
    static func supports(_ target: NotchLikeTarget) -> Bool { target == .music || target == .spotify }

    /// Follows what the open notch shows; reads the list for a track coming into view when it may without asking
    /// anything: Apple Music already automated, Spotify already signed in.
    func show(_ request: NotchLikeRequest?) {
        ledger.show(request)
        if let list, !ledger.mayList(list.request) { list.task.cancel(); self.list = nil }
        prefetch?.cancel()
        guard let request, Self.supports(request.target), !fresh(request.target),
              request.target == .music || spotify.authorized else { return }
        prefetch = Task { [weak self] in
            guard let self, let playlists = await self.load(request.target, prompting: false), !Task.isCancelled else { return }
            self.cache = (request.target, playlists, .now)
        }
    }

    /// A press: the menu for the track in view, or nil when it should not open, as when signing in did not complete,
    /// the list could not be read, or the notch closed or moved to another track meanwhile.
    func menu() async -> NotchPlaylistMenu? {
        guard let request = ledger.beginList() else { return nil }
        var playlists: [NotchPlaylist]?
        if fresh(request.target), let cache { playlists = cache.playlists }
        if playlists == nil {
            // Spotify's first press signs in; the list is read afterwards only if the notch still shows the track.
            let task = Task { [weak self] () -> [NotchPlaylist]? in
                guard let self else { return nil }
                let signedIn = request.target == .spotify ? await self.spotify.authorize() : true
                guard signedIn, !Task.isCancelled, self.ledger.mayList(request) else { return nil }
                return await self.load(request.target, prompting: true)
            }
            list = (request, task)
            playlists = await task.value
            if list?.task == task { list = nil }
            if let playlists { cache = (request.target, playlists, .now) }
        }
        guard ledger.finishList(for: request), let playlists else { return nil }
        return NotchPlaylistMenu(request: request, playlists: playlists, recent: recents[key(request.target)] ?? [])
    }

    /// Adds the track the menu was opened for to `playlist`, then shows the outcome for a moment.
    func add(_ playlist: NotchPlaylist, for request: NotchLikeRequest) {
        guard ledger.beginAdd(for: request) else { return }
        remember(playlist, for: request.target)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.run(playlist, request)
            if result != .added { self.log.notice("Adding to a playlist ended \(String(describing: result), privacy: .public)") }
            guard let serial = self.ledger.finishAdd(result, for: request) else { return }
            try? await Task.sleep(for: .seconds(Self.outcomeDuration))
            self.ledger.clearOutcome(serial)
        }
    }

    private func fresh(_ target: NotchLikeTarget) -> Bool {
        guard let cache, cache.target == target else { return false }
        return Date.now.timeIntervalSince(cache.at) < Self.freshness
    }

    private func load(_ target: NotchLikeTarget, prompting: Bool) async -> [NotchPlaylist]? {
        switch target {
        case .music:
            guard running("com.apple.Music") else { return nil }
            let result = await NotchWebSites.osascript(NotchMusicPlaylists.listScript, automating: "com.apple.Music", prompting: prompting)
            return result.status == 0 ? NotchMusicPlaylists.parse(result.output) : nil
        case .spotify:
            return try? await spotify.playlists()
        case .youTube, .zen, .unsupported:
            return nil
        }
    }

    private func run(_ playlist: NotchPlaylist, _ request: NotchLikeRequest) async -> NotchPlaylistResult {
        switch request.target {
        case .music:
            guard running("com.apple.Music") else { return .changed }
            let result = await NotchWebSites.osascript(NotchMusicPlaylists.addScript,
                                                       arguments: NotchMusicPlaylists.addArguments(playlist: playlist, request: request),
                                                       automating: "com.apple.Music")
            return NotchPlaylistResult(musicOutput: result.output, status: result.status)
        case .spotify:
            guard running(NotchSpotifyLike.bundle) else { return .changed }
            guard case .track(let uri) = await NotchSpotifyLike.track(title: request.title, artist: request.artist, prompting: true)
            else { return .changed }
            do throws(NotchSpotifyFailure) {
                try await spotify.add(uri, to: playlist.id)
                return .added
            } catch .unauthorized {
                return .unauthorized
            } catch {
                return .failed
            }
        case .youTube, .zen, .unsupported:
            return .failed
        }
    }

    private func running(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    private func key(_ target: NotchLikeTarget) -> String { target == .spotify ? "spotify" : "music" }

    private var recents: [String: [String]] {
        UserDefaults.standard.dictionary(forKey: Self.recentsKey) as? [String: [String]] ?? [:]
    }

    private func remember(_ playlist: NotchPlaylist, for target: NotchLikeTarget) {
        var all = recents
        let ids = [playlist.id] + (all[key(target)] ?? []).filter { $0 != playlist.id }
        all[key(target)] = Array(ids.prefix(5))
        UserDefaults.standard.set(all, forKey: Self.recentsKey)
    }
}

/// Apple Music's playlists through AppleScript: the user's own, neither smart nor special (folders, Genius, the
/// library's built in lists), identified by persistent ID. Values reach the scripts as arguments only.
enum NotchMusicPlaylists {
    /// Prints `persistent ID`, character 31 and the name for each playlist, each ended by character 30, so names
    /// holding tabs or line breaks stay whole.
    static let listScript = """
        set fieldEnd to character id 31
        set recordEnd to character id 30
        tell application "Music"
            set output to ""
            repeat with p in (every user playlist whose smart is false and special kind is none)
                set output to output & (persistent ID of p) & fieldEnd & (name of p) & recordEnd
            end repeat
            return output
        end tell
        """

    static func parse(_ output: String) -> [NotchPlaylist] {
        output.split(separator: "\u{1E}").compactMap { record in
            let fields = record.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            let id = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard fields.count == 2, id.wholeMatch(of: #/[0-9A-F]{16}/#) != nil else { return nil }
            return NotchPlaylist(id: id, name: String(fields[1]))
        }
    }

    /// The playlist's persistent ID, then the title and artist the current track must still have.
    static func addArguments(playlist: NotchPlaylist, request: NotchLikeRequest) -> [String] {
        [playlist.id, request.title, request.artist]
    }

    /// Adds the current track to the playlist when it is still the track asked about, always that exact recording. A
    /// library track, wherever it plays from, is found in the library by its persistent ID, which every playlist
    /// shares, and that copy joins; any error then fails. Only a song streaming from the Apple Music catalog, which is
    /// not in the library and cannot join a playlist directly, joins the library first, and the playlist takes the
    /// copy that add returned, once its title and artist are checked; without one it fails, adding nothing to the
    /// playlist. Prints `added`, `changed`, `missing` or `failed`.
    static let addScript = """
        on run argv
            set {playlistID, trackName, trackArtist} to argv
            tell application "Music"
                if player state is stopped then return "missing"
                set t to current track
                if (name of t) is not trackName or (artist of t) is not trackArtist then return "changed"
                set targets to (every user playlist whose persistent ID is playlistID and smart is false)
                if targets is {} then return "missing"
                set p to item 1 of targets
                set trackID to persistent ID of t
                set copies to (every track of library playlist 1 whose persistent ID is trackID)
                if (count of copies) is 1 then
                    try
                        duplicate item 1 of copies to p
                        return "added"
                    end try
                    return "failed"
                end if
                if copies is not {} then return "failed"
                try
                    set copied to duplicate t to library playlist 1
                    if class of copied is list then
                        if (count of copied) is not 1 then return "failed"
                        set copied to item 1 of copied
                    end if
                    if (name of copied) is trackName and (artist of copied) is trackArtist then
                        duplicate copied to p
                        return "added"
                    end if
                end try
                return "failed"
            end tell
        end run
        """
}
