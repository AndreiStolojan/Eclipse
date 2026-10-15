import SwiftUI

/// The timer's colour, after the Clock app's timers.
let notchTimerTint = Color(nsColor: .systemOrange)

/// The Timer page of the open notch: a thin ring with the big digits on the left, the controls on the right.
/// Idle, the digits show the length to set, which a vertical two-finger scroll over the ring or the − and + buttons
/// change, and the presets start at once. Running, the ring fills as time passes, once per second, and the controls
/// pause, resume, cancel or add a minute. In the last ten seconds the digits take the timer's colour; when it ends
/// the ring completes and blooms once and Done replaces the digits until Stop or +1 min. Reduce Motion keeps the
/// bloom and pulses out and crossfades the rest.
struct NotchTimerPage: View {
    @ObservedObject var timer: NotchTimer
    let experience: NotchExperience
    let topHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dialHovered = false

    private static let presets = [1, 5, 10, 15, 25, 45]
    private static let dial: CGFloat = 104

    /// What the page shows; running and paused share the controls.
    private enum Mode: Equatable {
        case idle, running, paused, done

        var controls: Int { self == .idle ? 0 : self == .done ? 2 : 1 }
    }

    private var mode: Mode {
        if timer.done != nil { return .done }
        guard let run = timer.run else { return .idle }
        return run.paused ? .paused : .running
    }

    var body: some View {
        let mode = mode
        HStack(spacing: 16) {
            dial(mode)
            ZStack { controls(mode).id(mode.controls).transition(swap) }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, topHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(motion, value: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timer")
    }

    /// A gentle spring between modes; a crossfade under Reduce Motion.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.12)
    }

    private var swap: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94))
    }

    /// The ring and what it holds. The ring jumps once per second without animating, so nothing repaints between
    /// ticks; only a change of mode, such as the finish completing it, springs.
    private func dial(_ mode: Mode) -> some View {
        let final = mode == .running && timer.seconds <= 10
        return ZStack {
            NotchTimerRing(progress: mode == .idle ? 0 : timer.progress, lineWidth: 4, tint: notchTimerTint,
                           track: mode == .idle && dialHovered ? 0.28 : 0.14)
                .shadow(color: mode == .done || final ? notchTimerTint.opacity(0.55) : .clear, radius: 6)
                .animation(.spring(duration: 0.8, bounce: 0), value: final)
            if mode == .done, !reduceMotion { NotchTimerBloom(lineWidth: 4) }
            VStack(spacing: 3) {
                if mode == .done {
                    Image(systemName: "checkmark").font(.system(size: 22, weight: .semibold)).foregroundStyle(notchTimerTint)
                    Text("Done").font(.system(size: 13, weight: .semibold))
                } else {
                    Text(NotchTimerRun.label(mode == .idle ? timer.dial * 60 : timer.seconds))
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(final ? notchTimerTint : .white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        // The dial's own changes roll; ticks are not animated and change in place.
                        .contentTransition(.numericText(value: Double(timer.dial)))
                        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: timer.dial)
                        .animation(.spring(duration: 0.8, bounce: 0), value: final)
                    caption(mode)
                }
            }
            .frame(width: Self.dial - 18)
        }
        .frame(width: Self.dial, height: Self.dial)
        .contentShape(Circle())
        .onHover { inside in
            dialHovered = inside
            experience.timerDialHovered = inside
        }
        .onDisappear { experience.timerDialHovered = false }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue(mode))
        .accessibilityAdjustableAction { direction in
            guard mode == .idle else { return }
            switch direction {
            case .increment: timer.dial = NotchTimerDial.step(timer.dial, by: 1)
            case .decrement: timer.dial = NotchTimerDial.step(timer.dial, by: -1)
            @unknown default: break
            }
        }
    }

    /// When a running timer ends, or Paused; nothing while setting one.
    @ViewBuilder private func caption(_ mode: Mode) -> some View {
        Group {
            switch mode {
            case .running:
                if let end = timer.end {
                    Label(end.formatted(date: .omitted, time: .shortened), systemImage: "bell.fill")
                        .labelStyle(NotchTimerCaptionLabel())
                }
            case .paused: Text("Paused")
            case .idle, .done: EmptyView()
            }
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
    }

    @ViewBuilder private func controls(_ mode: Mode) -> some View {
        switch mode {
        case .idle:
            VStack(spacing: 8) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(0..<2) { row in
                        GridRow {
                            ForEach(Self.presets[row * 3..<row * 3 + 3], id: \.self) { minutes in
                                chip("\(minutes) min", selected: timer.dial == minutes) { timer.begin(minutes: minutes) }
                                    .accessibilityLabel("Start \(minutes) minute timer")
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    round("minus", "Shorter", size: 28) { timer.dial = NotchTimerDial.step(timer.dial, by: -1) }
                        .disabled(timer.dial <= NotchTimerDial.range.lowerBound)
                    round("plus", "Longer", size: 28) { timer.dial = NotchTimerDial.step(timer.dial, by: 1) }
                        .disabled(timer.dial >= NotchTimerDial.range.upperBound)
                    Spacer(minLength: 0)
                    chip("Start", filled: true) { timer.begin(minutes: timer.dial) }
                }
            }
        case .running, .paused:
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    round(mode == .paused ? "play.fill" : "pause.fill", mode == .paused ? "Resume" : "Pause", size: 44,
                          filled: true) { mode == .paused ? timer.resume() : timer.pause() }
                    round("xmark", "Cancel", size: 44) { timer.cancel() }
                }
                chip("+1 min") { timer.addMinute() }
            }
        case .done:
            VStack(spacing: 10) {
                chip("Stop", filled: true, wide: true) { timer.dismissDone() }
                chip("+1 min", wide: true) { timer.addMinute() }
            }
        }
    }

    /// A capsule: dim white, brighter for the preset matching the dial, or in the timer's colour for the main action.
    private func chip(_ title: String, selected: Bool = false, filled: Bool = false, wide: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(filled ? .black : .white)
                .padding(.horizontal, 6).frame(height: 26).frame(maxWidth: wide ? 112 : .infinity)
                .background(filled ? notchTimerTint : .white.opacity(selected ? 0.24 : 0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle()).help(title)
    }

    private func round(_ symbol: String, _ label: String, size: CGFloat, filled: Bool = false,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.36, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(filled ? .black : .white)
                .frame(width: size, height: size)
                .background(filled ? notchTimerTint : .white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(NotchPressStyle()).accessibilityLabel(label).help(label)
    }

    private func accessibilityValue(_ mode: Mode) -> String {
        switch mode {
        case .idle: "\(timer.dial) minutes"
        case .running: "\(NotchTimerRun.label(timer.seconds)) left"
        case .paused: "Paused, \(NotchTimerRun.label(timer.seconds)) left"
        case .done: "Done"
        }
    }
}

/// The bell and the end time, tight together.
private struct NotchTimerCaptionLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8))
            configuration.title
        }
    }
}

/// A thin ring filling clockwise from the top over a faint track. It draws what it is given and never animates by
/// itself.
struct NotchTimerRing: View {
    let progress: Double
    let lineWidth: CGFloat
    let tint: Color
    var track: Double = 0.18

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(track), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // A round cap would show a dot at zero.
                .opacity(progress > 0 ? 1 : 0)
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// A copy of the finished ring that swells and fades once as it appears. It comes to rest invisible, so nothing
/// repaints after.
private struct NotchTimerBloom: View {
    let lineWidth: CGFloat
    @State private var bloomed = false

    var body: some View {
        Circle().stroke(notchTimerTint, lineWidth: lineWidth)
            .padding(lineWidth / 2)
            .scaleEffect(bloomed ? 1.28 : 1)
            .opacity(bloomed ? 0 : 0.8)
            .onAppear { withAnimation(.spring(duration: 1.1, bounce: 0)) { bloomed = true } }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The pulse of a phase alert: a little larger, glowing.
private struct NotchTimerPulse {
    var scale = 1.0
    var glow = 0.0
}

/// Left wing while a timer runs or is paused: a small ring filling as it passes, dimmed while paused. Each phase
/// alert pulses it once with a soft glow; Reduce Motion leaves it still.
struct NotchTimerWingRing: View {
    @ObservedObject var timer: NotchTimer
    /// The phase alert showing, if any.
    let alert: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulses = 0

    var body: some View {
        let paused = timer.run?.paused == true
        NotchTimerRing(progress: timer.progress, lineWidth: 2.5, tint: paused ? .white.opacity(0.5) : notchTimerTint, track: 0.2)
            .frame(width: 15, height: 15)
            .keyframeAnimator(initialValue: NotchTimerPulse(), trigger: pulses) { ring, pulse in
                ring.scaleEffect(pulse.scale).shadow(color: notchTimerTint.opacity(pulse.glow), radius: 5)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.3, duration: 0.35, spring: .snappy)
                    SpringKeyframe(1, duration: 0.8, spring: .smooth)
                }
                KeyframeTrack(\.glow) {
                    CubicKeyframe(0.9, duration: 0.35)
                    CubicKeyframe(0, duration: 1)
                }
            }
            .onChange(of: alert) { _, alert in if alert != nil, !reduceMotion { pulses += 1 } }
            .accessibilityLabel(paused ? "Timer paused" : "Timer")
    }
}

/// Right wing while a timer runs or is paused: the time left, ticking once per second, in the timer's colour for the
/// last ten seconds and dimmed while paused.
struct NotchTimerWingTime: View {
    @ObservedObject var timer: NotchTimer

    var body: some View {
        let paused = timer.run?.paused == true
        let final = !paused && timer.seconds <= 10
        Text(NotchTimerRun.label(timer.seconds)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(paused ? .white.opacity(0.5) : final ? notchTimerTint : .white)
            .lineLimit(1).minimumScaleFactor(0.8)
            .animation(.spring(duration: 0.8, bounce: 0), value: final)
            .accessibilityLabel(paused ? "Paused, \(NotchTimerRun.label(timer.seconds)) left" : "\(NotchTimerRun.label(timer.seconds)) left")
    }
}

/// The row a phase alert drops under the wings.
struct NotchTimerPhaseRow: View {
    let minutes: Int

    var body: some View {
        Text("\(minutes) min left").font(.system(size: 11, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: NotchGeometry.timerAlertDrop - 2, alignment: .center)
    }
}

/// The Done row a finished timer drops from the closed notch: the completed ring blooming once, Done and the length,
/// or when it ended for a finish missed while away, then +1 min and Stop.
struct NotchTimerDoneRow: View {
    @ObservedObject var timer: NotchTimer
    let topHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                NotchTimerRing(progress: 1, lineWidth: 2.5, tint: notchTimerTint)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(notchTimerTint)
                if !reduceMotion { NotchTimerBloom(lineWidth: 2.5) }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Done").font(.system(size: 12, weight: .semibold))
                if let done = timer.done {
                    Text(done.late ? "Ended \(done.end.formatted(date: .omitted, time: .shortened))" : Self.length(done.length))
                        .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            button("+1 min", filled: false, action: timer.addMinute)
            button("Stop", filled: true, action: timer.dismissDone)
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: NotchGeometry.timerDoneDrop - 6)
        .padding(.top, topHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timer done")
    }

    /// "25 min timer", or "1 h 30 min timer".
    private static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        return (hours > 0 ? "\(hours) h" + (minutes % 60 > 0 ? " \(minutes % 60) min" : "") : "\(minutes) min") + " timer"
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(filled ? .black : .white)
                .padding(.horizontal, 10).frame(height: 22)
                .background(filled ? notchTimerTint : .white.opacity(0.15), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle()).help(title)
    }
}
