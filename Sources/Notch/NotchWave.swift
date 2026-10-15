import AppKit

/// The right wing's decorative wave while music plays: when it may move, the motion itself and its tint. It is not
/// driven by the audio; a few sines at unrelated frequencies make it look alive, repeating only every `period`.
enum NotchWave {
    /// The wave's box, about the closed artwork's size so the two wings balance.
    static let width: Double = 22
    static let height: Double = 14
    static let bars = 5
    /// Seconds the wave takes to rise from rest or flatten back to it. The closed wings fade their playing content in
    /// and out over the same time on one spring, so on a pause the wave flattens as it fades with the artwork and
    /// is gone when the artwork is.
    static let ease: Double = 0.6
    /// Keyframes a second, and the rate Core Animation is asked to draw them at: a third of a 72 Hz display's rate
    /// and a fifth of ProMotion's, still smooth for motion this slow and this small.
    static let frameRate: Double = 24
    /// Seconds after which the motion repeats, so its keyframes are made once per rise. Over the last `seam` seconds
    /// it blends into its own start, so the repeat never jumps.
    static let period: Double = 60
    static let seam: Double = 4

    /// Whether the wave moves: only while a track plays in the closed notch with nothing else in the wings. Open, or
    /// with an indicator, the timer, the countdown or a peek in the wings, it settles to rest.
    static func moves(playing: Bool, shape: NotchShape) -> Bool {
        playing && shape == .closed
    }

    /// A bar's level at `time` in seconds, 0...1: a quick, a middling and a slow sine per bar, with frequencies and
    /// phases that differ from bar to bar, under a slow swell shared by all, like a phrase breathing.
    static func level(_ bar: Int, at time: Double) -> Double {
        let index = Double(bar)
        let quick = sin(time * (6.3 + 0.71 * index) + index * 2.4)
        let middling = sin(time * (3.7 - 0.43 * index) + index * 1.3 + 0.6)
        let slow = sin(time * (1.9 + 0.17 * index) + index * 0.8)
        return swell(at: time) * (0.5 + 0.5 * (0.45 * quick + 0.35 * middling + 0.2 * slow))
    }

    /// The line's height at `position` 0...1 along it, -1...1 before the amplitude: two travelling sines that drift
    /// against each other, pinned to zero at both ends.
    static func line(at position: Double, time: Double) -> Double {
        let taper = sin(position * .pi)
        let wave = 0.6 * sin(position * 8.2 - time * 3.1) + 0.4 * sin(position * 13.9 + time * 2.3 + 1.2)
        return swell(at: time) * taper * wave
    }

    /// The slow swell shared by the bars and the line.
    private static func swell(at time: Double) -> Double {
        0.8 + 0.2 * sin(time * 0.53) * sin(time * 0.29 + 1.3)
    }

    /// `motion` made to repeat every `period`: from `time` on its own until the last `seam` seconds of each
    /// period, then eased into a copy one period earlier, which ends where the next period starts.
    static func looped(at time: Double, _ motion: (Double) -> Double) -> Double {
        let time = time - (time / period).rounded(.down) * period
        let blend = max(0, (time - (period - seam)) / seam)
        let weight = blend * blend * (3 - 2 * blend)
        return motion(time) * (1 - weight) + motion(time - period) * weight
    }

    /// Bars nearer the middle reach higher, like the dictation pill's envelope.
    static func reach(_ bar: Int) -> Double {
        let distance = Double(bar) - Double(bars - 1) / 2
        return 1 - distance * distance / 12
    }

    /// The artwork's average colour as a soft tint: bright enough to read on black, never more than moderately
    /// saturated. ImageIO decodes the encoded data straight to an 8 px thumbnail, so the full image is never decoded;
    /// callers run it off the main actor.
    static func tint(artwork base64: String) -> NSColor? {
        let side = 8
        guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: side
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sum = [0.0, 0.0, 0.0]
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { sum[channel] += Double(pixels[pixel + channel]) }
        }
        let count = Double(side * side) * 255
        let average = NSColor(srgbRed: sum[0] / count, green: sum[1] / count, blue: sum[2] / count, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(0.6, saturation * 1.2), brightness: max(brightness, 0.9), alpha: 1)
    }
}

/// The wave's amplitude over time in seconds: 0 at rest, 1 in full motion. Each change of whether it moves eases
/// from wherever it was over `NotchWave.ease` with a smoothstep: in the closed notch a play or a pause starts it in
/// the same update as the wings' fade, which lasts as long, so there is no settle left once the artwork has gone.
/// Out of sight it drops to rest at once, even mid-ease, so a return rises from rest.
struct NotchWaveMotion {
    private(set) var from = 0.0
    private(set) var target = 0.0
    private(set) var changedAt = -Double.infinity

    func amplitude(at time: Double) -> Double {
        let progress = min(1, max(0, (time - changedAt) / NotchWave.ease))
        return from + (target - from) * progress * progress * (3 - 2 * progress)
    }

    /// Whether anything moves at `time`: in full motion, rising or settling.
    func moves(at time: Double) -> Bool {
        target > 0 || time < changedAt + NotchWave.ease
    }

    /// Takes whether the wave may move and can be seen; true when the motion changed and must be redrawn.
    mutating func update(moving: Bool, visible: Bool, at time: Double) -> Bool {
        guard visible else {
            defer { self = NotchWaveMotion() }
            return moves(at: time)
        }
        let target: Double = moving ? 1 : 0
        guard target != self.target else { return false }
        from = amplitude(at: time)
        self.target = target
        changedAt = time
        return true
    }
}
