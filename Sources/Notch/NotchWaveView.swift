import QuartzCore
import SwiftUI

/// The closed notch's right-wing wave while a track plays: bars like the dictation pill's, a soft line or a row
/// of dots, all moving to `NotchWave`'s sines. It only moves and rests; the caller fades it in and out with the
/// artwork, and stopping `moving` at the same moment flattens it over that fade.
///
/// Cost: the motion is Core Animation keyframes made once per rise and settle, which the render server plays at
/// `NotchWave.frameRate`; the app does no work per frame. A SwiftUI TimelineView redrawing a Canvas at the same rate
/// cost 4 to 6 % of a core, almost all of it SwiftUI and AppKit layout and commit work around each frame. At rest
/// (`moving` false, Reduce Motion or a still render) no animation is left; out of sight (`visible` false) they are
/// removed at once, without settling.
struct NotchWaveView: View {
    let style: NotchWaveStyle
    let color: Color
    /// Whether it moves; false settles it to rest over `NotchWave.ease` and then stops it.
    let moving: Bool
    /// Whether it can be seen; false stops it at once, and a return rises from rest.
    var visible = true
    /// False in still renders, which draw one frame as Reduce Motion does.
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NotchWaveLayers(style: style, color: NSColor(color).cgColor, moving: moving, visible: visible,
                        still: animated && !reduceMotion ? nil : 0.85)
            .frame(width: NotchWave.width, height: NotchWave.height)
            .accessibilityHidden(true)
    }
}

/// Hands the wave's inputs to its layers.
private struct NotchWaveLayers: NSViewRepresentable {
    let style: NotchWaveStyle
    let color: CGColor
    let moving: Bool
    let visible: Bool
    /// The amplitude of a still frame, or nil to move.
    let still: Double?

    func makeNSView(context: Context) -> NotchWaveLayerView {
        NotchWaveLayerView(style: style)
    }

    func updateNSView(_ view: NotchWaveLayerView, context: Context) {
        view.update(style: style, color: color, moving: moving, visible: visible, still: still)
    }
}

/// The wave as one layer per bar or dot, or one shape layer for the line. Each layer's model value stays at rest; a
/// rise or settle adds a short keyframe animation through `NotchWaveMotion`'s amplitudes, and full motion a
/// `NotchWave.period` loop after it, so both run in the render server.
final class NotchWaveLayerView: NSView {
    private var style: NotchWaveStyle
    private var parts: [CALayer] = []
    private var motion = NotchWaveMotion()
    private static let barWidth = 2.5
    private static let dotDiameter = 3.0
    private static let lineWidth = 1.75
    /// A moment of the motion that reads well as a still.
    private static let stillTime = 2.2

    init(style: NotchWaveStyle) {
        self.style = style
        super.init(frame: CGRect(x: 0, y: 0, width: NotchWave.width, height: NotchWave.height))
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for part in parts { part.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    /// Applies SwiftUI's latest inputs; animations are only redone when the motion or the style changed.
    func update(style: NotchWaveStyle, color: CGColor, moving: Bool, visible: Bool, still: Double?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let restyled = style != self.style
        if restyled {
            self.style = style
            build()
        }
        for part in parts {
            if let line = part as? CAShapeLayer { line.strokeColor = color } else { part.backgroundColor = color }
        }
        if let still {
            motion = NotchWaveMotion()
            for part in parts { part.removeAllAnimations() }
            show(values(time: Self.stillTime, amplitude: still))
            return
        }
        let now = CACurrentMediaTime()
        if motion.update(moving: moving, visible: visible, at: now) || restyled { animate(at: now) }
    }

    /// Replaces the layers for the current style, at rest.
    private func build() {
        parts.forEach { $0.removeFromSuperlayer() }
        let middle = NotchWave.height / 2
        let count = Double(NotchWave.bars)
        switch style {
        case .bars:
            let width = Self.barWidth
            let gap = (NotchWave.width - width * count) / (count - 1)
            parts = (0..<NotchWave.bars).map { bar in
                let part = CALayer()
                part.bounds = CGRect(x: 0, y: 0, width: width, height: width)
                part.position = CGPoint(x: Double(bar) * (width + gap) + width / 2, y: middle)
                part.cornerRadius = width / 2
                return part
            }
        case .dots:
            let diameter = Self.dotDiameter
            let step = (NotchWave.width - diameter) / (count - 1)
            parts = (0..<NotchWave.bars).map { dot in
                let part = CALayer()
                part.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                part.position = CGPoint(x: Double(dot) * step + diameter / 2, y: middle)
                part.cornerRadius = diameter / 2
                return part
            }
        case .line:
            let line = CAShapeLayer()
            line.frame = bounds
            line.fillColor = nil
            line.lineWidth = Self.lineWidth
            line.lineCap = .round
            line.lineJoin = .round
            parts = [line]
        }
        for part in parts {
            part.contentsScale = window?.backingScaleFactor ?? 2
            layer?.addSublayer(part)
        }
        show(values(time: 0, amplitude: 0))
    }

    /// Redoes the animations for `motion`: none at rest, an ease from its last change, and the loop once it arrives
    /// in full motion. The ease's keyframes use the same clock as the loop's, so the two join without a jump.
    private func animate(at now: CFTimeInterval) {
        for part in parts { part.removeAllAnimations() }
        show(values(time: 0, amplitude: 0))
        guard motion.moves(at: now) else { return }
        let start = motion.changedAt
        let steps = Int((NotchWave.ease * NotchWave.frameRate).rounded(.up))
        let easing = (0...steps).map { step in
            let time = start + NotchWave.ease * Double(step) / Double(steps)
            return values(time: time, amplitude: motion.amplitude(at: time))
        }
        add("ease", frames: easing, from: start, duration: NotchWave.ease)
        guard motion.target > 0 else { return }
        let count = Int(NotchWave.period * NotchWave.frameRate)
        let loop = (0...count).map { values(time: NotchWave.period * Double($0) / Double(count), amplitude: 1) }
        add("loop", frames: loop, from: start + NotchWave.ease, duration: NotchWave.period, repeats: true)
    }

    /// Adds one keyframe animation per layer; `frames` holds each frame's values, one per layer. A loop starts at its
    /// own point in the period, as the clock says.
    private func add(_ key: String, frames: [[Any]], from start: CFTimeInterval, duration: Double, repeats: Bool = false) {
        for (index, part) in parts.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = frames.map { $0[index] }
            animation.calculationMode = .linear
            animation.beginTime = part.convertTime(start, from: nil)
            animation.duration = duration
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 30,
                                                                 preferred: Float(NotchWave.frameRate))
            if repeats {
                animation.repeatCount = .infinity
                animation.timeOffset = start.truncatingRemainder(dividingBy: NotchWave.period)
            }
            part.add(animation, forKey: key)
        }
    }

    /// The property each layer animates: a bar's height, a dot's height or the line's path.
    private var keyPath: String {
        switch style {
        case .bars: "bounds.size.height"
        case .dots: "position.y"
        case .line: "path"
        }
    }

    private func show(_ values: [Any]) {
        for (part, value) in zip(parts, values) { part.setValue(value, forKeyPath: keyPath) }
    }

    /// Each layer's value of `keyPath` at `time` on the media clock, at `amplitude`.
    private func values(time: Double, amplitude: Double) -> [Any] {
        let height = NotchWave.height
        let middle = height / 2
        switch style {
        case .bars:
            let width = Self.barWidth
            return (0..<NotchWave.bars).map { bar in
                width + (height - width) * amplitude * NotchWave.reach(bar)
                    * NotchWave.looped(at: time) { NotchWave.level(bar, at: $0) }
            }
        case .dots:
            let diameter = Self.dotDiameter
            return (0..<NotchWave.bars).map { dot in
                let level = NotchWave.looped(at: time) { NotchWave.level(dot, at: $0) }
                return middle - amplitude * (middle - diameter / 2) * NotchWave.reach(dot) * (level * 2 - 1)
            }
        case .line:
            let lineWidth = Self.lineWidth
            let span = NotchWave.width - lineWidth
            let path = CGMutablePath()
            for sample in 0...24 {
                let position = Double(sample) / 24
                let rise = NotchWave.looped(at: time) { NotchWave.line(at: position, time: $0) }
                let point = CGPoint(x: lineWidth / 2 + position * span, y: middle - amplitude * (middle - lineWidth) * rise)
                if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return [path]
        }
    }
}
