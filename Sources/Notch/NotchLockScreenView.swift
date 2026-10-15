import AppKit
import Combine
import MediaRemoteAdapter
import os
import SwiftUI

/// The lock screen: while the Mac is locked the normal notch is concealed, so nothing private can be opened
/// or shown, and windows of their own draw above the lock screen instead: the closed notch with a lock in the left
/// wing, the media widget, and while its artwork is enlarged a colour wash behind it. They only draw what they are
/// given and never take the keyboard. On unlock the shackle opens, the wing retracts, the normal notch returns and the
/// windows and their space are removed.
@MainActor
final class NotchLockScreenController: ObservableObject {
    let monitor = NotchLockMonitor()
    /// The widget is on screen. It shows while locked with a track, and leaves 1.5 s after the track does, so the
    /// gap between two tracks does not flicker.
    @Published private(set) var mediaShown = false
    /// The last track, kept through that gap.
    @Published private(set) var track: TrackInfo.Payload?
    /// How the widget shows that track, kept with it, so the controls and the tile stay as they were through the gap.
    @Published private(set) var look: NotchLockMediaLook?
    /// The notch the lock wing draws around.
    @Published private(set) var geometry = NotchGeometry.fallback
    /// The widget, the enlarged artwork and their window on the main display; nil while it is too short to hold them.
    @Published private(set) var stage: NotchLockStage?
    /// The display the stage was laid out on: two displays of the same size give equal stages.
    private var stageDisplay: String?
    /// Whether the artwork is enlarged, see `NotchLockArtState`.
    @Published private(set) var art = NotchLockArtState()
    /// The wash's colours for the shown artwork; nil without artwork or until read.
    @Published private(set) var palette: NotchLockPalette?
    private let experience: NotchExperience
    private let space = NotchLockSpace()
    private var wing: NotchLockPanel?
    /// The widget's window, which grows over the band above it while the artwork is enlarged. It takes clicks only
    /// where it draws, see `NotchLockPanel`.
    private var widget: NotchLockPanel?
    /// The colour wash over the whole main display, only while the artwork is enlarged or shrinking.
    private var backdrop: NotchLockPanel?
    private var artStep: Task<Void, Never>?
    private var paletteTask: Task<Void, Never>?
    /// Palettes by artwork, so a track coming back costs nothing; emptied once it holds `paletteLimit`.
    private var palettes: [Int: NotchLockPalette] = [:]
    private var paletteKey: Int?
    private static let paletteLimit = 24
    private var subscriptions: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var mediaGrace: Task<Void, Never>?
    private var teardown: Task<Void, Never>?
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "lock")

    /// How long the windows outlive an unlock: until the normal notch is on screen underneath and a closing spring
    /// slower than the retract step has settled.
    private var handover: Double {
        max(0.15, experience.settings.closeAnimationDuration - NotchLockState.retractDuration + 0.05)
    }
    private static let mediaGracePeriod: Double = 1.5

    init(experience: NotchExperience) {
        self.experience = experience
    }

    func start() {
        guard subscriptions.isEmpty else { return }
        monitor.onChange = { [weak self] in self?.stateChanged() }
        // Published values arrive before they are stored; the main run loop hands them over afterwards.
        experience.$settings.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        experience.$hidden.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        // The track, and what decides how it shows.
        let media = experience.media
        Publishers.Merge4(media.$track.map { _ in }, media.$webSite.map { _ in }, media.$webPage.map { _ in },
                          media.$kind.map { _ in })
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateMedia() }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        log.notice("Lock screen space \(NotchLockSpace.available ? "available" : "unavailable", privacy: .public)")
        monitor.start()
    }

    func stop() {
        monitor.onChange = nil
        monitor.stop()
        subscriptions.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        mediaGrace?.cancel()
        mediaGrace = nil
        changeArt { $0.cut() }
        paletteTask?.cancel()
        paletteTask = nil
        dismantle()
        experience.locked = false
    }

    private func stateChanged() {
        let state = monitor.state
        log.notice("Lock \(String(describing: state.phase), privacy: .public), covered by \(state.covers.count)")
        if experience.locked != state.secured { experience.locked = state.secured }
        // Without a lock on screen there is nothing to animate; the notch comes back at once.
        if state.phase == .opening, wing == nil {
            monitor.skipUnlockAnimation()
            return
        }
        refresh()
    }

    private func refresh() {
        updateMedia()
        layout()
    }

    /// Shows the widget at once when it is wanted; a missing track hides it after the grace period, anything else
    /// (unlocking, the switch, the windows going) at once. The enlarged artwork follows: cut with the lock screen,
    /// shrunk with the widget, kept through a new track with its wait started over.
    private func updateMedia() {
        let state = monitor.state
        let settings = experience.settings
        let enabled = state.phase == .locked && state.presented && settings.lockScreenMedia && !experience.hidden
        if enabled, let current = experience.media.track {
            mediaGrace?.cancel()
            mediaGrace = nil
            if track?.uniqueIdentifier != current.uniqueIdentifier || track?.artworkDataBase64 != current.artworkDataBase64 {
                changeArt { $0.trackChanged() }
            }
            track = current
            let look = NotchLockMediaLook(media: experience.media, track: current)
            if look != self.look { self.look = look }
            if !mediaShown { mediaShown = true }
        } else if enabled, mediaShown {
            // The grace runs once; the enlarged artwork and the palette below still follow every change.
            if mediaGrace == nil {
                mediaGrace = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.mediaGracePeriod))
                    guard !Task.isCancelled, let self else { return }
                    self.mediaGrace = nil
                    self.mediaShown = false
                    self.changeArt { $0.collapse() }
                }
            }
        } else {
            mediaGrace?.cancel()
            mediaGrace = nil
            if mediaShown { mediaShown = false }
        }
        let available = enabled && settings.lockScreenArtTap
        changeArt { $0.follow(available: available, shown: mediaShown) }
        updatePalette(wanted: available && mediaShown)
    }

    /// A tap on the artwork, or on the widget's title while the artwork is enlarged.
    func toggleArt() {
        guard art.staged || (mediaShown && experience.settings.lockScreenArtTap && stage?.canEnlarge == true
                             && track?.artwork != nil)
        else { return }
        changeArt { $0.tap() }
    }

    /// Changes the artwork's state, resizes the windows when it comes out or is fully back, and schedules its next
    /// step: the idle wait while enlarged, the settling while it shrinks.
    private func changeArt(_ change: (inout NotchLockArtState) -> Void) {
        var next = art
        change(&next)
        guard next != art else { return }
        let staged = art.staged
        art = next
        if next.staged != staged { layout() }
        artStep?.cancel()
        artStep = nil
        let generation = next.generation
        let step: (delay: Double, change: (inout NotchLockArtState) -> Void)
        switch next.phase {
        case .expanded: step = (NotchLockArtState.idleTimeout, { $0.idle(generation) })
        case .collapsing: step = (NotchLockArtState.settleDuration, { $0.settled(generation) })
        case .collapsed: return
        }
        artStep = Task { [weak self] in
            try? await Task.sleep(for: .seconds(step.delay))
            guard !Task.isCancelled, let self else { return }
            self.artStep = nil
            self.changeArt(step.change)
        }
    }

    /// Reads the shown artwork's colours off the main thread while the enlarged artwork can show, once per artwork;
    /// until they arrive the wash keeps the previous colours, then crossfades.
    private func updatePalette(wanted: Bool) {
        guard wanted, let data = track?.artworkDataBase64 else {
            paletteTask?.cancel()
            paletteTask = nil
            paletteKey = nil
            if wanted, palette != nil { palette = nil }
            return
        }
        let key = data.hashValue
        guard key != paletteKey else { return }
        paletteKey = key
        paletteTask?.cancel()
        paletteTask = nil
        if let cached = palettes[key] {
            palette = cached
            return
        }
        paletteTask = Task { [weak self] in
            let read = await Task.detached(priority: .utility) { NotchLockPalette(artwork: data) }.value ?? .neutral
            guard !Task.isCancelled, let self, self.paletteKey == key else { return }
            self.paletteTask = nil
            if self.palettes.count >= Self.paletteLimit { self.palettes.removeAll() }
            self.palettes[key] = read
            self.palette = read
        }
    }

    /// Puts the windows where the state, settings and displays want them, or takes them down. The lock goes on the
    /// notch's display, the widget on the main display, where macOS shows the login controls, unless that display is
    /// too short to keep it clear of the clock and the login block. While the artwork is out the widget's window also
    /// covers the band above it, and the wash covers the display beneath both.
    func layout() {
        let state = monitor.state
        guard state.presented, !experience.hidden else {
            // After an unlock the normal notch is back first; anything else hides them at once.
            if state.secured || experience.hidden { dismantle() } else { scheduleTeardown() }
            return
        }
        teardown?.cancel()
        teardown = nil
        let settings = experience.settings
        let screens = NSScreen.screens
        let displays = screens.enumerated().map { NotchDisplay(screen: $1, isMain: $0 == 0) }
        if settings.lockIcon, let target = NotchDisplay.resolve(settings.display, in: displays),
           let screen = screens.first(where: { NotchDisplay.id(of: $0) == target.id }) {
            let next = NotchGeometry(screen: screen, settings: settings)
            if geometry != next { geometry = next }
            wing = place(wing, frame: next.frame(.indicator)) { wingView }
            wing?.ignoresMouseEvents = true
        } else {
            close(&wing)
        }
        let next = settings.lockScreenMedia ? screens.first.flatMap {
            NotchLockScreenLayout.stage(in: $0.frame, offset: settings.lockScreenWidgetOffset)
        } : nil
        let nextDisplay = screens.first.map(NotchDisplay.id(of:))
        if stage != next || stageDisplay != nextDisplay {
            // Another display, even one of the same size, or another size or offset: the artwork goes back to the
            // tile at once and its timer stops, before the windows move. The cut lays them out again on the new stage.
            changeArt { $0.cut() }
            stageDisplay = nextDisplay
            if stage != next { stage = next }
        }
        if let next {
            // The widget's window keeps its default event routing: setting `ignoresMouseEvents` would make it take
            // clicks everywhere or nowhere. A hidden widget draws nothing, so it takes none.
            widget = place(widget, frame: art.staged ? next.frame : next.widget) { stageView() }
            if art.staged {
                // Below the widget, and never in the way: clicks reach the lock screen underneath.
                backdrop = place(backdrop, frame: next.screen, level: .statusBar + 1) { washView() }
                backdrop?.ignoresMouseEvents = true
            } else {
                close(&backdrop)
            }
        } else {
            close(&widget)
            close(&backdrop)
        }
        let sharing: NSWindow.SharingType = settings.hideFromScreenCapture ? .none : .readOnly
        for panel in [wing, widget, backdrop].compactMap({ $0 }) where panel.sharingType != sharing { panel.sharingType = sharing }
    }

    /// Moves an existing window or creates one and lifts it above the lock screen.
    private func place<Content: View>(_ existing: NotchLockPanel?, frame: CGRect, level: NSWindow.Level = .statusBar + 2,
                                      content: () -> Content) -> NotchLockPanel {
        if let existing {
            if existing.frame != frame { existing.setFrame(frame, display: true) }
            return existing
        }
        let panel = NotchLockPanel(frame: frame, level: level, content: content())
        panel.orderFrontRegardless()
        if !space.adopt(panel) { log.error("Could not lift a window above the lock screen") }
        return panel
    }

    /// Takes a window out of the space, which goes with the last one, and closes it.
    private func close(_ panel: inout NotchLockPanel?) {
        guard let window = panel else { return }
        space.remove(window)
        window.orderOut(nil)
        window.close()
        panel = nil
    }

    private func scheduleTeardown() {
        guard wing != nil || widget != nil || backdrop != nil || space.active, teardown == nil else { return }
        let delay = handover
        teardown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.teardown = nil
            if !self.monitor.state.presented { self.dismantle() }
        }
    }

    /// The notch's own springs from the settings, so the wings move like the rest of it.
    var motion: NotchMotion { NotchMotion(experience.settings) }

    /// The lock wing, the media widget alone, the widget with its enlarged artwork, and the wash, live from this
    /// controller. Renders pass a fixed point of the artwork's flight.
    var wingView: some View { NotchLockWing(controller: self, monitor: monitor) }
    var widgetView: some View { NotchLockMediaWidget(controller: self, media: experience.media, experience: experience) }
    func stageView(progress: Double? = nil) -> some View {
        NotchLockStageView(controller: self, media: experience.media, experience: experience, progress: progress)
    }
    func washView(progress: Double? = nil) -> some View { NotchLockWash(controller: self, progress: progress) }

    /// For fixture renders only: puts the views in a phase with a track on a screen, the artwork enlarged if asked,
    /// without windows, timers or system signals.
    func preview(_ phase: NotchLockPhase, track: TrackInfo.Payload?, geometry: NotchGeometry,
                 screen: CGRect = CGRect(x: 0, y: 0, width: 1470, height: 956), enlarged: Bool = false) {
        monitor.apply { state in
            state.lock()
            if phase != .locked { state.unlock() }
            if phase == .retracting { state.opened() }
        }
        self.track = track
        look = track.map { NotchLockMediaLook(media: experience.media, track: $0) }
        mediaShown = track != nil && phase == .locked
        self.geometry = geometry
        stage = NotchLockScreenLayout.stage(in: screen, offset: 0)
        if enlarged, !art.expanded { art.tap() }
        palette = track?.artworkDataBase64.flatMap(NotchLockPalette.init(artwork:))
    }

    /// Takes the windows out of the space, destroys it and closes them: nothing outlives the lock.
    private func dismantle() {
        teardown?.cancel()
        teardown = nil
        space.release()
        close(&wing)
        close(&widget)
        close(&backdrop)
    }
}

/// A transparent window above the lock screen that never takes the keyboard. Left at its default event routing, the
/// window server sends it a click only where it draws: the widget's rounded shape and the artwork. Clicks on empty
/// areas, shadows, the corners outside a clipped shape and views at opacity 0 reach the lock screen underneath, so
/// macOS's own controls there, such as the Accessibility Keyboard, stay usable wherever they appear. `--hit-probe`
/// checks this for the stage.
final class NotchLockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A borderless panel at `level` holding `content`, not yet on screen.
    convenience init(frame: CGRect, level: NSWindow.Level, content: some View) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        title = "Lock screen"
        let hosting = NSHostingView(rootView: content)
        // The frame is set here alone: the widget's content is laid out for its large frame even while the window
        // holds only the widget, and must not grow the window.
        hosting.sizingOptions = []
        contentView = hosting
    }
}

/// The closed notch on the lock screen: the wings grow out like an indicator with a lock on the left. Unlocking
/// opens the shackle with a short scale and glow, then the wings retract on the closing spring and the lock fades
/// with them. Reduce Motion swaps the symbol with a crossfade and the outline changes at once.
private struct NotchLockWing: View {
    @ObservedObject var controller: NotchLockScreenController
    @ObservedObject var monitor: NotchLockMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False until the first frame, so the wings grow out of the closed notch rather than appear.
    @State private var grown = false
    @State private var beats = 0

    var body: some View {
        let geometry = controller.geometry
        let phase = monitor.state.phase
        let out = grown && (phase == .locked || phase == .opening)
        let shape: NotchShape = out ? .indicator : .closed
        let size = geometry.frame(shape).size
        HStack(spacing: 0) {
            Image(systemName: phase == .locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.magic(fallback: .replace.downUp)))
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.25), value: phase == .locked)
                .keyframeAnimator(initialValue: 0.0, trigger: beats) { content, beat in
                    content.scaleEffect(1 + 0.18 * beat).shadow(color: .white.opacity(0.6 * beat), radius: 6 * beat)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1, duration: 0.16, spring: .snappy)
                        SpringKeyframe(0, duration: 0.42, spring: .smooth)
                    }
                }
                .frame(width: geometry.wingWidth + NotchGeometry.hudWingExtra, height: geometry.topHeight)
                .opacity(out ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(.black)
        .clipShape(NotchOutline(cornerRadius: geometry.cornerRadius(shape)))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : out ? controller.motion.open : controller.motion.close, value: out)
        .onAppear { grown = true }
        .onChange(of: phase) { _, phase in if phase == .opening, !reduceMotion { beats += 1 } }
        .accessibilityElement()
        .accessibilityLabel(phase == .locked ? "Locked" : "Unlocked")
    }
}

/// Now Playing on the lock screen, like an iPhone's: artwork, title, artist (the website for browser video), a
/// progress line and previous, play or pause and next. Generic web media keeps play or pause alone, and fades the line
/// out in place without times, as in the open player. It fades and settles in from slightly smaller, and a new
/// track crossfades in place. The line moves once a second, only while playing and shown. A tap on the artwork
/// enlarges it: the tile leaves its place to the flying artwork and the title slides into its slot; a tap on the title
/// brings it back. Under Reduce Motion the tile and the title stay put.
private struct NotchLockMediaWidget: View {
    @ObservedObject var controller: NotchLockScreenController
    @ObservedObject var media: NotchMedia
    @ObservedObject var experience: NotchExperience
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False until the first frame, so the widget also fades in when it is there from the moment of locking.
    @State private var appeared = false

    var body: some View {
        let settings = experience.settings
        let shown = controller.mediaShown && appeared
        let size = NotchLockScreenLayout.widgetSize
        let tile = NotchLockScreenLayout.tile
        // The artwork is out: the slot closes, unless motion is reduced.
        let away = controller.art.expanded && !reduceMotion
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                artwork
                    .frame(width: away ? 0 : tile.width, alignment: .leading)
                    .padding(.trailing, away ? 0 : 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .id(controller.track?.uniqueIdentifier)
                .transition(.opacity)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { if controller.art.expanded { controller.toggleArt() } }
            Group {
                if shown, controller.track?.isPlaying == true, line {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in progress }
                } else {
                    progress
                }
            }
            .revealed(line)
            HStack(spacing: 44) {
                control("backward.fill", "Previous track", size: 20, action: media.previous).revealed(skips)
                control(controller.track?.isPlaying == true ? "pause.fill" : "play.fill", "Play or pause", size: 26,
                        action: media.togglePlayback)
                control("forward.fill", "Next track", size: 20, action: media.next).revealed(skips)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(width: size.width, height: size.height)
        .background {
            ZStack {
                NotchLockGlassView(style: settings.lockScreenGlass, cornerRadius: NotchLockScreenLayout.cornerRadius)
                    .id(settings.lockScreenGlass)
                Color.black.opacity(settings.lockScreenDimming)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: NotchLockScreenLayout.cornerRadius, style: .continuous))
        .foregroundStyle(.white)
        .colorScheme(.dark)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduceMotion ? 1 : 0.94)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.55, bounce: 0.12), value: shown)
        .animation(.easeInOut(duration: 0.3), value: controller.track?.uniqueIdentifier)
        .allowsHitTesting(shown)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing")
        .accessibilityHidden(!shown)
    }

    private var presentation: NotchPlayerPresentation? { controller.look?.presentation }
    private var title: String { controller.look?.title ?? "" }
    private var subtitle: String { controller.look?.subtitle ?? "" }

    /// The site's logo stands in for the artwork, as Netflix's, so there is nothing to enlarge.
    private var siteTile: Bool { presentation?.siteTile == true }

    /// Previous and next, unless generic web media plays, which handles neither, or its website is still being read.
    private var skips: Bool { presentation?.skips ?? true }

    /// The progress line, faded out in its place for generic web media without times, so nothing moves.
    private var line: Bool { !(presentation?.kind == .genericWeb && presentation?.progress == .hidden) }

    /// The tile, a button that enlarges it. While the artwork is out the flying copy draws it instead.
    private var artwork: some View {
        let hidden = controller.art.staged && !reduceMotion
        return Button(action: controller.toggleArt) {
            Group {
                if siteTile {
                    NotchSiteTile(icon: controller.look?.tileIcon, size: 52, glyph: presentation?.kind != .pending)
                } else if let image = controller.track?.artwork {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: 20)).frame(width: 52, height: 52)
                        .background(.white.opacity(0.12))
                }
            }
            .frame(width: 52, height: 52)
            .notchArtworkTile(cornerRadius: NotchLockScreenLayout.tileRadius)
            .id(controller.track?.uniqueIdentifier)
            .transition(.opacity)
        }
        .buttonStyle(.plain)
        .disabled(!experience.settings.lockScreenArtTap || controller.track?.artwork == nil || siteTile)
        .opacity(hidden ? 0 : 1)
        // The flying copy takes over in the same frame, so the swap must not fade.
        .animation(nil, value: hidden)
        .allowsHitTesting(!hidden)
        .accessibilityLabel("Enlarge artwork")
    }

    private var progress: some View {
        let micros = controller.track?.durationMicros ?? 0
        let duration = micros.isFinite && micros > 0 ? micros / 1_000_000 : 0
        let elapsed = controller.track?.currentElapsedTime ?? 0
        let fraction = duration > 0 && elapsed.isFinite ? min(1, max(0, elapsed / duration)) : 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private func control(_ symbol: String, _ label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .frame(width: 36, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .accessibilityLabel(label)
        .disabled(!media.reaches(.transport))
        .opacity(media.reaches(.transport) ? 1 : 0.35)
    }
}

/// What the lock screen widget shows of a track besides its payload, worked out from the media while the track plays.
struct NotchLockMediaLook: Equatable {
    /// How the open player presents the track.
    let presentation: NotchPlayerPresentation?
    /// The show a confirmed page names, or the track's title. Locking drops the page, since nothing may check the tab
    /// meanwhile, so Netflix shows as itself on its site tile rather than an episode that may have moved on.
    let title: String
    /// The website for browser video, or the episode a page named; never the title again, as Netflix's "Netflix".
    let subtitle: String
    let tileIcon: NSImage?

    @MainActor
    init(media: NotchMedia, track: TrackInfo.Payload) {
        presentation = track.uniqueIdentifier == media.track?.uniqueIdentifier ? media.presentation : nil
        title = presentation?.title ?? track.title ?? ""
        if media.source?.isBrowser == true {
            let site = media.webPage?.subtitle ?? media.webSite?.name ?? track.artist ?? ""
            subtitle = site == title ? media.source?.name ?? "" : site
        } else {
            subtitle = track.artist ?? media.source?.name ?? "System player"
        }
        tileIcon = media.tileIcon
    }
}

/// The widget's material: Liquid Glass (`NSGlassEffectView`, macOS 26 and later) in its regular or clear style, or a
/// frosted blur, which is also the fallback on older macOS.
private struct NotchLockGlassView: NSViewRepresentable {
    let style: NotchLockGlass
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *), style != .frosted {
            let glass = NSGlassEffectView()
            glass.style = style == .clear ? .clear : .regular
            glass.cornerRadius = cornerRadius
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        return blur
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The widget and its enlarged artwork in one view the size of the widget's large window, the widget at its bottom and
/// the artwork with room around it for its shadow and overshoot. The window holds only the widget until the artwork
/// comes out; the content keeps its place either way. The padding and the gap draw nothing but the shadow, so clicks
/// there reach the lock screen. The artwork flies from the tile to its large place and back on one unhurried spring;
/// Reduce Motion fades it in at its large place instead.
private struct NotchLockStageView: View {
    @ObservedObject var controller: NotchLockScreenController
    let media: NotchMedia
    let experience: NotchExperience
    /// A fixed point of the flight for renders; nil follows the state.
    var progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let stage = controller.stage { content(stage) }
    }

    private func content(_ stage: NotchLockStage) -> some View {
        let frame = stage.frame
        let widget = stage.local(stage.widget, in: frame)
        let art = controller.art
        let flight = NotchLockArtFlight(progress: progress ?? (art.expanded ? 1 : 0),
                                        tile: NotchLockScreenLayout.tile.offsetBy(dx: widget.minX, dy: widget.minY),
                                        large: stage.local(stage.art, in: frame), reduceMotion: reduceMotion)
        return ZStack(alignment: .topLeading) {
            NotchLockMediaWidget(controller: controller, media: media, experience: experience)
                .offset(x: widget.minX, y: widget.minY)
            NotchLockLargeArt(controller: controller)
                // The tile hides in the same frame, so the copy appears without a fade.
                .opacity(art.staged || progress != nil ? 1 : 0)
                .animation(nil, value: art.staged)
                .modifier(flight)
                .allowsHitTesting(art.staged)
                .onTapGesture(perform: controller.toggleArt)
                .accessibilityElement()
                .accessibilityLabel("Artwork")
                .accessibilityAddTraits(.isButton)
                .accessibilityHidden(!art.expanded)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .animation(art.animated ? motion(art.expanded) : nil, value: art.expanded)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottom)
    }

    /// Growing settles with a trace of overshoot; shrinking lands on the tile without one.
    private func motion(_ expanding: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.35) }
        return expanding ? .spring(duration: 0.8, bounce: 0.14) : .spring(duration: 0.7, bounce: 0.04)
    }
}

/// The enlarged artwork's picture; a new track crossfades in place.
private struct NotchLockLargeArt: View {
    @ObservedObject var controller: NotchLockScreenController

    var body: some View {
        ZStack {
            Group {
                if let image = controller.track?.artwork {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    GeometryReader { geometry in
                        Image(systemName: "music.note").font(.system(size: geometry.size.width * 0.36))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .background(Color(white: 0.16))
                }
            }
            .id(controller.track?.uniqueIdentifier)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.6), value: controller.track?.uniqueIdentifier)
    }
}

/// Places the artwork between the tile (progress 0) and its large place (1): frame, corner radius and a shadow that
/// grows as it lifts. A spring's overshoot carries it a little past its large size before it settles. Under Reduce
/// Motion it stays at its large place and progress fades it.
private struct NotchLockArtFlight: ViewModifier, Animatable {
    var progress: Double
    let tile: CGRect
    let large: CGRect
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = CGFloat(progress)
        let lift = min(max(p, 0), 1)
        let rect = reduceMotion ? large : CGRect(x: tile.minX + (large.minX - tile.minX) * p,
                                                 y: tile.minY + (large.minY - tile.minY) * p,
                                                 width: max(0, tile.width + (large.width - tile.width) * p),
                                                 height: max(0, tile.height + (large.height - tile.height) * p))
        let radius = reduceMotion ? NotchLockScreenLayout.artRadius
            : NotchLockScreenLayout.tileRadius + (NotchLockScreenLayout.artRadius - NotchLockScreenLayout.tileRadius) * lift
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .frame(width: rect.width, height: rect.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45 * lift), radius: 30 * lift, y: 12 * lift)
            .opacity(reduceMotion ? Double(lift) : 1)
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// The colour wash while the artwork is enlarged: a mesh of the artwork's 3 × 3 region colours over the whole main
/// display, its middle row on the artwork's centre. It sits above the lock screen, so it fades toward the clock and the
/// login block rather than covering them (see `NotchLockStage.washStops`): they keep their own colours and stay crisp,
/// while the wallpaper around the artwork takes its colours. It fades in more slowly than the artwork flies, a new
/// artwork's colours crossfade, and it holds still otherwise. Its window ignores the mouse.
private struct NotchLockWash: View {
    @ObservedObject var controller: NotchLockScreenController
    /// A fixed opacity for renders; nil follows the state.
    var progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False until the first frame, so the wash fades in when its window comes.
    @State private var appeared = false
    private static let peak = 0.9

    var body: some View {
        if let stage = controller.stage { wash(stage) }
    }

    private func wash(_ stage: NotchLockStage) -> some View {
        let palette = controller.palette ?? .neutral
        let shown = progress ?? (controller.art.expanded && appeared ? 1 : 0)
        let middle = Float(min(max((stage.screen.maxY - stage.art.midY) / max(stage.screen.height, 1), 0.2), 0.8))
        let points: [SIMD2<Float>] = [0, middle, 1].flatMap { y in [0, 0.5, 1].map { SIMD2<Float>($0, y) } }
        return ZStack {
            MeshGradient(width: 3, height: 3, points: points,
                         colors: palette.colors.map { Color(.sRGB, red: $0.x, green: $0.y, blue: $0.z) })
                .id(palette)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.8), value: palette)
        .mask {
            LinearGradient(stops: stage.washStops.map { Gradient.Stop(color: .white.opacity($0.opacity), location: $0.location) },
                           startPoint: .top, endPoint: .bottom)
        }
        .opacity(shown * Self.peak)
        .animation(reduceMotion ? .easeInOut(duration: 0.35) : .easeInOut(duration: shown > 0 ? 1 : 0.7), value: shown)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { appeared = true }
    }
}
