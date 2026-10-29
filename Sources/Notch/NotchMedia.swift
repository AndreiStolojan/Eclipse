import AppKit
import Combine
import MediaRemoteAdapter
import os

/// Observes the system's player, or one heard playing beside it (`NotchSourcePick`), without changing playback until a
/// user presses a control.
@MainActor
final class NotchMedia: ObservableObject {
    @Published private(set) var track: TrackInfo.Payload?
    @Published private(set) var unavailable = false
    /// Spotify reports neither mode through MediaRemote, so the last toggle stands in until a player reports real values.
    @Published private(set) var shuffleMode: TrackInfo.ShuffleMode = .off
    @Published private(set) var repeatMode: TrackInfo.RepeatMode = .off
    private(set) var source: NotchMediaSource?
    /// The website behind browser media; nil for apps or until Safari's tabs are read for the playing track.
    @Published private(set) var webSite: NotchWebSite?
    private var sourceKey: String?
    private var web = NotchWebLookup()
    private var webLookup: Task<Void, Never>?
    /// Waits for the lookup's next automatic retry, and when it is due, see `NotchWebLookup.retryAt`.
    private var webRetry: Task<Void, Never>?
    private var webRetryAt: Date?
    /// The show Netflix's page last named and the video it named it on, which a track may report instead of
    /// "Netflix", see `NotchWebSites.pick`.
    private var netflixHeading: NotchWebSites.NetflixHeading?
    /// Fetches the website's icon once the site is shown, and the host it was asked for.
    private var iconTask: Task<Void, Never>?
    private var iconAsked: String?
    /// YouTube recognised in another browser's titles, see `NotchBrowserTabs`.
    private var tabs = NotchTabLookup()
    private var tabsTask: Task<Void, Never>?
    /// What plays, for its layout; worked out again whenever its source, website or wait changes.
    @Published private(set) var kind: NotchMediaKind = .app
    private var kindWait = NotchMediaKindWait()
    private var kindExpiry: Task<Void, Never>?
    private var kindExpiryAt: Date?
    private var previewKind: NotchMediaKind?
    /// What the playing page says about its video, read for a site MediaRemote says too little about, see
    /// `NotchWebPage`; nil until a read confirms the tab still shows the video it was read from (`NotchWebPageCache`).
    @Published private(set) var webPage: NotchWebPage?
    /// Set by the view while the open notch shows the Music page on a panel that can be seen; the player's page reads
    /// run only then.
    var watchesPage = false {
        didSet { if watchesPage != oldValue { followPage() } }
    }
    /// Set by the experience while a mini peek could show: it is on and the notch is neither hidden, locked nor
    /// obscured. A Netflix track starting while the player is closed then gets one read of its tab's text, so the peek
    /// can name the show; a read under way stops when that ends.
    var peeksPages = false {
        didSet { if peeksPages != oldValue { followPage() } }
    }
    private var pages = NotchWebPageCache()
    /// The reads under way, or the player's last ones, which a pause or a resume continues.
    private var pageRound: PageRound?
    private var pageTask: Task<Void, Never>?
    /// Waits for the shown page's lapse, see `NotchWebPageCache.lapse`.
    private var pageLapse: Task<Void, Never>?
    private var previewWeb = false
    /// Set by the experience while the Mac is locked: no new Apple Events, Accessibility reads or favicon fetches
    /// start meanwhile, and a track that changed is looked up after unlock. Reads of other players stop and run again
    /// after unlock.
    var webLookupsPaused = false {
        didSet {
            guard webLookupsPaused != oldValue else { return }
            web.paused = webLookupsPaused
            tabs.paused = webLookupsPaused
            if webLookupsPaused {
                if webLookup != nil { web.abandon() }
                if tabsTask != nil { tabs.abandon() }
                for task in [webLookup, tabsTask, iconTask, confirmWake, playerRead] { task?.cancel() }
                for read in confirmReads.values { read.cancel() }
                (webLookup, tabsTask, iconTask, iconAsked, confirmReads) = (nil, nil, nil, nil, [:])
                confirmations.interrupt()
            }
            lookUpWebSite()
            followPage()
            if !webLookupsPaused {
                follow()
                if case .other(let app, _) = pick.followed { readPlayer(app) }
            }
        }
    }
    /// The current track's like, for the player's Like button.
    let like = NotchLike()
    /// The playlists the current track can join, for the player's Playlist button.
    let playlists = NotchPlaylists()
    private let adapter = MediaRemoteAdapter.MediaController()
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "media")
    /// Called with true when what plays deserves a peek: playback starting, or a different track or player playing
    /// (see `NotchTrackWatch`), and with false when more of the playing track becomes known: its artist, website or
    /// artwork arriving after the title, or its artwork replaced.
    var onTrackChange: ((Bool) -> Void)?
    /// The playing track as the mini peek shows it; nil while paused, without a track or without a title.
    private(set) var nowPlaying: NotchTrackPeek?
    /// The artwork as the player and the closed wing show it: it changes once per new image, see `NotchArtworkFlow`.
    @Published private(set) var shownArtwork = NotchShownArtwork()
    private var artworkFlow = NotchArtworkFlow()
    /// The artwork data last reported and a key that changes with it, so the flow compares integers.
    private var artworkData: String?
    private var artworkKey = 0
    private var artworkSettle: Task<Void, Never>?
    /// The shown artwork's average colour for a tinted wave, nil without artwork or until first wanted.
    @Published private(set) var artworkTint: NSColor?
    /// Whether the wave wants the artwork's colour; the experience sets it from the settings. Off, nothing is computed.
    var tintsWave = false {
        didSet { if tintsWave != oldValue { updateTint() } }
    }
    /// The artwork key `artworkTint` belongs to or is being computed for, so each image is computed once.
    private var tintKey: Int?
    private var tintTask: Task<Void, Never>?
    private var trackWatch = NotchTrackWatch()
    /// Which apps make sound, so a player playing beside a paused one MediaRemote holds can be followed, see
    /// `NotchSourcePick`.
    private let audible = NotchAudibleApps()
    private var pick = NotchSourcePick()
    private var pickRecheck: Task<Void, Never>?
    /// The system's player as MediaRemote last reported it, and each player's last report by bundle identifier, which
    /// stands in for a player followed beside it. A followed player's report is replaced by what it shows, so a pause
    /// freezes its position and a resume carries on from there.
    private var systemTrack: TrackInfo.Payload?
    private var reports: [String: TrackInfo.Payload] = [:]
    private var sources: [String: NotchMediaSource] = [:]
    /// Whether each player the pick wants plays what its last report says, the reads under way and the wait for the
    /// next one that may start, see `confirm`.
    private var confirmations = NotchConfirmations()
    private var confirmReads: [String: Task<Void, Never>] = [:]
    private var confirmWake: Task<Void, Never>?
    /// The Netflix video Safari's page was last read at, which confirms Safari when only the tab's text can be read.
    private var safariVideo: String?
    /// Spotify or Music followed beside the system's player: its notification observer, the read under way and the
    /// cover being fetched for a new track.
    private var playerObserver: (app: String, token: NSObjectProtocol)?
    private var playerRead: Task<Void, Never>?
    private var coverFetch: Task<Void, Never>?
    private var running = false
    private var revision = 0
    private var recovery: Task<Void, Never>?

    /// The preview values stand in for a track, its website, what its page said and its kind, for offscreen renders.
    /// A preview website and page stay as given; nothing reads a browser for them.
    init(previewTrack: TrackInfo.Payload? = nil, previewSite: NotchWebSite? = nil, previewPage: NotchWebPage? = nil,
         previewKind: NotchMediaKind? = nil) {
        // Set before the track, so the mini peek's row is worked out with them.
        previewWeb = previewSite != nil || previewPage != nil || previewKind != nil
        webSite = previewSite
        webPage = previewPage
        self.previewKind = previewKind
        apply(previewTrack)
        adapter.onTrackInfoReceived = { [weak self] info in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.revision += 1
                self.hear(info?.payload)
                self.unavailable = false
            }
        }
        audible.onChange = { [weak self] stirred in
            self?.confirmations.stir(stirred)
            self?.follow()
        }
        adapter.onDecodingError = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.unavailable = true }
        }
        adapter.onListenerTerminated = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.unavailable = true
                self.recovery?.cancel()
                self.recovery = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, self.running else { return }
                    self.adapter.startListening()
                    self.refresh()
                }
            }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        revision += 1
        // Whatever already plays when listening starts is not news.
        trackWatch = NotchTrackWatch()
        audible.start()
        adapter.startListening()
        refresh()
    }

    func stop() {
        running = false
        revision += 1
        recovery?.cancel()
        recovery = nil
        adapter.stopListening()
        audible.stop()
        pickRecheck?.cancel()
        pickRecheck = nil
        pick = NotchSourcePick()
        confirm([])
        observePlayer()
        systemTrack = nil
        reports = [:]
        safariVideo = nil
        apply(nil)
    }

    func refresh() {
        let requestRevision = revision
        adapter.getTrackInfo { [weak self] info in
            MainActor.assumeIsolated {
                guard let self, self.running, self.revision == requestRevision else { return }
                self.hear(info?.payload)
            }
        }
    }

    /// Takes a report of the system's player and follows the player `NotchSourcePick` picks.
    private func hear(_ payload: TrackInfo.Payload?) {
        systemTrack = payload
        if let payload, let app = mediaSource(payload).bundleIdentifier { reports[app] = payload }
        follow(systemReported: true)
    }

    /// Picks the player to follow again, after a report, a change in what makes sound or a wait ending, and shows it
    /// if that changed or the system's followed player reported.
    private func follow(systemReported: Bool = false) {
        guard running else { return }
        let system = systemTrack.flatMap { mediaSource($0).bundleIdentifier }
        let known = Set(reports.keys.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        reports = reports.filter { known.contains($0.key) || $0.key == system }
        let before = pick.followed
        let now = ContinuousClock.now, fresh = confirmations.fresh(at: now)
        let followed = pick.update(NotchSourcePick.Report(system: system, systemPlaying: systemTrack?.isPlaying == true,
                                                          heard: audible.heard, voiced: audible.voiced, known: known,
                                                          confirmed: fresh, stale: confirmations.confirmed.subtracting(fresh),
                                                          denied: confirmations.denied), at: now)
        audible.polled = pick.watched
        confirm(pick.wanted, renew: pick.renew)
        observePlayer()
        pickRecheck?.cancel()
        pickRecheck = pick.recheck.map { when in
            Task { [weak self] in
                try? await Task.sleep(until: when, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.follow()
            }
        }
        if followed != before { log.info("Following \(String(describing: followed), privacy: .public), system \(system ?? "none", privacy: .public)") }
        switch followed {
        case .system:
            if followed != before || systemReported { apply(systemTrack) }
        case .other(let app, let playing):
            guard followed != before, let report = reports[app] else { return }
            // A player followed beside the system's is already playing or paused, so it never peeks.
            show(report.as(playing: playing), of: app)
            readPlayer(app)
        }
    }

    /// Shows a report of a player followed beside the system's, quietly, and keeps it as that player's report.
    private func show(_ report: TrackInfo.Payload, of app: String) {
        reports[app] = report
        apply(report, quiet: true)
    }

    /// Keeps the confirmations to the players in `wanted`, marks the stale ones in `renew` due and starts the reads
    /// that are due, see `NotchConfirmations`; none while the Mac is locked. The followed player is read again every `NotchConfirmations.refresh` through the
    /// one wake below, which nothing sets while the system's player is followed. Each read that settles picks the
    /// player again.
    private func confirm(_ wanted: Set<String>, renew: Set<String> = []) {
        for app in confirmations.want(wanted) { confirmReads.removeValue(forKey: app)?.cancel() }
        confirmations.renew(renew, at: .now)
        let following: String? = if case .other(let app, _) = pick.followed { app } else { nil }
        let (apps, wake) = confirmations.start(at: .now, paused: webLookupsPaused, following: following)
        for app in apps {
            guard let report = reports[app] else {
                confirmations.settle(app, plays: nil, at: .now)
                continue
            }
            confirmReads[app]?.cancel()
            confirmReads[app] = Task { [weak self] in
                let plays = await self?.plays(app, report: report)
                guard !Task.isCancelled, let self else { return }
                self.confirmReads[app] = nil
                let verdict = plays.map { $0 ? "plays" : "does not play" } ?? "cannot tell whether it plays"
                self.log.info("\(app, privacy: .public) \(verdict, privacy: .public) its last report")
                self.confirmations.settle(app, plays: plays, at: .now)
                self.follow()
            }
        }
        confirmWake?.cancel()
        confirmWake = wake.map { when in
            Task { [weak self] in
                try? await Task.sleep(until: when, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.follow()
            }
        }
    }

    private static let netflix = NotchWebSite(name: "Netflix", host: "netflix.com", url: URL(string: "https://www.netflix.com/")!)

    /// Whether `app` plays what `report` says, or nil when that cannot be told this time. Spotify and Music say
    /// through AppleScript, and a track that changed meanwhile replaces the report. Safari's Netflix is its one player
    /// tab, see `NotchWebPages.netflixPlays`; another Safari video is the tab whose title names it, by its video's
    /// state, which only JavaScript reads (`NotchWebPages.videoPlays`). Without Automation for Safari nothing can be
    /// told. Any other player is never confirmed, since nothing tells its sound from a call's.
    private func plays(_ app: String, report: TrackInfo.Payload) async -> Bool? {
        if NotchScriptedPlayer.notifications[app] != nil {
            // A read the pick dropped meanwhile, or one that outlived locking or stopping, changes nothing.
            guard let player = await Self.read(app), !Task.isCancelled else { return nil }
            refresh(app, with: player)
            return player.playing
        }
        guard app == NotchWebSites.safari else { return false }
        guard NotchWebSites.automation(of: app) == noErr else { return nil }
        if NotchWebSites.plainTitle(report.title ?? "").caseInsensitiveCompare(Self.netflix.name) == .orderedSame {
            guard let request = NotchWebPageRequest(site: Self.netflix, title: report.title, durationKnown: false) else { return false }
            let outcome = await NotchWebPages.read(request, known: nil, javaScript: true)
            return NotchWebPages.netflixPlays(outcome, watched: safariVideo, sounding: audible.heard?.contains(app) == true,
                                              capturing: audible.capturing.contains(app))
        }
        guard let tabs = await NotchWebSites.safariTabs(prompting: false) else { return nil }
        guard case .named(let tab) = NotchWebSites.pick(tabs, trackTitle: report.title, netflixHeading: netflixHeading) else {
            return false
        }
        let site = NotchWebSite(name: "", host: NotchWebSites.host(of: tab.url) ?? "", url: tab.url, matchesTrack: true)
        guard let request = NotchWebPageRequest(site: site, title: report.title, durationKnown: false) else { return nil }
        return NotchWebPages.videoPlays(await NotchWebPages.read(request, known: nil, javaScript: true))
    }

    /// Reads Spotify or Music through AppleScript, without asking for the Automation permission; nil when that failed
    /// or is not allowed.
    private static func read(_ app: String) async -> NotchScriptedPlayer? {
        guard let script = NotchScriptedPlayer.script(for: app) else { return nil }
        let result = await NotchWebSites.osascript(script, automating: app, prompting: false)
        return result.status == 0 ? NotchScriptedPlayer.parse(result.output, app: app) : nil
    }

    /// Reads Spotify or Music again while it is followed beside the system's player, replacing a read under way; not
    /// while the Mac is locked, nor once it is no longer followed. What it says also settles whether it plays, so a
    /// pause reported while it is still heard shows at once.
    private func readPlayer(_ app: String) {
        guard running, case .other(app, _) = pick.followed, NotchScriptedPlayer.notifications[app] != nil,
              !webLookupsPaused else { return }
        playerRead?.cancel()
        playerRead = Task { [weak self] in
            guard let player = await Self.read(app), !Task.isCancelled, let self else { return }
            self.confirmations.settle(app, plays: player.playing, at: .now)
            self.refresh(app, with: player)
        }
    }

    /// Takes what Spotify or Music says about itself: a new track replaces its report, with Spotify's cover fetched,
    /// and the position is renewed. While it is followed it shows at once, and a pause shows as soon as it falls silent.
    private func refresh(_ app: String, with player: NotchScriptedPlayer) {
        guard let old = reports[app] else { return }
        if player.title != nil {
            let report = TrackInfo.Payload(player, over: old)
            reports[app] = report
            if report.title != old.title || report.artist != old.artist, let cover = player.artworkURL {
                fetchCover(app, title: report.title, from: cover)
            }
        }
        guard case .other(app, let playing) = pick.followed else { return }
        if !player.playing { pick.paused() }
        if let report = reports[app] { show(report.as(playing: playing), of: app) }
        follow()
    }

    /// Fetches Spotify's cover for the followed track; one arriving after the track changed is dropped.
    private func fetchCover(_ app: String, title: String?, from url: URL) {
        coverFetch?.cancel()
        coverFetch = Task { [weak self] in
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 5)
            guard let (data, _) = try? await URLSession.shared.data(for: request), NSImage(data: data) != nil,
                  !Task.isCancelled, let self, let report = self.reports[app], report.title == title else { return }
            let covered = report.with(artwork: data)
            self.reports[app] = covered
            if case .other(app, let playing) = self.pick.followed { self.show(covered.as(playing: playing), of: app) }
        }
    }

    /// Listens to Spotify's or Music's own notifications while it is followed beside the system's player, which
    /// MediaRemote no longer reports, and reads it again on each, as after a skip pressed in the notch.
    private func observePlayer() {
        var followed: String?
        if case .other(let app, _) = pick.followed, NotchScriptedPlayer.notifications[app] != nil { followed = app }
        guard followed != playerObserver?.app else { return }
        if let playerObserver { DistributedNotificationCenter.default().removeObserver(playerObserver.token) }
        playerObserver = nil
        playerRead?.cancel()
        coverFetch?.cancel()
        guard let app = followed, let name = NotchScriptedPlayer.notifications[app] else { return }
        let token = DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.readPlayer(app) }
        }
        playerObserver = (app, token)
    }

    /// The player behind a report, made once per player since it looks up the app's icon.
    private func mediaSource(_ payload: TrackInfo.Payload) -> NotchMediaSource {
        let key = "\(payload.bundleIdentifier ?? "")|\(payload.applicationName ?? "")"
        if let source = sources[key] { return source }
        let source = NotchMediaSource(payload)
        sources[key] = source
        return source
    }

    /// Shows `payload`; `quiet` records it without a peek.
    private func apply(_ payload: TrackInfo.Payload?, quiet: Bool = false) {
        // The player, not the tab: browser tabs share their app's identity.
        let key = payload.map { "\($0.bundleIdentifier ?? "")|\($0.applicationName ?? "")" }
        if key != sourceKey {
            sourceKey = key
            source = payload.map(mediaSource)
            shuffleMode = .off
            repeatMode = .off
        }
        track = payload
        followWebSite(explicit: false)
        followTabs(explicit: false)
        kindWait.follow(player: running && source?.isBrowser == true ? sourceKey : nil, title: payload?.title, now: .now)
        updateKind()
        if let reported = payload?.shuffleMode { shuffleMode = reported }
        if let reported = payload?.repeatMode { repeatMode = reported }
        if payload?.artworkDataBase64 != artworkData {
            artworkData = payload?.artworkDataBase64
            artworkKey += 1
        }
        reportArtwork()
        let newTrack = trackWatch.update(source: sourceKey, title: payload?.title, artist: payload?.artist,
                                         album: payload?.album, playing: payload?.isPlaying == true)
        report(newTrack: newTrack && !quiet)
        followPage(newTrack: newTrack && !quiet)
    }

    var artwork: NSImage? { track?.artwork }
    /// What a site tile shows: the website's icon, else the reported artwork when that is the site's logo. Nil leaves
    /// the tile's pictogram.
    var tileIcon: NSImage? { webSite?.icon ?? (presentation?.logoArtwork == true ? artwork : nil) }
    /// What the mini peek shows as artwork: the site tile's icon for a site tile, else the track's artwork.
    var peekArtwork: NSImage? { nowPlaying?.siteTile == true ? tileIcon : artwork }

    /// Turns the shown artwork to the reported image, or waits a moment when it was removed, see `NotchArtworkFlow`.
    private func reportArtwork() {
        switch artworkFlow.report(artworkData == nil ? nil : artworkKey, at: .now) {
        case .turned:
            artworkSettle?.cancel()
            artworkSettle = nil
            shownArtwork = NotchShownArtwork(image: artworkData == nil ? nil : track?.artwork, turn: artworkFlow.turn)
            updateTint()
        case .wait(let until):
            guard artworkSettle == nil else { return }
            artworkSettle = Task { [weak self] in
                try? await Task.sleep(until: until, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.artworkSettle = nil
                self.reportArtwork()
            }
        case .unchanged:
            artworkSettle?.cancel()
            artworkSettle = nil
        }
    }

    /// Computes the shown image's tint off the main actor, once per image and only while the wave wants it; a result
    /// for an image no longer shown is dropped. The placeholder has no tint, and none is kept while unwanted, so turning
    /// the tint on never shows an earlier track's colour.
    private func updateTint() {
        guard tintsWave, let shown = artworkFlow.shown else {
            tintTask?.cancel()
            tintKey = nil
            artworkTint = nil
            return
        }
        guard shown != tintKey, shown == artworkKey, let data = artworkData else { return }
        tintKey = shown
        tintTask?.cancel()
        tintTask = Task { [weak self] in
            let tint = await Task.detached(priority: .utility) { NotchWave.tint(artwork: data) }.value
            guard let self, self.tintKey == shown, self.artworkFlow.shown == shown else { return }
            self.artworkTint = tint
        }
    }

    /// Tells the experience about a new track, or about what is now known of the playing one, if anything changed.
    /// A confirmed page names the show and the episode, or a film and its website, as the open player does.
    private func report(newTrack: Bool) {
        let playing = track?.isPlaying == true ? track : nil
        let siteTile = presentation?.siteTile == true
        let shown = playing.flatMap {
            NotchTrackPeek(title: webPage?.title ?? $0.title, artist: $0.artist, site: webPage?.subtitle ?? webSite?.name,
                           player: source?.name, browser: source?.isBrowser == true, siteTile: siteTile)
        }
        guard trackWatch.learn(shown, artwork: playing?.artworkDataBase64) || newTrack else { return }
        nowPlaying = shown
        onTrackChange?(newTrack)
    }

    /// Asks the browser again for a website a failed read left unknown, as after unlock and when the open notch shows
    /// the Music page. Unlike a metadata update, it may retry once more after the automatic retries ran out.
    func lookUpWebSite() {
        followWebSite(explicit: true)
        followTabs(explicit: true)
        updateKind()
    }

    /// Reads Safari's tabs once per browser track; app sources and previews never trigger Apple Events. A new title
    /// drops the previous site at once, and a read that failed is retried within the budget, see `NotchWebLookup`.
    private func followWebSite(explicit: Bool) {
        guard !previewWeb else { return }
        let title = running && source?.bundleIdentifier == "com.apple.Safari" ? track?.title : nil
        if title != web.title {
            for task in [webLookup, iconTask] { task?.cancel() }
            (webLookup, iconTask, iconAsked) = (nil, nil, nil)
        }
        let lookup = web.follow(title, explicit: explicit)
        if webSite != web.site { webSite = web.site }
        followIcon()
        followWebRetry()
        guard let lookup else { return }
        webLookup = Task { [weak self, netflixHeading] in
            do {
                let site = try await NotchWebSites.resolveSafari(trackTitle: lookup, netflixHeading: netflixHeading)
                guard !Task.isCancelled, let self, self.web.finish(site, for: lookup) else { return }
                self.webLookup = nil
                self.followWebRetry()
                // No site found falls back to the browser rather than leaving the previous track's site.
                self.webSite = site
                self.updateKind()
                self.report(newTrack: false)
                self.followPage()
                self.followIcon()
            } catch {
                // Cancelled lookups were already abandoned or replaced; a failed or undecided one leaves the title to
                // ask again.
                guard !Task.isCancelled, let self else { return }
                self.webLookup = nil
                self.web.fail(for: lookup)
                self.followWebRetry()
                self.updateKind()
                self.report(newTrack: false)
            }
        }
    }

    /// Comes back when the lookup's next automatic retry is due, so a tab retitled a moment after its video started
    /// is found without waiting for a metadata update. Nothing waits while locked, past the budget or once resolved.
    private func followWebRetry() {
        let at = web.retryAt
        guard at != webRetryAt else { return }
        webRetryAt = at
        webRetry?.cancel()
        webRetry = at.map { at in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self else { return }
                (self.webRetry, self.webRetryAt) = (nil, nil)
                self.followWebSite(explicit: false)
                self.updateKind()
            }
        }
    }

    /// Fetches the shown website's icon after the site itself is shown, so its layout never waits for the icon; once
    /// per site and track, and never while locked.
    private func followIcon() {
        guard let site = web.site, site.icon == nil, !webLookupsPaused, iconTask == nil, let host = site.url.host(),
              host != iconAsked else { return }
        iconAsked = host
        iconTask = Task { [weak self] in
            let icon = await NotchWebSites.icon(for: host)
            guard !Task.isCancelled, let self else { return }
            self.iconTask = nil
            guard let icon, self.web.attach(icon, host: host) else { return }
            self.webSite = self.web.site
            self.report(newTrack: false)
        }
    }

    /// Reads another browser's titles once per track for YouTube, off the main thread; Safari is read by
    /// `followWebSite`. A track not found at first is read once more half a second later, as a page may retitle its tab
    /// just after its media starts.
    private func followTabs(explicit: Bool) {
        guard !previewWeb else { return }
        let bundle = source?.bundleIdentifier
        let other = running && source?.isBrowser == true && bundle != NotchWebSites.safari
        let title = other ? track?.title : nil
        let key = bundle.flatMap { bundle in title.map { "\(bundle)|\($0)" } }
        if key != tabs.key {
            tabsTask?.cancel()
            tabsTask = nil
        }
        guard let lookup = tabs.follow(key, explicit: explicit), let bundle, let title else { return }
        tabsTask = Task { [weak self] in
            func read() async throws -> String? {
                if let host = try await NotchBrowserTabs.youTubeHost(bundle: bundle, track: title) { return host }
                try await Task.sleep(for: .seconds(0.5))
                return try await NotchBrowserTabs.youTubeHost(bundle: bundle, track: title)
            }
            let host: String??
            do { host = try await read() } catch { host = nil }
            // Cancelled reads were already abandoned or replaced; a failed or ambiguous one is read again only when
            // asked.
            guard !Task.isCancelled, let self else { return }
            self.tabsTask = nil
            if let host { self.tabs.finish(host, for: lookup) } else { self.tabs.fail(for: lookup) }
            self.updateKind()
            self.report(newTrack: false)
        }
    }

    /// Works out the kind from the website found and the reads under way, and comes back at the wait's deadline.
    private func updateKind() {
        let kind: NotchMediaKind
        if let previewKind {
            kind = previewKind
        } else if source?.isBrowser == true {
            let reading = webLookup != nil || webRetry != nil || tabsTask != nil
            kind = kindWait.kind(host: webSite?.host ?? tabs.host, reading: reading, now: .now)
        } else {
            kind = .app
        }
        if kind != self.kind { self.kind = kind }
        guard kindWait.deadline != kindExpiryAt else { return }
        kindExpiryAt = kindWait.deadline
        kindExpiry?.cancel()
        kindExpiry = kindWait.deadline.map { deadline in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self else { return }
                self.updateKind()
                self.report(newTrack: false)
            }
        }
    }

    /// The reads under way: the open player's for one track and tab while it plays or is paused, or one read for the
    /// mini peek.
    private enum PageRound: Equatable {
        case player(owner: String, playing: Bool)
        case peek(owner: String)

        var playerOwner: String? { if case .player(let owner, _) = self { owner } else { nil } }
    }

    /// Reads the playing page while the open player shows it, it needs reading and the Mac is unlocked: every couple
    /// of seconds while it has a position, otherwise only checking that the tab still shows the same video, once while
    /// paused, see `NotchWebPagePoll`. With the player closed, a Netflix track starting gets one read without
    /// JavaScript for the mini peek, no retries, skipping the text of a video already read. A new track or tab, or
    /// locking, drops the page; hiding the player, locking or the track pausing or playing restarts or stops reads,
    /// and the peek's read stops once no peek could show.
    private func followPage(newTrack: Bool = false) {
        guard !previewWeb else { return }
        let durationKnown = track?.durationMicros.map { $0.isFinite && $0 > 0 } ?? false
        let request = running ? NotchWebPageRequest(site: webSite, title: track?.title, durationKnown: durationKnown) : nil
        let owner = request.map { "\(track?.uniqueIdentifier ?? "")|\($0.address)" }
        let locked = webLookupsPaused
        let changed = pages.follow(owner: owner, locked: locked)
        if let request, let owner, NotchWebPagePoll.active(request, onScreen: watchesPage, locked: locked) {
            let round = PageRound.player(owner: owner, playing: track?.isPlaying == true)
            if round != pageRound {
                // A pause or a resume continues the player's reads; reads starting anew check the tab again first.
                if pageRound?.playerOwner != owner { pages.begin(now: .now) }
                readPage(request, round: round)
            }
        } else if let request, let owner, request.text, peeksPages, !locked, changed || newTrack {
            pages.begin(now: .now)
            readPage(request, round: .peek(owner: owner))
        } else if pageRound?.playerOwner != nil || !peeksPages || changed || locked {
            pageTask?.cancel()
            pageTask = nil
            pageRound = nil
        }
        showPage()
    }

    /// Runs one round of page reads, replacing the one under way.
    private func readPage(_ request: NotchWebPageRequest, round: PageRound) {
        pageTask?.cancel()
        pageRound = round
        let player = round.playerOwner != nil
        // The player starts by checking a video it already named; the peek's one read skips any video already read.
        let start = NotchWebPagePoll(known: player ? pages.page : nil)
        let peekKnown = pages.known
        pageTask = Task { [weak self] in
            var poll = start
            while !Task.isCancelled {
                let known = player ? poll.known : peekKnown
                let outcome = await NotchWebPages.read(request, known: known, javaScript: player)
                guard !Task.isCancelled, let self else { return }
                self.pages.land(outcome, now: .now)
                self.awaitLapse()
                self.showPage()
                guard player, let wait = poll.next(after: outcome, playing: self.track?.isPlaying == true) else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Withdraws the shown page at its lapse, when failing reads stopped renewing it; a read since moves or clears it.
    private func awaitLapse() {
        pageLapse?.cancel()
        pageLapse = nil
        guard let lapse = pages.lapse else { return }
        pageLapse = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, lapse.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.pages.expire(now: .now)
            self.showPage()
        }
    }

    /// Publishes the page as confirmed, and tells the mini peek, which may still be settling or showing.
    private func showPage() {
        guard pages.shown != webPage else { return }
        webPage = pages.shown
        if webSite?.host == "netflix.com", let heading = webPage.flatMap(NotchWebSites.NetflixHeading.init) {
            netflixHeading = heading
        }
        if source?.bundleIdentifier == NotchWebSites.safari, let content = webPage?.content, !content.isEmpty {
            safariVideo = content
        }
        report(newTrack: false)
    }

    /// How the open player presents the playing track, nil without one.
    var presentation: NotchPlayerPresentation? {
        guard let track else { return nil }
        return NotchPlayerPresentation(title: track.title, artist: track.artist, duration: track.durationMicros.map { $0 / 1_000_000 },
                                       hasArtwork: track.artworkDataBase64 != nil, player: source?.name ?? "System player",
                                       kind: kind, site: webSite, page: webPage)
    }

    /// Where a like for the current track goes: Music, the YouTube tab once Safari's tabs are read for this track and
    /// its title names it, or nowhere meanwhile.
    var likeTarget: NotchLikeTarget {
        let page = webSite.flatMap { $0.matchesTrack ? $0.url : nil }
        return track == nil ? .unsupported : NotchLikeTarget(bundleIdentifier: source?.bundleIdentifier, page: page)
    }

    /// The current track's like request, or nil when nothing plays or its player has no like.
    var likeRequest: NotchLikeRequest? {
        guard let track, likeTarget != .unsupported else { return nil }
        return NotchLikeRequest(target: likeTarget, track: track.uniqueIdentifier, title: track.title ?? "",
                                artist: track.artist ?? "")
    }

    /// Brings the source forward: the playing Safari tab for websites, otherwise the player app.
    func showSource() {
        if let webSite {
            NotchWebSites.showSafariTab(webSite.url)
        } else if let bundle = source?.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// What the player's buttons can reach: `transport` is previous, play or pause and next; `modes` adds shuffle,
    /// repeat and seeking. MediaRemote commands only the system's player, so a player followed beside it gets the
    /// transport through AppleScript when it is Spotify or Music and no buttons otherwise.
    enum Reach { case transport, modes }

    func reaches(_ reach: Reach) -> Bool {
        guard track != nil else { return false }
        guard case .other(let app, _) = pick.followed else { return true }
        return reach == .transport && NotchScriptedPlayer.notifications[app] != nil
    }

    /// Sends a transport command to the shown player: through MediaRemote to the system's, through AppleScript to
    /// Spotify or Music followed beside it, which asks for the Automation permission on the first press and is read
    /// again once the command ran, in case its notification does not come and it is still followed.
    private func command(_ script: String, system: () -> Void) {
        switch pick.followed {
        case .system: system()
        case .other(let app, _) where NotchScriptedPlayer.notifications[app] != nil:
            Task { [weak self] in
                _ = await NotchWebSites.osascript("tell application id \"\(app)\" to \(script)", automating: app)
                self?.readPlayer(app)
            }
        case .other: break
        }
    }

    func togglePlayback() {
        guard running, reaches(.transport) else { return }
        pick.paused()
        command("playpause", system: adapter.togglePlayPause)
    }

    /// Next and previous do nothing where the player shows neither, so a swipe does not skip there either.
    func next() {
        guard running, reaches(.transport), kind.skips else { return }
        artworkFlow.skipped(.next, at: .now)
        command("next track", system: adapter.nextTrack)
    }

    func previous() {
        guard running, reaches(.transport), kind.skips else { return }
        artworkFlow.skipped(.previous, at: .now)
        command("previous track", system: adapter.previousTrack)
    }

    func shuffle() {
        guard running, reaches(.modes) else { return }
        adapter.toggleShuffle()
        if track?.shuffleMode == nil { shuffleMode = shuffleMode == .off ? .songs : .off }
    }

    /// Players cycle off, all, one; the assumed order only matters while the player reports nothing.
    func repeatTrack() {
        guard running, reaches(.modes) else { return }
        adapter.toggleRepeat()
        guard track?.repeatMode == nil else { return }
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }
    /// Seeks through MediaRemote; the bar offers it only where `NotchPlayerPresentation` allows.
    func seek(to seconds: Double) {
        guard running, reaches(.modes), let duration = track?.durationMicros, duration.isFinite, duration > 0, seconds.isFinite else { return }
        adapter.setTime(seconds: min(max(seconds, 0), duration / 1_000_000))
    }
}

extension TrackInfo.Payload {
    /// What Spotify or Music says about its track over its last report: the app stays, the artwork stays for the same
    /// track, and the position is the one read, else the report's carried on for the same track.
    init(_ player: NotchScriptedPlayer, over old: TrackInfo.Payload) {
        let same = player.title == old.title && player.artist == old.artist
        let elapsed = player.position ?? (same ? old.currentElapsedTime : nil)
        self.init(title: player.title, artist: player.artist, album: player.album, isPlaying: player.playing,
                  durationMicros: player.duration.map { $0 * 1_000_000 } ?? (same ? old.durationMicros : nil),
                  elapsedTimeMicros: elapsed.map { $0 * 1_000_000 }, applicationName: old.applicationName,
                  bundleIdentifier: old.bundleIdentifier, artworkDataBase64: same ? old.artworkDataBase64 : nil,
                  artworkMimeType: same ? old.artworkMimeType : nil, timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000,
                  PID: old.PID, shuffleMode: old.shuffleMode, repeatMode: old.repeatMode, playbackRate: player.playing ? 1 : 0,
                  artwork: same ? old.artwork : nil)
    }

    /// This report with `data` as its artwork.
    func with(artwork data: Data) -> TrackInfo.Payload {
        TrackInfo.Payload(title: title, artist: artist, album: album, isPlaying: isPlaying, durationMicros: durationMicros,
                          elapsedTimeMicros: elapsedTimeMicros, applicationName: applicationName, bundleIdentifier: bundleIdentifier,
                          artworkDataBase64: data.base64EncodedString(), artworkMimeType: nil,
                          timestampEpochMicros: timestampEpochMicros, PID: PID, shuffleMode: shuffleMode, repeatMode: repeatMode,
                          playbackRate: playbackRate, artwork: NSImage(data: data))
    }

    /// This report as playing or paused from now, its position carried on from when it was made.
    func `as`(playing: Bool) -> TrackInfo.Payload {
        let elapsed = currentElapsedTime.map { $0 * 1_000_000 } ?? elapsedTimeMicros
        return TrackInfo.Payload(title: title, artist: artist, album: album, isPlaying: playing, durationMicros: durationMicros,
                                 elapsedTimeMicros: elapsed, applicationName: applicationName, bundleIdentifier: bundleIdentifier,
                                 artworkDataBase64: artworkDataBase64, artworkMimeType: artworkMimeType,
                                 timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000, PID: PID,
                                 shuffleMode: shuffleMode, repeatMode: repeatMode, playbackRate: playing ? 1 : 0, artwork: artwork)
    }
}

/// The artwork shown for the playing track and the turn that brought it.
struct NotchShownArtwork: Equatable {
    var image: NSImage?
    var turn = NotchArtworkFlow.Turn()
}
