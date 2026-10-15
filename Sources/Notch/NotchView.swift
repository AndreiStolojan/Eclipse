import AppKit
import SwiftUI

/// A camera-safe native view for the standalone notch app.
struct NotchView: View {
    @ObservedObject var experience: NotchExperience
    var animateTransitions = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The outline's size as last drawn, so a change can tell whether the outline grows or shrinks.
    @State private var drawnSize: CGSize?

    private var geometry: NotchGeometry { experience.geometry ?? .fallback }
    private var topHeight: CGFloat { geometry.topHeight }
    private var expanded: Bool { experience.state.expanded }
    private var hud: NotchHUD? { experience.state.hud }
    private var shape: NotchShape { experience.state.shape }
    private var screenshot: URL? { experience.state.screenshot.url }
    private var visibleSize: CGSize { geometry.frame(shape).size }

    var body: some View {
        ZStack(alignment: .top) {
            // The screenshot stays mounted, hidden, under the drop targets its own drag opens, so the drag source
            // lives until the drag ends.
            if let screenshot {
                let size = geometry.frame(.screenshot).size
                NotchScreenshotPeek(url: screenshot, experience: experience, topHeight: topHeight)
                    .frame(width: size.width, height: size.height)
                    .opacity(shape == .screenshot ? 1 : 0)
                    .allowsHitTesting(shape == .screenshot)
                    .accessibilityHidden(shape != .screenshot)
                    .transition(content)
            }
            if expanded, experience.state.dropTargeted {
                NotchDropTargets(zone: experience.dropZone, topHeight: topHeight)
                    .transition(content)
            } else if shape == .thread, let thread = experience.state.agentThread {
                NotchAgentThreadPage(t3: experience.t3, experience: experience, threadID: thread, topHeight: topHeight,
                                     wing: (visibleSize.width - geometry.cutoutWidth) / 2)
                    .frame(width: visibleSize.width, height: visibleSize.height)
                    .transition(content)
            } else if expanded {
                pages.transition(content)
                if let level = experience.state.level {
                    NotchLevelRow(level: level, experience: experience)
                        .frame(width: visibleSize.width, height: NotchGeometry.levelRowHeight)
                        .padding(.top, pageHeight - NotchLevelRow.rise)
                        .transition(content)
                }
            } else if shape == .dictation {
                NotchDictationView(dictation: experience.socket.dictation, topHeight: topHeight,
                                   controls: experience.state.dictationHover, barScale: experience.settings.dictationBarScale)
                    .transition(content)
            } else if shape == .agentPeek, let alert = experience.state.agentPeek {
                NotchAgentPeekView(alert: alert, experience: experience, topHeight: topHeight,
                                   wing: (visibleSize.width - geometry.cutoutWidth) / 2, scale: geometry.agentPeekScale)
                    .transition(content)
            } else if shape == .timerDone {
                NotchTimerDoneRow(timer: experience.timer, topHeight: topHeight)
                    .transition(content)
            } else if shape == .downloadPeek, let download = experience.state.download {
                NotchDownloadPeekView(download: download, experience: experience, topHeight: topHeight)
                    .transition(content)
            } else if shape == .eventPeek, let peek = experience.state.eventPeek {
                NotchEventPeekView(peek: peek, experience: experience, topHeight: topHeight)
                    .transition(content)
            } else if shape == .trackPeek, let peek = experience.state.trackPeek {
                NotchTrackPeekView(peek: peek, experience: experience, topHeight: topHeight,
                                   crossfade: motion?.crossfade ?? (animateTransitions ? .easeInOut(duration: 0.2) : nil))
                    .transition(content)
            } else if screenshot == nil {
                // A timer phase alert adds its row under the wings, which stay as they are.
                VStack(spacing: 0) {
                    compact.frame(height: topHeight)
                    if shape == .timerAlert, case .timer(let minutes)? = hud {
                        NotchTimerPhaseRow(minutes: minutes).transition(content)
                    }
                }
                .transition(content)
            }
        }
        .frame(width: visibleSize.width, height: visibleSize.height, alignment: .top)
        .background(.black)
        .clipShape(NotchOutline(cornerRadius: geometry.cornerRadius(shape)))
        .foregroundStyle(.white)
        .colorScheme(.dark)
        .environment(\.notchArtworkMotion, artworkMotion)
        .animation(resize, value: expanded)
        .animation(resize, value: experience.state.dictating)
        // An indicator appears at once, so a key press reads immediately; only its departure is animated. A timer
        // phase alert drops a row, which grows in with the spring.
        .animation(hud == nil || hud?.drops == true ? resize : nil, value: hud)
        .animation(resize, value: screenshot)
        .animation(resize, value: experience.state.countdown)
        .animation(resize, value: experience.state.timer)
        .animation(resize, value: experience.state.timerDone)
        .animation(resize, value: experience.state.download)
        .animation(resize, value: experience.state.eventPeek)
        .animation(resize, value: experience.state.trackPeek)
        .animation(resize, value: experience.state.agentPeek)
        .animation(resize, value: experience.state.agentThread)
        .animation(resize, value: experience.state.level)
        .background(NotchLikeWatch(experience: experience, media: experience.media))
        .background(NotchWebPageWatch(experience: experience, media: experience.media))
        // Known limit: this is the target size, not the animated one, so an interrupted change may pick the other
        // spring; springs keep their velocity when retargeted, so only the settle differs slightly.
        .onChange(of: visibleSize, initial: true) { _, size in drawnSize = size }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Pages keep the open player's height while the level row grows the outline under them.
    private var pageHeight: CGFloat { shape == .openLevel ? geometry.frame(.open).height : visibleSize.height }

    /// The settings' springs; nil under Reduce Motion and in still renders, where the outline changes at once.
    private var motion: NotchMotion? {
        reduceMotion || !animateTransitions ? nil : NotchMotion(experience.settings)
    }

    /// How artwork turns to a new track's: the chosen style on its spring, only a crossfade under Reduce Motion, and
    /// nothing in still renders or while the notch is hidden, locked or out of sight, where a turn under way settles.
    private var artworkMotion: NotchArtworkMotion {
        let transition = experience.settings.artworkTransition
        guard animateTransitions, !experience.concealed, !experience.obscured, transition != .none else {
            return NotchArtworkMotion()
        }
        return NotchArtworkMotion(transition: transition, reduceMotion: reduceMotion,
                                  animation: motion?.artwork ?? .spring(duration: 0.35, bounce: 0))
    }

    /// The spring for the outline's next change, from its drawn size to the one it takes now: the opening spring
    /// when it grows, such as an indicator ending over a waiting Quick Peek, the closing one otherwise.
    private var resize: Animation? {
        motion.map { NotchGeometry.grows(from: drawnSize ?? visibleSize, to: visibleSize) ? $0.open : $0.close }
    }

    /// Content follows the outline: it arrives a beat after the outline starts to grow, from a little smaller and
    /// out of focus, and leaves early, so it is gone before the outline finishes shrinking. Under Reduce Motion it
    /// only crossfades.
    private var content: AnyTransition {
        guard animateTransitions else { return .identity }
        guard let motion else { return .opacity.animation(.easeInOut(duration: 0.2)) }
        return .asymmetric(
            insertion: .modifier(active: NotchReveal(hidden: true), identity: NotchReveal(hidden: false))
                .animation(motion.reveal),
            removal: .opacity.animation(motion.conceal))
    }

    /// The pages lie on an endless strip: the open one between its neighbours, each keyed by its turn and page, so
    /// a turn past the last page still slides on in the same direction. Pages that left stay on the strip until the
    /// slide comes to rest, so a turn started during another never cuts a page still in view. A swipe in progress
    /// drags the strip with the fingers and only the settle after release animates. Under Reduce Motion only the
    /// open view is mounted and a change crossfades, with nothing sliding. VoiceOver turns pages through the
    /// container's actions.
    @ViewBuilder private var pages: some View {
        let width = visibleSize.width
        let activities = experience.state.activities
        let cycle = experience.state.pages
        Group {
            if let motion {
                ZStack {
                    ForEach(cycle.strip(in: activities), id: \.self) { slot in
                        // A page counts as on screen while any of it shows, as a neighbour does under the fingers.
                        let x = CGFloat(slot.turn - cycle.turn) * width + experience.swipeOffset
                        page(slot.page, width: width, visible: abs(x) < width)
                            .offset(x: x)
                            .accessibilityHidden(slot.turn != cycle.turn)
                            // Slots come and go off screen, except a jump swapping the current page in place,
                            // which crossfades.
                            .transition(.opacity)
                    }
                }
                .animation(experience.swipeOffset == 0 ? motion.page : nil, value: experience.swipeOffset)
                .animation(motion.page, value: cycle)
            } else {
                ZStack {
                    page(cycle.current, width: width, visible: true).id(cycle.current).transition(.opacity)
                }
                .animation(animateTransitions ? .easeInOut(duration: 0.2) : nil, value: cycle.current)
            }
        }
        .frame(width: width, height: pageHeight)
        // Restarted by each turn and each release, so pages are dropped only once the last slide has come to rest,
        // never while fingers hold the strip and may show one.
        .task(id: experience.swipeOffset == 0 ? cycle.turn : nil) {
            guard experience.swipeOffset == 0 else { return }
            try? await Task.sleep(for: .seconds(motion?.pageSettling ?? 0.2))
            if !Task.isCancelled { experience.state.settlePages() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(cycle.current.name)
        .accessibilityAction(named: "Next page") { experience.state.swipe(by: 1) }
        .accessibilityAction(named: "Previous page") { experience.state.swipe(by: -1) }
    }

    /// One page of the strip; `visible` is false for a neighbour waiting off screen, whose clocks then stand still.
    private func page(_ activity: NotchActivity, width: CGFloat, visible: Bool) -> some View {
        Group {
            switch activity {
            case .music: NotchMusicView(experience: experience, media: experience.media, topHeight: topHeight,
                                        height: pageHeight, visible: visible)
            case .calendar: NotchCalendarPage(calendar: experience.calendar, topHeight: topHeight,
                                              wing: (width - geometry.cutoutWidth) / 2, visible: visible)
            case .timer: NotchTimerPage(timer: experience.timer, experience: experience, topHeight: topHeight)
            case .shelf: NotchShelfView(experience: experience, topHeight: topHeight)
            case .agents: NotchAgentListPage(t3: experience.t3, experience: experience, topHeight: topHeight,
                                             wing: (width - geometry.cutoutWidth) / 2, visible: visible)
            }
        }
        .frame(width: width, height: pageHeight)
    }

    /// The closed wings' playing content arriving and leaving: the artwork and the wave fade on one spring as long as
    /// the wave's rise and flatten, so both sides go and come back together. Opacity only, so Reduce Motion keeps it;
    /// nothing in still renders or out of sight.
    private var playingFade: Animation? {
        animateTransitions && !experience.concealed && !experience.obscured ? .spring(duration: NotchWave.ease, bounce: 0) : nil
    }

    /// Artwork in the left wing while something plays and the wave in the right one. An indicator takes both
    /// wings, which widen for it; so do a running timer and the countdown to the next event, the timer first, which
    /// an indicator covers while it shows. A timer phase alert keeps the timer in the wings and pulses its ring.
    private var compact: some View {
        let countdown = experience.state.countdown
        let wide = shape == .indicator || shape == .timerAlert
        let wing = (experience.geometry?.wingWidth ?? 40) + (wide ? NotchGeometry.hudWingExtra : 0)
        let phase: Int? = if case .timer(let minutes)? = hud { minutes } else { nil }
        let indicator = phase == nil ? hud : nil
        return HStack(spacing: 0) {
            Group {
                if let indicator {
                    NotchHUDSymbol(hud: indicator, experience: experience).transition(.opacity)
                } else if experience.state.timer {
                    NotchTimerWingRing(timer: experience.timer, alert: phase).transition(.opacity)
                } else if countdown {
                    NotchCountdownTitle(calendar: experience.calendar).transition(.opacity)
                } else {
                    NotchPlayingArtwork(media: experience.media, animation: playingFade)
                }
            }
            .frame(width: wing)
            Spacer(minLength: experience.geometry?.cutoutWidth ?? 179)
            Group {
                if let indicator {
                    NotchHUDValue(hud: indicator, experience: experience).transition(.opacity)
                } else if experience.state.timer {
                    NotchTimerWingTime(timer: experience.timer).transition(.opacity)
                } else if countdown {
                    NotchCountdownTime(calendar: experience.calendar).transition(.opacity)
                } else if experience.settings.playingWave {
                    NotchPlayingWave(media: experience.media, settings: experience.settings, shape: shape,
                                     visible: !experience.concealed && !experience.obscured, animated: animateTransitions,
                                     animation: playingFade)
                }
            }
            .frame(width: wing)
        }
        .contentShape(Rectangle())
        .onTapGesture { experience.open() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open notch")
    }

}

private extension NotchActivity {
    var name: String {
        switch self {
        case .music: "Music"
        case .calendar: "Calendar"
        case .shelf: "Shelf"
        case .timer: "Timer"
        case .agents: "T3 Code"
        }
    }
}

/// The notch's springs, from the settings. The outline leads: growing takes the opening spring with its trace of
/// overshoot, shrinking the quicker closing one with none. Content follows a beat behind as it arrives and leaves
/// within the first part of a close. Wing indicators use the same springs, so every shape change shares one feel.
struct NotchMotion {
    let open: Animation
    let close: Animation
    /// Pages settling after a swipe or a turn: no overshoot, a little quicker than opening.
    let page: Animation
    /// Seconds until a page turn has come to rest.
    let pageSettling: TimeInterval
    /// Content arriving, a short delay after the outline starts growing.
    let reveal: Animation
    /// Content leaving, well before the outline finishes shrinking.
    let conceal: Animation
    /// Content changing in place, such as a track peek taking a newer track: as unhurried as a reveal, without its delay.
    let crossfade: Animation
    /// The artwork turning to a new track's: slower than a crossfade, so a flip or a slide reads without hurry.
    let artwork: Animation

    init(_ settings: NotchSettings) {
        let opening = settings.openAnimationDuration
        let closing = settings.closeAnimationDuration
        open = .spring(duration: opening, bounce: settings.openAnimationBounce)
        close = .spring(duration: closing, bounce: 0)
        let paging = Spring(duration: opening * 0.8, bounce: 0)
        page = .spring(paging)
        pageSettling = paging.settlingDuration
        reveal = .spring(duration: opening * 0.8, bounce: 0).delay(opening * 0.18)
        conceal = .spring(duration: closing * 0.4, bounce: 0)
        crossfade = .spring(duration: opening * 0.8, bounce: 0)
        artwork = .spring(duration: opening * 1.2, bounce: 0)
    }
}

/// Content not yet revealed: transparent, slightly smaller from the top edge and softly out of focus. Only the
/// transition animates it; nothing moves once the content has arrived.
private struct NotchReveal: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.96 : 1, anchor: .top)
            .blur(radius: hidden ? 4 : 0)
    }
}

/// Rounded lower corners join the black camera cutout without painting inside its unavailable pixels.
struct NotchOutline: Shape {
    var cornerRadius: CGFloat = 18
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Left wing of the closed notch: the artwork only while something plays. Paused or without a track the wing
/// stays empty, so an idle notch shows nothing at all. It fades on `animation` as the wave does, both reading the same
/// change, so the two wings leave and arrive together. At this size a new track's artwork only crossfades.
private struct NotchPlayingArtwork: View {
    @ObservedObject var media: NotchMedia
    let animation: Animation?
    @Environment(\.notchArtworkMotion) private var artworkMotion

    var body: some View {
        let playing = media.track?.isPlaying == true
        NotchArtwork(media: media, size: 22)
            .opacity(playing ? 1 : 0)
            .animation(animation, value: playing)
            .environment(\.notchArtworkMotion, subtle)
    }

    private var subtle: NotchArtworkMotion {
        var motion = artworkMotion
        if motion.transition != .none { motion.transition = .crossfade }
        return motion
    }
}

/// The playing track's artwork, turning to each new image in the style from the environment. When the artwork is
/// only the website's logo, as Netflix's, a website gives none, or generic web media plays, the site tile stands in;
/// an empty one while the website is still being read.
private struct NotchArtwork: View {
    @ObservedObject var media: NotchMedia
    let size: CGFloat
    var body: some View {
        let tile = media.presentation?.siteTile == true
        ZStack {
            if tile {
                NotchSiteTile(icon: media.tileIcon, size: size, glyph: media.kind != .pending).transition(.opacity)
            } else {
                NotchArtworkSwap(artwork: media.shownArtwork, size: size).transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0), value: tile)
    }
}

/// A website's logo small and centred on a dark tile, in place of artwork, so a logo is never stretched across the
/// tile as if it were a cover. Without a logo, as for another browser's media, a video glyph, unless `glyph` is off
/// while the website is still being read. A logo or glyph arriving fades in.
struct NotchSiteTile: View {
    let icon: NSImage?
    let size: CGFloat
    var glyph = true

    var body: some View {
        ZStack {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().frame(width: size * 0.5, height: size * 0.5)
                    .transition(.opacity)
            } else if glyph {
                Image(systemName: "play.rectangle.fill").font(.system(size: size * 0.38)).foregroundStyle(.white.opacity(0.7))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: icon)
        .animation(.easeInOut(duration: 0.25), value: glyph)
        .frame(width: size, height: size)
        .background(.white.opacity(0.08)).background(.black)
        .notchArtworkTile(cornerRadius: size * 0.18)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Fades a control in or out in place, keeping its room either way so nothing beside it moves; hidden, it takes
    /// no clicks and is left out of Accessibility.
    func revealed(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0).animation(.spring(duration: 0.35, bounce: 0), value: shown)
            .allowsHitTesting(shown).accessibilityHidden(!shown)
    }
}

/// Right wing of the closed notch while a track plays: the wave, in white or the artwork's colour. It fades on
/// `animation` with the artwork and moves only while `NotchWave.moves` allows and the notch can be seen, so a pause
/// flattens it as it fades.
private struct NotchPlayingWave: View {
    @ObservedObject var media: NotchMedia
    let settings: NotchSettings
    let shape: NotchShape
    /// False while the notch is hidden, locked, covered or on sleeping displays.
    let visible: Bool
    let animated: Bool
    let animation: Animation?

    var body: some View {
        let playing = media.track?.isPlaying == true
        NotchWaveView(style: settings.waveStyle, color: settings.waveColor(artwork: media.artworkTint),
                      moving: NotchWave.moves(playing: playing, shape: shape), visible: visible, animated: animated)
            .opacity(playing ? 1 : 0)
            .animation(animation, value: playing)
    }
}

/// Left wing of an indicator: the speaker, sun, battery, Focus, Caps Lock, output device or travel mode symbol. A Focus that
/// ended, Caps Lock turning off and a device going away show their symbol dimmed; the battery is green with power
/// connected, white on battery and red when low.
private struct NotchHUDSymbol: View {
    let hud: NotchHUD
    @ObservedObject var experience: NotchExperience
    @ObservedObject var volume: NotchVolume
    @ObservedObject var brightness: NotchBrightness
    @ObservedObject var focus: NotchFocus
    @ObservedObject var battery: NotchBattery

    init(hud: NotchHUD, experience: NotchExperience) {
        self.hud = hud
        self.experience = experience
        volume = experience.volume
        brightness = experience.brightness
        focus = experience.focus
        battery = experience.battery
    }

    var body: some View {
        image.font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .accessibilityLabel(label)
    }

    /// The battery goes through `tintableSymbol`; the other indicator symbols are white or tint as expected.
    private var image: Image { hud == .battery ? tintableSymbol(symbol, size: 14) : Image(systemName: symbol) }

    private var symbol: String {
        switch hud {
        case .volume: return volume.symbol
        case .brightness: return brightness.symbol
        case .focus: return focus.change?.mode.symbol ?? "moon.fill"
        case .battery: return NotchBattery.symbol(for: battery.level)
        case .capsLock: return "capslock.fill"
        case .audioDevice(let change): return change.device.symbol
        case .leave: return experience.settings.travelMode.symbol
        case .timer: return "timer"
        }
    }

    private var tint: Color {
        switch hud {
        case .volume, .brightness: return .white
        case .leave: return Color(nsColor: .systemBlue)
        case .timer: return notchTimerTint
        case .battery: return battery.color
        case .capsLock(let on): return on ? .white : .white.opacity(0.5)
        case .audioDevice(let change): return change.connected ? .white : .white.opacity(0.5)
        case .focus:
            guard let change = focus.change, change.on else { return .white.opacity(0.5) }
            return change.mode.tint.map { Color(nsColor: $0) } ?? .white
        }
    }

    private var label: String {
        switch hud {
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .focus: "Focus"
        case .battery: battery.plugged ? "Charging" : battery.low ? "Low battery" : "On battery"
        case .capsLock: "Caps Lock"
        case .audioDevice(let change): change.device.name
        case .leave(let event): "Time to leave for \(event.title)"
        case .timer: "Timer"
        }
    }
}

/// Right wing of an indicator: a short meter for volume and brightness, On or Off for Focus, Caps Lock and an output
/// device (Connected and Disconnected do not fit the wing), the percentage for the battery, Leave when it is time to go. The mode or device
/// itself is the symbol on the left, so no name is spelled out.
private struct NotchHUDValue: View {
    let hud: NotchHUD
    @ObservedObject var experience: NotchExperience
    @ObservedObject var volume: NotchVolume
    @ObservedObject var brightness: NotchBrightness
    @ObservedObject var focus: NotchFocus
    @ObservedObject var battery: NotchBattery

    init(hud: NotchHUD, experience: NotchExperience) {
        self.hud = hud
        self.experience = experience
        volume = experience.volume
        brightness = experience.brightness
        focus = experience.focus
        battery = experience.battery
    }

    var body: some View {
        switch hud {
        case .volume: NotchMeter(level: volume.muted ? 0 : volume.level, color: experience.settings.hudColor,
                                 glow: experience.settings.hudGlow)
                .accessibilityValue(volume.muted ? "Muted" : percent(volume.level))
        case .brightness: NotchMeter(level: brightness.level, color: experience.settings.hudColor,
                                     glow: experience.settings.hudGlow)
                .accessibilityValue(percent(brightness.level))
        case .focus:
            Text(focus.change?.on == true ? "On" : "Off")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focusTint)
                .padding(.horizontal, 4)
        case .battery:
            Text("\(Int((battery.level * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(battery.color)
                .padding(.horizontal, 4)
                .accessibilityValue(percent(battery.level))
        case .capsLock(let on):
            Text(on ? "On" : "Off")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? .white : .white.opacity(0.7))
                .padding(.horizontal, 4)
        case .audioDevice(let change):
            Text(change.connected ? "On" : "Off")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(change.connected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 4)
                .accessibilityLabel(change.connected ? "Connected" : "Disconnected")
        case .leave:
            Text("Leave")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 4)
        // The compact view shows the timer's own wings for its alerts; this keeps the switch whole.
        case .timer(let minutes):
            Text("\(minutes) min")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 4)
        }
    }

    /// The mode's tint while it turned on; dim white after it turned off or without a tint.
    private var focusTint: Color {
        guard let change = focus.change, change.on, let tint = change.mode.tint else { return .white.opacity(0.7) }
        return Color(nsColor: tint)
    }

    private func percent(_ level: Float) -> String { "\(Int((level * 100).rounded())) percent" }
}

private extension NotchBattery {
    /// Green while power is connected, white on battery, red at or under 20 %: the colour carries the meaning in
    /// both wings.
    var color: Color { plugged ? Color(nsColor: .systemGreen) : low ? Color(nsColor: .systemRed) : .white }
}

/// A 4 pt meter. Each level change glides over a short spring; glow is a static shadow, so nothing repaints at rest.
private struct NotchMeter: View {
    let level: Float
    let color: Color
    let glow: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(color)
                    .frame(width: geometry.size.width * CGFloat(max(0, min(1, level))))
                    .shadow(color: glow ? color.opacity(0.8) : .clear, radius: 4)
            }
        }
        .frame(width: 40, height: 4)
        .animation(reduceMotion ? nil : .spring(duration: 0.15, bounce: 0), value: level)
        .accessibilityElement()
    }
}

/// The dictation pill under the camera: Sotto's bars while recording, "Transcribing" while Sotto works. Hovering a
/// recording shows Cancel and Stop either side of the bars; both go back to Sotto, which owns the recording.
private struct NotchDictationView: View {
    @ObservedObject var dictation: NotchDictation
    let topHeight: CGFloat
    let controls: Bool
    let barScale: Double

    var body: some View {
        HStack(spacing: 10) {
            if dictation.state == .processing {
                Text("Transcribing").font(.system(size: 11, weight: .medium))
            } else {
                let recording = dictation.state == .recording
                if controls { button("xmark", "Cancel dictation", action: dictation.cancel) }
                NotchDictationBars(level: recording ? dictation.level : nil, scale: barScale)
                if controls, recording { button("stop.fill", "Stop and insert", action: dictation.stop) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, topHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation")
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
                .frame(width: 18, height: 18).background(.white.opacity(0.15), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(NotchPressStyle()).accessibilityLabel(label).help(label)
    }
}

/// Sotto's recorder bars, copied from its pill: twelve 2.5 pt bars on a flattened envelope, grown by the microphone
/// level Sotto sends about 20 times a second while recording, all sizes times the bar size setting. A nil level rests them as dots. No animation: the bars
/// change only when a level arrives, so nothing repaints between messages.
private struct NotchDictationBars: View {
    let level: Double?
    let scale: CGFloat

    /// The envelope 1 - d² / 90 over the distance from the centre: the edges nearly as tall as the middle.
    private static let shape: [Double] = (0..<12).map { index in
        let distance = Double(index) - 5.5
        return 1 - distance * distance / 90
    }

    var body: some View {
        // Sotto's curve: quiet speech still moves the bars visibly.
        let amplitude = level.map { (pow(max(0, min(1, $0)), 0.7) * 100).rounded() / 100 } ?? 0
        HStack(spacing: 2.5 * scale) {
            ForEach(Self.shape.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.25 * scale)
                    .fill(.white.opacity(0.85))
                    .frame(width: 2.5 * scale, height: height(index, amplitude: amplitude))
            }
        }
        .frame(height: maxHeight)
        .transaction { $0.disablesAnimations = true }
        .accessibilityHidden(true)
    }

    private var minHeight: CGFloat { 2.5 * scale }
    private var maxHeight: CGFloat { NotchGeometry.dictationBarHeight * scale }

    private func height(_ index: Int, amplitude: Double) -> CGFloat {
        minHeight + CGFloat(amplitude * Self.shape[index]) * (maxHeight - minHeight)
    }
}

/// The approved B layout puts artwork beside the cutout and keeps all text below it. The two secondary slots either
/// side of the transport hold the buttons picked on the Now Playing page. Generic web media, and browser media whose
/// website is still being read, fade previous and next out in place, leaving play or pause alone in the middle.
private struct NotchMusicView: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var media: NotchMedia
    let topHeight: CGFloat
    let height: CGFloat
    /// The page is on screen rather than waiting beside it on the strip, where its progress does not move.
    var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { experience.settings.accentColor }

    var body: some View {
        let presentation = media.presentation
        let siteTile = presentation?.siteTile == true
        // Without times the progress row goes and the transport rises into half its space, so the gap it leaves is
        // shared above and below the buttons. With Reduce Motion the transport moves at once and only the row fades.
        let hidesProgress = presentation?.progress == .hidden
        let skips = presentation?.skips ?? true
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // The site tile also stands in for the source badge, so it opens the tab as the badge does.
                Button(action: media.showSource) { NotchArtwork(media: media, size: 52) }
                    .buttonStyle(NotchPressStyle()).allowsHitTesting(siteTile)
                    .help(siteTile ? "Open \(sourceName)" : "")
                    .accessibilityHidden(!siteTile).accessibilityLabel("Open \(sourceName)")
                    .offset(x: 12, y: topHeight - 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation?.title ?? (media.unavailable ? "Player unavailable" : "Play something"))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let presentation {
                        Text(presentation.subtitle)
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    } else {
                        Button("Refresh", action: media.refresh).font(.system(size: 11)).buttonStyle(.plain)
                    }
                }
                .frame(width: max(0, geometry.size.width - (siteTile ? 90 : 118)), alignment: .leading)
                .offset(x: 78, y: topHeight + 8)

                if media.track != nil, !siteTile, let source = media.source {
                    NotchSourceBadge(name: media.webSite?.name ?? source.name, icon: media.webSite?.icon ?? source.icon,
                                     open: media.showSource)
                        .frame(width: 24).offset(x: geometry.size.width - 34, y: topHeight + 6)
                }

                // Ticks each second while a track plays on screen and stands still otherwise, such as paused or paged
                // away. One view either way, so a drag or a seek on its way survives a pause or a page turn.
                let ticking = media.track?.isPlaying == true && visible
                if !hidesProgress {
                    TimelineView(NotchTicks(start: .now, interval: ticking ? 1 : nil)) { _ in progress(presentation?.progress) }
                    .padding(.horizontal, 12)
                    .offset(y: height - 83)
                    .transition(.opacity.animation(.spring(duration: 0.35, bounce: 0)))
                }

                // The skips keep their places while hidden, so nothing moves when they come or go: they only fade,
                // which suits Reduce Motion too.
                HStack(spacing: 0) {
                    slot(experience.settings.playerLeftButton)
                    Spacer(minLength: 0)
                    control("backward.fill", "Previous track", size: 22, action: media.previous).revealed(skips)
                    Spacer(minLength: 0)
                    control(media.track?.isPlaying == true ? "pause.fill" : "play.fill", "Play or pause", size: 26, action: media.togglePlayback)
                    Spacer(minLength: 0)
                    control("forward.fill", "Next track", size: 22, action: media.next).revealed(skips)
                    Spacer(minLength: 0)
                    slot(experience.settings.playerRightButton)
                }
                .padding(.horizontal, 12)
                .offset(y: height - 52 - (hidesProgress ? 12 : 0))
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: hidesProgress)
        }
    }

    /// What the site tile opens: the website, or for another browser, that browser.
    private var sourceName: String { media.webSite?.name ?? media.source?.name ?? "the website" }

    /// The bar from the player's times, or from the page's video, which it shows without seeking. With nothing
    /// playing it stays as the empty bar of the idle player.
    private func progress(_ progress: NotchPlayerPresentation.Progress?) -> some View {
        let elapsed = media.track?.currentElapsedTime ?? 0
        var duration: Double = 0, reported = elapsed.isFinite ? elapsed : 0, playing = media.track?.isPlaying == true
        var seek: ((Double) -> Void)?
        switch progress {
        case .player(let total, let seekable):
            duration = total
            if seekable, media.reaches(.modes) { seek = { [media] in media.seek(to: $0) } }
        case .page(let page):
            (duration, reported, playing) = (page.duration, page.elapsed(at: .now), page.playing)
        case .hidden, nil:
            reported = 0
        }
        return NotchPlaybackProgress(duration: duration, reported: reported, playing: playing,
                                     track: media.track?.uniqueIdentifier, accent: accent, seek: seek)
    }

    /// One secondary slot. Browsers have no shuffle or repeat, so those slots stay empty there; Like and Playlist dim
    /// for players they cannot reach yet and stay empty for generic web media, which no like or playlist ever
    /// reaches, and until a website is known. Volume and Output work whatever plays, nothing included.
    @ViewBuilder private func slot(_ button: NotchPlayerButton) -> some View {
        let browser = media.source?.isBrowser == true
        let generic = media.kind == .genericWeb || media.kind == .pending
        switch button {
        case .shuffle where !browser:
            control("shuffle", "Shuffle", size: 15, secondary: true, active: media.shuffleMode != .off,
                    value: media.shuffleMode == .off ? "Off" : "On", action: media.shuffle)
        case .repeat where !browser:
            control(media.repeatMode == .one ? "repeat.1" : "repeat", "Repeat", size: 15, secondary: true,
                    active: media.repeatMode != .off, value: repeatValue, action: media.repeatTrack)
        case .like where !generic:
            NotchLikeButton(like: media.like, target: media.likeTarget, request: media.likeRequest, accent: accent)
        case .playlist where !generic:
            NotchPlaylistButton(experience: experience, playlists: media.playlists, request: media.likeRequest, accent: accent)
        case .volume:
            NotchVolumeButton(experience: experience, volume: experience.volume, accent: accent)
        case .output:
            NotchOutputButton(experience: experience, devices: experience.audioDevices)
        case .none, .shuffle, .repeat, .like, .playlist:
            Spacer().frame(width: 36).accessibilityHidden(true)
        }
    }

    private var repeatValue: String {
        switch media.repeatMode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    /// Secondary controls sit dimmed until their mode is active, which takes the accent colour. Every one of them
    /// acts on playback, so with nothing playing, or a shown player it cannot reach, it is disabled and faded.
    private func control(_ symbol: String, _ label: String, size: CGFloat, secondary: Bool = false,
                         active: Bool = false, value: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? accent : .white.opacity(secondary ? 0.4 : 1))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle()).accessibilityLabel(label).accessibilityValue(value ?? "").help(label)
        .disabled(!media.reaches(secondary ? .modes : .transport))
        .opacity(media.reaches(secondary ? .modes : .transport) ? 1 : 0.25)
    }
}

/// A press shrinks and dims the symbol briefly; the spring settles, so nothing repaints while idle.
struct NotchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.8 : 1)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// A press on a whole dropped row, such as a peek or an alert: it settles back a little and dims, quieter than a
/// symbol's press, which would shrink the wings with it.
struct NotchRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

/// A thumb-free seek bar matches B and exposes time adjustment to assistive tools. Dragging scrubs: the bar thickens
/// under the finger, both times follow it, and release seeks. The chosen position then stays until the player reports
/// it (`NotchSeekHold`), so the bar never jumps back while the player catches up. Without `seek` it only shows the
/// position, as for a page's video.
private struct NotchPlaybackProgress: View {
    let duration: Double
    /// The position the player reports now.
    let reported: Double
    let playing: Bool
    /// The track's identity; a new track forgets a seek still on its way.
    let track: String?
    let accent: Color
    let seek: ((Double) -> Void)?
    @State private var draggedPosition: Double?
    @State private var hold = NotchSeekHold()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scrubbing = draggedPosition != nil
        let current = min(duration, max(0, draggedPosition ?? hold.position(reported: reported, track: track, at: .now) ?? reported))
        HStack(spacing: 8) {
            Text(duration > 0 ? time(current) : "--:--")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(accent)
                        .frame(width: duration > 0 ? geometry.size.width * (current / duration) : 0)
                }
                .frame(height: scrubbing ? 6 : 4).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard seek != nil, duration > 0, geometry.size.width > 0 else { return }
                        draggedPosition = min(duration, max(0, value.location.x / geometry.size.width * duration))
                    }
                    .onEnded { _ in
                        if let draggedPosition { commit(draggedPosition) }
                        draggedPosition = nil
                    })
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue(duration > 0 ? "\(time(current)) of \(time(duration))" : "Unavailable")
                .accessibilityAdjustableAction { direction in
                    guard seek != nil, duration > 0 else { return }
                    switch direction {
                    case .increment: commit(min(duration, current + 5))
                    case .decrement: commit(max(0, current - 5))
                    @unknown default: break
                    }
                }
            }
            Text(duration > 0 ? "-\(time(duration - current))" : "--:--")
        }
        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.white.opacity(scrubbing ? 0.9 : 0.7))
        .frame(height: 24)
        // Pressing glides the fill to the finger as the bar thickens; the drag itself follows the finger exactly.
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: scrubbing)
        .onChange(of: reported) { hold.settle(reported: reported, track: track, at: .now) }
        .onChange(of: track) { hold.settle(reported: reported, track: track, at: .now) }
        // A paused bar stands still, so the seek's deadline gets its own wake. A new seek or the end of this
        // one cancels it.
        .task(id: hold.pending) {
            guard let seek = hold.pending else { return }
            try? await Task.sleep(for: .seconds(max(0, seek.deadline.timeIntervalSinceNow)))
            if !Task.isCancelled { hold.expire(seek) }
        }
    }

    private func commit(_ target: Double) {
        guard let seek else { return }
        hold.send(target, at: .now, playing: playing, track: track)
        seek(target)
    }

    private func time(_ seconds: Double) -> String {
        let minutes = floor(max(0, seconds) / 60)
        let remainder = floor(max(0, seconds).truncatingRemainder(dividingBy: 60))
        return String(format: "%.0f:%02.0f", minutes, remainder)
    }
}

/// `Image(systemName:)` paints some symbols, the battery and speaker ones among them, in their own colours inside this
/// app whatever style is set, while a standalone harness tints them; an AppKit template image always takes the tint.
private func tintableSymbol(_ name: String, size: CGFloat) -> Image {
    guard let template = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium)) else {
        return Image(systemName: name)
    }
    return Image(nsImage: template).renderingMode(.template)
}

private extension NotchVolume {
    /// The speaker with one to three waves for the level, crossed out when muted or silent.
    var symbol: String {
        if muted || level == 0 { return "speaker.slash.fill" }
        return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

private extension NotchBrightness {
    var symbol: String { level < 0.5 ? "sun.min.fill" : "sun.max.fill" }
}

/// The slim row a volume or brightness change grows under the open Music page: the symbol in the column of the
/// left slot, then a bar that follows the level live and sets it when dragged, thickening under the finger. Muted,
/// the speaker is crossed out and the bar empties and dims; an output or display that cannot be adjusted dims the
/// whole row and ignores drags. The pointer on it or a drag holds it open.
private struct NotchLevelRow: View {
    let level: NotchLevel
    @ObservedObject var experience: NotchExperience
    @ObservedObject var volume: NotchVolume
    @ObservedObject var brightness: NotchBrightness
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the row tucks up under the player, so it sits at the transport row's rhythm.
    static let rise: CGFloat = 14

    init(level: NotchLevel, experience: NotchExperience) {
        self.level = level
        self.experience = experience
        volume = experience.volume
        brightness = experience.brightness
    }

    private var available: Bool { level == .volume ? volume.available : brightness.available }
    private var muted: Bool { level == .volume && volume.muted }
    private var value: Float { level == .volume ? (volume.muted ? 0 : volume.level) : brightness.level }

    var body: some View {
        let color = experience.settings.hudColor
        HStack(spacing: 8) {
            Image(systemName: level == .volume ? volume.symbol : brightness.symbol)
                .font(.system(size: 14, weight: .medium))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .frame(width: 36)
                .accessibilityHidden(true)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(muted ? 0.1 : 0.2))
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * CGFloat(max(0, min(1, value))))
                        .shadow(color: experience.settings.hudGlow ? color.opacity(0.8) : .clear, radius: 4)
                }
                .frame(height: dragging ? 6 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard geometry.size.width > 0 else { return }
                        if !dragging { dragging = true; experience.holdLevel(.drag, true) }
                        set(Float(drag.location.x / geometry.size.width))
                    }
                    .onEnded { _ in
                        dragging = false
                        experience.holdLevel(.drag, false)
                    })
                .allowsHitTesting(available)
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: dragging)
            // Key presses glide; the finger is followed exactly.
            .animation(reduceMotion || dragging ? nil : .spring(duration: 0.15, bounce: 0), value: value)
        }
        .padding(.leading, 12).padding(.trailing, 24)
        .opacity(available ? 1 : 0.35)
        .contentShape(Rectangle())
        .onHover { experience.holdLevel(.pointer, $0) }
        .accessibilityElement()
        .accessibilityLabel(level == .volume ? "Volume" : "Brightness")
        .accessibilityValue(!available ? "Unavailable" : muted ? "Muted" : "\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard available else { return }
            switch direction {
            case .increment: set(value + NotchMediaKey.step)
            case .decrement: set(value - NotchMediaKey.step)
            @unknown default: break
            }
        }
    }

    /// Dragging a muted output unmutes it, as the Control Center slider does.
    private func set(_ newValue: Float) {
        let clamped = max(0, min(1, newValue))
        switch level {
        case .volume:
            if volume.muted { volume.setMuted(false) }
            volume.setVolume(clamped)
        case .brightness:
            brightness.setLevel(clamped)
        }
    }
}

/// Tells the media whether the open notch shows the Music page where it can be seen, so the playing page is read
/// only then (see `NotchMedia.followPage`). Hidden or locked, the notch is not open; obscured, as while the displays
/// sleep or the screen saver covers it, nobody sees it: reads stop and start again, checking the tab first, after.
private struct NotchWebPageWatch: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var media: NotchMedia

    var body: some View {
        let watching = experience.state.playerOnScreen && !experience.concealed && !experience.obscured
        Color.clear
            .onChange(of: watching, initial: true) { _, watching in media.watchesPage = watching }
            .onDisappear { media.watchesPage = false }
    }
}

/// Tells the like and the playlists which track the open notch shows their buttons for: the current track while the
/// notch is open on the Music page with Like or Playlist in a slot, where it can be seen, otherwise nothing, which
/// stops reads and gives up a like or a list waiting for Spotify's sign in. A YouTube tab out of reach is checked
/// again when its browser comes forward. Generic and pending web media, whose slots are hidden, read nothing. One
/// watcher for the view, so the neighbouring pages the strip mounts off screen never read, and nothing reads while the notch is closed, on another
/// page, hidden, locked or obscured, as `NotchWebPageWatch` does.
private struct NotchLikeWatch: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var media: NotchMedia

    private func request(_ button: NotchPlayerButton) -> NotchLikeRequest? {
        let state = experience.state, settings = experience.settings
        // Generic and pending web media hide both slots, so nothing is read for them; a YouTube classification
        // starts the read.
        guard settings.playerLeftButton == button || settings.playerRightButton == button, state.playerOnScreen,
              !experience.concealed, !experience.obscured, media.kind != .genericWeb, media.kind != .pending
        else { return nil }
        return media.likeRequest
    }

    var body: some View {
        Color.clear
            .onChange(of: request(.like), initial: true) { _, request in media.like.show(request) }
            .onChange(of: request(.playlist), initial: true) { _, request in media.playlists.show(request) }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                media.like.retry(activated: app?.bundleIdentifier)
            }
            .onDisappear { media.like.show(nil); media.playlists.show(nil) }
    }
}

/// The Like slot: an outlined heart that fills in the accent colour with a small bounce when liked. The like is read
/// for each track and each open of the player (see `NotchLikeWatch`); for players it cannot reach, Spotify without a
/// Client ID included, for a YouTube tab neither JavaScript nor Accessibility reaches, and for a Zen tab in front
/// that is no YouTube video naming the track, it is dimmed rather than hidden, so the transport never shifts. A press
/// of the dimmed heart only checks the tab again, and lights the heart if it is now in reach.
private struct NotchLikeButton: View {
    @ObservedObject var like: NotchLike
    let target: NotchLikeTarget
    let request: NotchLikeRequest?
    let accent: Color
    @State private var pops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let blocked = request != nil && like.unreachable == request
        let enabled = target != .unsupported && !blocked
        let liked = enabled && like.liked(request) == true
        Button {
            guard !blocked else { return like.retry() }
            if !liked, !reduceMotion { pops += 1 }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0)) { like.toggle() }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(liked ? accent : .white.opacity(enabled ? 0.4 : 0.15))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.downUp))
                .symbolEffect(.bounce.up, options: .nonRepeating, value: pops)
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .disabled(target == .unsupported)
        .accessibilityLabel("Like")
        .accessibilityValue(!enabled ? "Unavailable" : liked ? "Liked" : "Not liked")
        .accessibilityHint(blocked ? blockedHint : "")
        .help(blocked ? blockedHint : enabled ? "Like" : "Like is not available for this player")
    }

    private var blockedHint: String {
        target == .zen ? "Show the YouTube video's tab in Zen on this Space"
            : "Show the video's tab in Safari, or allow JavaScript from Apple Events in Safari's Develop menu"
    }
}

/// The Volume slot: the speaker at the current level, in the accent colour while it holds the volume row open.
private struct NotchVolumeButton: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var volume: NotchVolume
    let accent: Color

    var body: some View {
        let active = experience.state.level == .volume
        Button(action: experience.toggleVolumeLevel) {
            tintableSymbol(volume.symbol, size: 15)
                .foregroundStyle(active ? accent : .white.opacity(0.4))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .accessibilityLabel("Volume")
        .accessibilityValue(active ? "Shown" : "Hidden")
        .help("Volume")
    }
}

/// The Output slot: the current output device's symbol; a press lists every device that can play sound, with the
/// current one checked, and picking one makes it the output. The notch stays open while the menu is up.
private struct NotchOutputButton: View {
    let experience: NotchExperience
    @ObservedObject var devices: NotchAudioDevices

    var body: some View {
        Button(action: showMenu) {
            tintableSymbol(devices.output?.symbol ?? "airplay.audio", size: 15)
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .accessibilityLabel("Output")
        .accessibilityValue(devices.output?.name ?? "None")
        .help("Output")
    }

    private func showMenu() {
        let menu = NSMenu()
        for device in devices.devices {
            let item = NSMenuItem(title: device.name, action: #selector(NotchMenuAction.run), keyEquivalent: "")
            let action = NotchMenuAction { [devices] in devices.select(device) }
            item.target = action
            // The item's target is weak; the represented object keeps the action alive as long as the menu.
            item.representedObject = action
            item.image = NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil)
            item.state = device.uid == devices.output?.uid ? NSControl.StateValue.on : .off
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else { return }
        experience.holdOpen { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }
}

/// An NSMenuItem target that runs a closure.
final class NotchMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// Ticks every `interval` from `start` while a page is on screen. Without an interval it shows `start` once and never
/// wakes, as for a page waiting off screen; coming back on screen hands its timeline a new schedule.
struct NotchTicks: TimelineSchedule {
    let start: Date
    let interval: TimeInterval?

    func entries(from _: Date, mode _: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        sequence(first: start) { [interval] date in interval.map { date + $0 } }
    }
}
