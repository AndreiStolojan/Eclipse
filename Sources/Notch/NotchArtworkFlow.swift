import Foundation

/// Which way the artwork turns: back after Eclipse's own Previous, forward otherwise.
enum NotchSkipDirection: Equatable {
    case next, previous
}

/// Decides when the player's artwork turns to a new image, and which way. Images are told apart by a key that
/// changes only with the image data, so a pause, a seek or the title arriving first never turns it. Players often
/// clear the artwork for a moment between tracks, so a removal waits `settle` for the next image and the artwork turns
/// once, straight to it; a track without artwork turns to the placeholder after that. A skip from Eclipse's own
/// controls or swipe sets the direction of the next turn for `skipMemory` seconds; any other change goes forward.
struct NotchArtworkFlow {
    /// One turn to a new image: the views animate each time the number changes.
    struct Turn: Equatable {
        var number = 0
        var direction = NotchSkipDirection.next
    }

    /// What a report asks of the caller.
    enum Outcome: Equatable {
        /// The artwork turned to the reported image.
        case turned
        /// The artwork was removed: report again at this instant, when the removal is due unless an image arrives.
        case wait(until: ContinuousClock.Instant)
        case unchanged
    }

    static let settle: Duration = .milliseconds(350)
    static let skipMemory: Duration = .seconds(4)

    /// The image shown, nil for the placeholder.
    private(set) var shown: Int?
    private(set) var turn = Turn()
    private var removedSince: ContinuousClock.Instant?
    private var skip: (direction: NotchSkipDirection, at: ContinuousClock.Instant)?

    /// Eclipse's own controls skipped a track.
    mutating func skipped(_ direction: NotchSkipDirection, at now: ContinuousClock.Instant) {
        skip = (direction, now)
    }

    /// The player now reports the image with `key`, or none.
    mutating func report(_ key: Int?, at now: ContinuousClock.Instant) -> Outcome {
        guard key != shown else { removedSince = nil; return .unchanged }
        if key == nil {
            let since = removedSince ?? now
            removedSince = since
            if now - since < Self.settle { return .wait(until: since + Self.settle) }
        }
        removedSince = nil
        shown = key
        turn = Turn(number: turn.number + 1, direction: direction(at: now))
        return .turned
    }

    /// The direction of a skip made shortly before, used once; forward without one.
    private mutating func direction(at now: ContinuousClock.Instant) -> NotchSkipDirection {
        defer { skip = nil }
        guard let skip, now - skip.at <= Self.skipMemory else { return .next }
        return skip.direction
    }
}

/// Where one face of the artwork stands during a turn, for `progress` 0...1. The new image comes in over the old one
/// and the old stays whole beneath it until the turn ends, so the tile is never empty or stretched on the way. A
/// flip shows the old face for the first half and the new for the second, swapping as the card stands edge-on; a
/// slide moves both faces by the tile's width plus a small gap, the new one in from the right for next and from the
/// left for previous; a fade settles the new image from slightly enlarged. Reduce Motion leaves only a crossfade.
struct NotchArtworkPose: Equatable {
    var opacity = 1.0
    var scale = 1.0
    /// Degrees about the vertical axis.
    var angle = 0.0
    /// Horizontal offset in tile widths.
    var offset = 0.0
    /// Blur radius in tile widths.
    var blur = 0.0

    static let slideGap = 0.08

    init() {}

    init(_ transition: NotchArtworkTransition, progress: Double, direction: NotchSkipDirection, outgoing: Bool,
         reduceMotion: Bool) {
        let progress = min(1, max(0, progress))
        let sign = direction == .next ? 1.0 : -1.0
        if reduceMotion {
            opacity = outgoing ? 1 : progress
            return
        }
        switch transition {
        case .flip:
            let firstHalf = progress < 0.5
            opacity = outgoing == firstHalf ? 1 : 0
            angle = (outgoing ? progress : progress - 1) * 180 * -sign
            scale = 1 - 0.08 * sin(progress * .pi)
        case .slide:
            offset = (outgoing ? -progress : 1 - progress) * sign * (1 + Self.slideGap)
        case .crossfade:
            if !outgoing {
                opacity = progress
                scale = 1.08 - 0.08 * progress
            }
        case .blur:
            opacity = outgoing ? 1 : progress
            blur = (outgoing ? progress : 1 - progress) * 0.14
        case .none:
            opacity = outgoing ? 0 : 1
        }
    }
}
